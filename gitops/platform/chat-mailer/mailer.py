"""Chat mailer: when an ordered AI chat is ready, mail its owner the link and the username.

Watches the Argo CD apps of the AI chats. Sends with Amazon SES. SES is in test mode, so a new address first
gets a confirm mail from Amazon; the chat mail follows once it is confirmed.
"""
import datetime
import hashlib
import hmac
import json
import os
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

REGION = os.environ.get("REGION", "us-west-2")
DOMAIN = os.environ.get("DOMAIN", "kubeforge.live")
FROM = os.environ.get("FROM", "noreply@" + DOMAIN)
TAG = os.environ.get("PROJECT_TAG", "kubecon-demo")
STATE = "/data/state.json"
GIVE_UP = 3 * 86400  # stop waiting for a confirm after three days

SA = "/var/run/secrets/kubernetes.io/serviceaccount"
KUBE = "https://kubernetes.default.svc"


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def kube(path):
    ctx = ssl.create_default_context(cafile=SA + "/ca.crt")
    req = urllib.request.Request(KUBE + path, headers={"Authorization": "Bearer " + open(SA + "/token").read()})
    with urllib.request.urlopen(req, context=ctx, timeout=20) as r:
        return json.load(r)


def ses(method, path, body=None):
    """One call to the SES v2 API, signed with AWS SigV4."""
    key, secret = os.environ["AWS_ACCESS_KEY_ID"], os.environ["AWS_SECRET_ACCESS_KEY"]
    host = f"email.{REGION}.amazonaws.com"
    data = json.dumps(body).encode() if body is not None else b""
    now = datetime.datetime.now(datetime.timezone.utc)
    amz, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    canon_path = urllib.parse.quote(path, safe="/")
    headers = {"host": host, "x-amz-date": amz, "content-type": "application/json"}
    signed = ";".join(sorted(headers))
    # AWS signs the path encoded once more (all services but S3)
    canon = "\n".join([method, urllib.parse.quote(canon_path, safe="/"), "", "".join(f"{k}:{headers[k]}\n" for k in sorted(headers)), signed,
                       hashlib.sha256(data).hexdigest()])
    scope = f"{day}/{REGION}/ses/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz, scope, hashlib.sha256(canon.encode()).hexdigest()])
    k = ("AWS4" + secret).encode()
    for part in (day, REGION, "ses", "aws4_request"):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    headers["Authorization"] = f"AWS4-HMAC-SHA256 Credential={key}/{scope}, SignedHeaders={signed}, Signature={sig}"
    req = urllib.request.Request(f"https://{host}{canon_path}", data=data or None, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def address_ready(addr, state):
    """True when SES may send to addr. Asks Amazon to send a confirm mail the first time."""
    code, body = ses("GET", "/v2/email/identities/" + addr)
    if code == 200:
        return body.get("VerifiedForSendingStatus", False)
    if code == 404 and addr not in state["asked"]:
        code, body = ses("POST", "/v2/email/identities",
                         {"EmailIdentity": addr, "Tags": [{"Key": "Project", "Value": TAG}]})
        state["asked"][addr] = time.time()
        log(f"{addr}: asked Amazon to send a confirm mail ({code})")
    return False


def message(name, owner, docs):
    first = name[:-5] if name.endswith("-docs") else name
    url = f"https://{name}.{DOMAIN}"
    what = "documents chat" if docs else "AI chat"
    text = (f"Hi {first.capitalize()},\n\nYour private {what} is ready.\n\n"
            f"Open: {url}\nUsername: {owner}\nPassword: use the password you chose when you ordered it.\n\n"
            "To remove it, order \"Remove AI chat\" in Morpheus.\n")
    html = (f"<p>Hi {first.capitalize()},</p><p>Your private {what} is ready.</p>"
            f"<p>Open: <a href=\"{url}\">{url}</a><br>Username: {owner}<br>"
            "Password: use the password you chose when you ordered it.</p>"
            "<p>To remove it, order \"Remove AI chat\" in Morpheus.</p>")
    return {"FromEmailAddress": FROM, "Destination": {"ToAddresses": [owner]},
            "Content": {"Simple": {"Subject": {"Data": f"Your {what} is ready"},
                                   "Body": {"Text": {"Data": text}, "Html": {"Data": html}}}}}


def chats():
    apps = kube("/apis/argoproj.io/v1alpha1/namespaces/argocd/applications?labelSelector=kubecon-demo%2Fcatalog%3Dai-chat")
    for a in apps.get("items", []):
        params = {p["name"]: p.get("value", "") for p in a["spec"].get("source", {}).get("helm", {}).get("parameters", [])}
        owner = (a["metadata"].get("annotations", {}).get("kubecon-demo/owner") or params.get("ownerEmail", "")).strip().lower()
        yield {"uid": a["metadata"]["uid"], "app": a["metadata"]["name"], "name": params.get("name", ""),
               "owner": owner, "docs": params.get("documents", "") == "true",
               "healthy": a.get("status", {}).get("health", {}).get("status") == "Healthy"}


def load():
    try:
        return json.load(open(STATE))
    except (OSError, ValueError):
        return None


def save(state):
    tmp = STATE + ".tmp"
    json.dump(state, open(tmp, "w"))
    os.replace(tmp, STATE)


def step(state):
    for c in chats():
        if c["uid"] in state["sent"] or not c["healthy"] or not c["owner"] or not c["name"]:
            continue
        wait = state["waiting"].setdefault(c["uid"], time.time())
        if time.time() - wait > GIVE_UP:
            log(f"{c['app']}: {c['owner']} never confirmed, no mail")
            state["sent"][c["uid"]] = "gave up"
            continue
        if not address_ready(c["owner"], state):
            continue
        code, body = ses("POST", "/v2/email/outbound-emails", message(c["name"], c["owner"], c["docs"]))
        if code == 200:
            state["sent"][c["uid"]] = time.time()
            state["waiting"].pop(c["uid"], None)
            log(f"{c['app']}: mailed {c['owner']}")
        else:
            log(f"{c['app']}: send failed ({code}) {body.get('message', '')}")


def main():
    if "AWS_ACCESS_KEY_ID" not in os.environ:
        log("no SES key yet: run scripts/setup-email.sh")
        while True:
            time.sleep(3600)
    state = load()
    if state is None:
        # first start: chats that already run were set up before mail existed, do not mail them
        state = {"sent": {}, "asked": {}, "waiting": {}}
        for c in chats():
            if c["healthy"]:
                state["sent"][c["uid"]] = "before mail"
        save(state)
        log(f"first start, {len(state['sent'])} running chats skipped")
    while True:
        try:
            step(state)
            save(state)
        except Exception as e:  # keep going, the next round tries again
            log("error:", e)
        time.sleep(30)


if __name__ == "__main__":
    main()
