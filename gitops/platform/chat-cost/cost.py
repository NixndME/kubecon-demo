"""Cost recorder for the AI chats.

Every 30 seconds it reads, for each chat (namespace ai-*):
  - the questions (Open WebUI audit log in Loki: who, what)
  - the model server calls (Ollama request log in Loki: how long each call kept the model busy)
  - CPU, memory and booked GPU memory (Prometheus)
and prices them with the AWS prices in prices.json.

Cost model, so that questions + idle = total for every chat:
  chat cost     = booked GPU memory x GPU price x time + CPU used x vCPU price + memory used x memory price
  question cost = booked GPU memory x GPU price x busy seconds + CPU and memory used in those seconds
  idle cost     = chat cost - all its question costs

Output: Prometheus counters on :9100/metrics, and one JSON line per question on stdout (Loki).
"""
import json, os, re, time, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Lock, Thread

PROM = os.environ.get("PROM_URL", "http://prometheus-k8s.monitoring.svc:9090")
LOKI = os.environ.get("LOKI_URL", "http://loki.loki.svc:3100")
STATE = os.environ.get("STATE_FILE", "/data/state.json")
STEP = int(os.environ.get("STEP_SECONDS", "30"))
PRICES = json.load(open(os.environ.get("PRICES_FILE", "/config/prices.json")))

# Split the GPU node price into GPU, CPU and memory: the GPU is worth the difference to the same machine without
# a GPU; CPU and memory split that machine's price with the usual cloud ratio (vCPU ~7.5x a GB of memory).
node, twin = PRICES["gpu_node_per_hour"], PRICES["same_node_without_gpu_per_hour"]
vcpus, mem_gb, gpu_mem_gb = PRICES["vcpus"], PRICES["memory_gb"], PRICES["gpu_memory_gb"]
ratio = PRICES.get("vcpu_to_memory_gb_ratio", 7.46)
MEM_GB_H = twin / (vcpus * ratio + mem_gb)
VCPU_H = MEM_GB_H * ratio
GPU_H = node - twin
GPU_GB_H = GPU_H / gpu_mem_gb

lock = Lock()
# Bump when the way questions are priced changes: the recorder then starts fresh
STATE_VERSION = 3
state = {"version": STATE_VERSION, "since_ns": 0, "chats": {}}


def http_json(url):
    with urllib.request.urlopen(url, timeout=20) as r:
        return json.load(r)


def prom(query, at=None):
    q = {"query": query}
    if at:
        q["time"] = f"{at:.3f}"
    res = http_json(f"{PROM}/api/v1/query?{urllib.parse.urlencode(q)}")["data"]["result"]
    return {r["metric"].get("namespace", ""): float(r["value"][1]) for r in res}


def loki(query, start_ns, end_ns):
    q = urllib.parse.urlencode({"query": query, "start": start_ns, "end": end_ns, "limit": 5000, "direction": "forward"})
    out = []
    for s in http_json(f"{LOKI}/loki/api/v1/query_range?{q}")["data"]["result"]:
        for ts, line in s["values"]:
            out.append((int(ts), s["stream"], line))
    return sorted(out, key=lambda x: x[0])


DUR = re.compile(r"(\d+(?:\.\d+)?)(h|ms|µs|us|ns|m|s)")
UNIT = {"h": 3600, "m": 60, "s": 1, "ms": 1e-3, "µs": 1e-6, "us": 1e-6, "ns": 1e-9}


def go_seconds(text):
    """Seconds from a Go duration like 1m2.5s or 432.5ms."""
    return sum(float(n) * UNIT[u] for n, u in DUR.findall(text))


GIN = re.compile(r"\[GIN\].*?\|\s*(\d{3})\s*\|\s*([0-9.]+[a-zµ]+(?:[0-9.]+[a-zµ]+)*)\s*\|.*?POST\s+\"(/api/[a-z]+)\"")
AUDIT = re.compile(r"audit:write:\d+ - +- (\{.*)$")
LAST_USER = re.compile(r'(?s).*"role":\s*"user",\s*"content":\s*"((?:[^"\\]|\\.)*)"')


def question_of(audit_line):
    m = AUDIT.search(audit_line)
    if not m:
        return None
    a = json.loads(m.group(1))
    if not a.get("user") or "/api/chat/completions" not in a.get("request_uri", ""):
        return None
    body = a.get("request_object") or ""
    q = LAST_USER.match(body)
    text = json.loads('"' + q.group(1) + '"') if q else ""
    try:
        model = json.loads(body).get("model", "")
    except ValueError:
        model = ""
    return {"who": a["user"].get("email", ""), "question": text[:300], "model": model}


def loki_metric(query):
    q = urllib.parse.urlencode({"query": query, "time": time.time_ns()})
    return [r["metric"] for r in http_json(f"{LOKI}/loki/api/v1/query?{q}")["data"]["result"]]


def chat_info():
    """Chats now: owner, model, size and resources, keyed by namespace."""
    up = prom('sum by (namespace) (kube_pod_info{namespace=~"ai-.+"})')
    gpu = prom('sum by (namespace) (hami_vgpu_memory_allocated_bytes{namespace=~"ai-.+"})')
    cpu = prom('sum by (namespace) (rate(container_cpu_usage_seconds_total{namespace=~"ai-.+", container!=""}[2m]))')
    mem = prom('sum by (namespace) (container_memory_working_set_bytes{namespace=~"ai-.+", container!=""})')
    labels = {}
    for m in loki_metric('count by (namespace, owner, model, size, team) (count_over_time({namespace=~"ai-.+", container=~".+"} [10m]))'):
        labels[m.get("namespace", "")] = {k: m.get(k, "") for k in ("owner", "model", "size", "team")}
    return {ns: {"gpu_gb": gpu.get(ns, 0) / 2**30, "cpu": cpu.get(ns, 0), "mem_gb": mem.get(ns, 0) / 2**30,
                 **labels.get(ns, {"owner": "", "model": "", "size": "", "team": ""})} for ns in up}


def chat(ns, info):
    c = state["chats"].setdefault(ns, {"gpu": 0.0, "cpu": 0.0, "mem": 0.0, "q_gpu": 0.0, "q_cpu": 0.0, "q_mem": 0.0,
                                      "questions": 0, "busy": 0.0, "seconds": 0.0, "labels": {}})
    if info.get("owner"):
        c["labels"] = {k: info[k] for k in ("owner", "model", "size", "team")}
    return c


def record(ns, q, calls, info):
    """Price one question from its model server calls."""
    busy = sum(d for _, d, _ in calls)
    end = max(t for t, _, _ in calls) / 1e9
    cores = prom(f'sum by (namespace) (rate(container_cpu_usage_seconds_total{{namespace="{ns}", container="ollama"}}[1m]))', end + 30).get(ns, 0)
    mem = prom(f'sum by (namespace) (container_memory_working_set_bytes{{namespace="{ns}", container="ollama"}})', end).get(ns, 0) / 2**30
    gpu_gb = info.get("gpu_gb", 0)
    cost = {"gpu": gpu_gb * GPU_GB_H * busy / 3600, "cpu": cores * busy * VCPU_H / 3600, "mem": mem * busy * MEM_GB_H / 3600}
    c = chat(ns, info)
    c["q_gpu"] += cost["gpu"]; c["q_cpu"] += cost["cpu"]; c["q_mem"] += cost["mem"]
    c["questions"] += 1; c["busy"] += busy
    print(json.dumps({"type": "question", "chat": ns, "who": q["who"], "model": q["model"] or c["labels"].get("model", ""),
                      "size": c["labels"].get("size", ""), "question": q["question"], "calls": len(calls),
                      "busy_seconds": round(busy, 3), "cpu_seconds": round(cores * busy, 3), "memory_gb": round(mem, 2),
                      "gpu_gb_booked": round(gpu_gb, 2), "cost_gpu": round(cost["gpu"], 8), "cost_cpu": round(cost["cpu"], 8),
                      "cost_memory": round(cost["mem"], 8), "cost": round(sum(cost.values()), 8)}), flush=True)


DELAY = 60 * 10**9
BACKFILL = int(os.environ.get("BACKFILL_MINUTES", "120")) * 60 * 10**9


def step():
    now_ns = time.time_ns()
    # Calls are logged when they finish; wait 60 s so a question's calls are all in before pricing it
    until = now_ns - DELAY
    # First start: also price the questions of the last two hours
    since = state["since_ns"] or until - BACKFILL
    info = chat_info()
    with lock:
        for ns, i in info.items():
            c = chat(ns, i)
            c["gpu"] += i["gpu_gb"] * GPU_GB_H * STEP / 3600
            c["cpu"] += i["cpu"] * VCPU_H * STEP / 3600
            c["mem"] += i["mem_gb"] * MEM_GB_H * STEP / 3600
            c["seconds"] += STEP
    if until <= since:
        return
    # Open WebUI logs a question when it arrives; the model server logs each call when it ends, with its duration.
    # A call belongs to the latest question that arrived before the call started (the answer itself, then the
    # title, tags and follow-up suggestions). Look 10 minutes back and up to now for the neighbours, but price
    # only the questions in [since, until), so each one is priced once.
    questions = {}
    for ts, st, line in loki('{namespace=~"ai-.+", container="webui"} |= "audit:write" |= "/api/chat/completions"', since - 600 * 10**9, now_ns):
        q = question_of(line)
        if q:
            questions.setdefault(st["namespace"], []).append((ts, q))
    calls = {}
    for ts, st, line in loki('{namespace=~"ai-.+", container="ollama"} |= "[GIN]" |= "POST"', since - 600 * 10**9, now_ns):
        m = GIN.search(line)
        if m and m.group(3) in ("/api/chat", "/api/generate", "/api/embed", "/api/embeddings"):
            calls.setdefault(st["namespace"], []).append((ts, go_seconds(m.group(2)), m.group(3)))
    with lock:
        for ns, qs in questions.items():
            owned = {n: [] for n in range(len(qs))}
            for call in calls.get(ns, []):
                start = call[0] - int(call[1] * 1e9)
                if call[2].startswith("/api/embed") and not any(ts <= start + 5 * 10**9 <= ts + 30 * 10**9 for ts, _ in qs):
                    # Indexing an uploaded file happens before anyone asks: it belongs to the next question
                    n = min((k for k, (ts, _) in enumerate(qs) if ts >= start), default=None)
                else:
                    n = max((k for k, (ts, _) in enumerate(qs) if ts <= start + 5 * 10**9), default=None)
                if n is not None:
                    owned[n].append(call)
            for n, (ts, q) in enumerate(qs):
                if since <= ts < until and owned[n]:
                    record(ns, q, owned[n], info.get(ns, {}))
        state["since_ns"] = until
        json.dump(state, open(STATE + ".tmp", "w"))
        os.replace(STATE + ".tmp", STATE)


def metrics():
    out = ["# HELP ai_chat_cost_dollars_total Cost of a chat since it started, by part.",
           "# TYPE ai_chat_cost_dollars_total counter",
           "# HELP ai_chat_question_cost_dollars_total Cost of the questions of a chat, by part.",
           "# TYPE ai_chat_question_cost_dollars_total counter"]
    with lock:
        for ns, c in state["chats"].items():
            lab = ",".join([f'chat="{ns}"'] + [f'{k}="{v}"' for k, v in c["labels"].items()])
            for part in ("gpu", "cpu", "mem"):
                p = {"mem": "memory"}.get(part, part)
                out.append(f'ai_chat_cost_dollars_total{{{lab},part="{p}"}} {c[part]:.8f}')
                out.append(f'ai_chat_question_cost_dollars_total{{{lab},part="{p}"}} {c["q_" + part]:.8f}')
            out.append(f"ai_chat_questions_total{{{lab}}} {c['questions']}")
            out.append(f"ai_chat_busy_seconds_total{{{lab}}} {c['busy']:.3f}")
            out.append(f"ai_chat_running_seconds_total{{{lab}}} {c['seconds']:.0f}")
    for item, v in (("gpu_node", node), ("gpu", GPU_H), ("gpu_memory_gb", GPU_GB_H), ("vcpu", VCPU_H), ("memory_gb", MEM_GB_H),
                    ("platform", PRICES.get("platform_per_hour", 0))):
        out.append(f'ai_price_dollars_per_hour{{item="{item}"}} {v:.6f}')
    for size, gb in PRICES.get("sizes_gb", {}).items():
        out.append(f'ai_price_dollars_per_hour{{item="size_{size}"}} {gb * GPU_GB_H:.6f}')
    return "\n".join(out) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = metrics().encode() if self.path.startswith("/metrics") else b"ok\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def loop():
    while True:
        started = time.time()
        try:
            step()
        except Exception as e:
            print(json.dumps({"type": "error", "message": str(e)[:300]}), flush=True)
        time.sleep(max(1, STEP - (time.time() - started)))


if __name__ == "__main__":
    if os.path.exists(STATE):
        saved = json.load(open(STATE))
        if saved.get("version") == STATE_VERSION:
            state.update(saved)
    print(json.dumps({"type": "start", "gpu_per_hour": round(GPU_H, 4), "gpu_memory_gb_per_hour": round(GPU_GB_H, 5),
                      "vcpu_per_hour": round(VCPU_H, 5), "memory_gb_per_hour": round(MEM_GB_H, 5)}), flush=True)
    Thread(target=loop, daemon=True).start()
    HTTPServer(("", 9100), Handler).serve_forever()
