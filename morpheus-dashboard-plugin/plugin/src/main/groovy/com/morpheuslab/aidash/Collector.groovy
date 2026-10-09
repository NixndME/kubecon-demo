package com.morpheuslab.aidash

import groovy.json.JsonSlurper
import groovy.util.logging.Slf4j

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** Gathers what the dashboard shows: chats, GPU, approvals, cost, activity, platform. */
@Slf4j
class Collector {
    Kube kube
    SelfApi api
    Map settings

    static final String CHATS = 'namespace=~"ai-.+", namespace!="ai-chat"'
    static final List<String> COLORS = ['#01A982', '#2F6FBA', '#7630EA', '#C7881A', '#C0567A', '#0D8C9E', '#6B7A89', '#8C6D2F']

    // change over the last 24 hours; a chat that started inside it counts in full
    static String day(String m) { "(${m} - (${m} offset 24h or ${m} * 0))" }

    static final String ACTIVITY = '{job="events"} | logfmt' +
        ' | (namespace="argocd" and kind="Application" and name=~"ai-.+" and name!="ai-chat") or (namespace=~"ai-.+" and namespace!="ai-chat" and (reason=~"FailedScheduling|BackOff|Failed|OOMKilling|Evicted" or (reason="Started" and name=~"ollama-.+")))' +
        ' | label_format chat=`{{ if eq .namespace "argocd" }}{{ .name }}{{ else }}{{ .namespace }}{{ end }}`' +
        ' | label_format what=`{{ if eq .reason "ResourceDeleted" }}Removed{{ else if hasPrefix "Updated sync status:  ->" .msg }}Ordered{{ else if eq .reason "Started" }}Ready{{ else if hasSuffix "-> Degraded" .msg }}Problem{{ else if eq .reason "FailedScheduling" }}Waiting{{ else if ne .namespace "argocd" }}Problem{{ else }}{{ end }}`' +
        ' | what != ""'

    Map collect() {
        long now = System.currentTimeMillis()
        Map v = [errors: [], updated: clock(now), updatedMs: now, links: links()]
        v.approvals = approvals(v)
        if (!kube.configured) {
            v.errors << 'Cluster access is not set up. Run the setup script or fill in the plugin settings.'
            return v
        }
        try {
            cluster(v)
        } catch (Exception e) {
            log.warn("AI on HKS: cluster read failed: ${e}")
            v.errors << "Could not read the cluster: ${e.message?.take(120)}".toString()
        }
        v
    }

    private Map links() {
        String g = (settings.grafanaUrl ?: '').replaceAll('/+$', ''), a = (settings.argocdUrl ?: '').replaceAll('/+$', '')
        [grafana: g ? "${g}/d/ai-chats?kiosk".toString() : null, cost: g ? "${g}/d/ai-cost?kiosk".toString() : null, argocd: a ?: null]
    }

    // ---------- Morpheus side, as the signed-in user ----------

    private List<Map> approvals(Map v) {
        Map r = api.get('/api/approvals?max=50&sort=dateCreated&direction=desc')
        if ((r._status as Integer) != 200) { v.canApprove = false; return [] }
        v.canApprove = true
        List<Map> out = []
        (r.approvals ?: []).findAll { (it.status as String)?.contains('requested') }.take(10).each { Map a ->
            Map d = api.get("/api/approvals/${a.id}").approval as Map ?: [:]
            (d.approvalItems ?: []).findAll { it.status == 'requested' }.each { Map it ->
                Map ref = it.reference ?: [:]
                Map app = ref.type == 'app' && ref.id ? (api.get("/api/apps/${ref.id}").app as Map ?: [:]) : [:]
                String desc = app.description ?: ''
                out << [itemId: it.id, name: ref.displayName ?: ref.name ?: d.name, by: a.requestBy,
                        owner: (desc =~ /login (\S+?),/).with { it.find() ? it.group(1) : '' },
                        model: (desc =~ /model ([^,]+)/).with { it.find() ? it.group(1).trim() : '' },
                        size: (desc =~ /size (\w+)/).with { it.find() ? it.group(1).capitalize() : '' },
                        kind: (ref.name as String ?: '').endsWith('-docs') ? 'Chat with your documents' : 'Private AI chat',
                        ago: ago(Instant.parse(a.dateCreated as String).toEpochMilli())]
            }
        }
        v.approvalsWaiting = out.size()
        out
    }

    private Map appIds() {
        Map r = api.get('/api/apps?max=200')
        ((r.apps ?: []) as List<Map>).collectEntries { [(it.name): it.id] }
    }

    // ---------- Cluster side, read-only token ----------

    private void cluster(Map v) {
        Map labels = [:]
        kube.logMetric("count by (namespace, owner, model, size) (count_over_time({${CHATS}, container=~\".+\"} [10m]))").each { Map r ->
            if (r.m.owner || !labels[r.m.namespace]) labels[r.m.namespace] = r.m
        }
        Map<String, Double> ready = byNs("sum by (namespace) (kube_pod_status_ready{${CHATS}, condition=\"true\"})")
        Map<String, Double> pending = byNs("sum by (namespace) (kube_pod_status_phase{${CHATS}, phase=\"Pending\"})")
        Map<String, Double> booked = byNs("sum by (namespace) (hami_vgpu_memory_allocated_bytes{${CHATS}})")
        Map<String, Double> used = byNs("sum by (namespace) (hami_vgpu_memory_used_bytes{${CHATS}})")
        Map<String, Double> qn = byLabel("sum by (chat) (${day('ai_chat_questions_total')})")
        Map<String, Double> total = byLabel("sum by (chat) (${day('ai_chat_cost_dollars_total')})")
        Map<String, Double> qcost = byLabel("sum by (chat) (${day('ai_chat_question_cost_dollars_total')})")
        Map ids = appIds()
        Map<String, List<Map>> questions = [:]
        kube.logs('{namespace="chat-cost"} |= "\\"type\\": \\"question\\"" |= "\\"asked\\""', 1440, 400).each { Map l ->
            Map q = new JsonSlurper().parseText(l.line as String) as Map
            long asked = Instant.parse(q.asked as String).toEpochMilli()
            questions.get(q.chat, []) << [ms: asked, when: clock(asked), who: q.who, question: q.question,
                                         gpu: fmt(q.busy_seconds as Double, 1), cpu: fmt(q.cpu_seconds as Double, 1), cost: money(q.cost as Double)]
        }
        List<String> names = byNs("sum by (namespace) (kube_pod_info{${CHATS}})").keySet().sort()
        v.chats = names.withIndex().collect { String ns, int i ->
            Map m = labels[ns] ?: [:]
            boolean isReady = (ready[ns] ?: 0) >= 2, waiting = (pending[ns] ?: 0) > 0 && !(booked[ns])
            double t = total[ns] ?: 0, q = qcost[ns] ?: 0
            String first = ns.replaceFirst('^ai-', '')
            [name: ns, color: COLORS[i % COLORS.size()], type: ns.endsWith('-docs') ? 'Docs' : 'Chat', owner: m.owner ?: '-', model: m.model ?: '-',
             size: (m.size ?: '-').capitalize(), status: isReady ? 'Ready' : waiting ? 'Waiting for GPU' : 'Starting',
             statusClass: isReady ? 'ok' : waiting ? 'warn' : 'info', booked: gb(booked[ns]), used: used[ns] ? gb(used[ns]) : '0 GB',
             questions: (qn[ns] ?: 0) as int, cost: money(t), kept: money(t - q), qcost: money(q), idle: t > 0 ? Math.round((t - q) / t * 100) : 0,
             perQuestion: qn[ns] ? money(q / qn[ns]) : '-', page: "https://${first}.${settings.domain ?: 'kubeforge.live'}".toString(),
             appId: ids[ns], list: (questions[ns] ?: []).take(10), more: Math.max(0, (questions[ns] ?: []).size() - 10), bookedBytes: booked[ns] ?: 0]
        }
        v.running = v.chats.count { it.status == 'Ready' }
        v.waiting = v.chats.count { it.status == 'Waiting for GPU' }
        gpu(v, booked)
        cost(v, qn, total, qcost)
        perChat(v)
        v.activity = activity(questions)
        platform(v)
    }

    private void gpu(Map v, Map<String, Double> booked) {
        double limit = kube.num('sum(hami_gpu_memory_limit_bytes)'), all = booked.values().sum() ?: 0
        double free = Math.max(0, limit - all)
        v.gpu = [total: gb(limit), booked: gb(all), bookedPct: limit ? Math.round(all / limit * 100) : 0,
                 segments: v.chats.findAll { it.bookedBytes > 0 }.collect { [name: it.name.replaceFirst('^ai-', ''), gb: it.booked, pct: limit ? it.bookedBytes / limit * 100 : 0, color: it.color] },
                 free: gb(free), freePct: limit ? free / limit * 100 : 0,
                 busy: Math.round(kube.num('avg(DCGM_FI_DEV_GPU_UTIL)')), temp: Math.round(kube.num('avg(DCGM_FI_DEV_GPU_TEMP)')),
                 power: Math.round(kube.num('sum(DCGM_FI_DEV_POWER_USAGE)')), name: settings.gpuName ?: 'NVIDIA T4',
                 spark: spark(kube.range('avg(DCGM_FI_DEV_GPU_UTIL)', 60, 120))]
    }

    private void cost(Map v, Map<String, Double> qn, Map<String, Double> total, Map<String, Double> qcost) {
        Map<String, Double> price = kube.prom('ai_price_dollars_per_hour').collectEntries { [(it.m.item): it.v] }
        double t = kube.num("sum(${day('ai_chat_cost_dollars_total')})"), q = kube.num("sum(${day('ai_chat_question_cost_dollars_total')})")
        double n = kube.num("sum(${day('ai_chat_questions_total')})")
        v.kpi = [questions: n as int, questionsCost: money(q), cost: money(t), idle: money(t - q)]
        v.cost = [questions: money(q), kept: money(t), idle: money(t - q), platform: money((price.platform ?: 0) * 24), perQuestion: n ? money(q / n) : '-',
                  prices: [['GPU node (whole machine)', price.gpu_node], ['Small chat', price.size_small], ['Medium chat', price.size_medium], ['Large chat', price.size_large]]
                      .findAll { it[1] != null }.collect { [label: it[0], value: money(it[1] as Double) + '/h'] }]
    }

    /** Cost per chat over the last 24 hours, also for chats removed since. Questions + idle = total. */
    private void perChat(Map v) {
        String by = 'chat, owner, size, model'
        Closure<Map> m = { String metric, String extra = '' ->
            kube.prom("sum by (${by}) (${day(metric + extra)})").collectEntries { [(it.m.chat): it] }
        }
        Map tot = m('ai_chat_cost_dollars_total'), q = m('ai_chat_question_cost_dollars_total'), n = m('ai_chat_questions_total')
        Map busy = m('ai_chat_busy_seconds_total'), up = m('ai_chat_running_seconds_total'), qcpu = m('ai_chat_question_cost_dollars_total', '{part="cpu"}')
        Map gpu = m('ai_chat_cost_dollars_total', '{part="gpu"}'), cpu = m('ai_chat_cost_dollars_total', '{part="cpu"}'), mem = m('ai_chat_cost_dollars_total', '{part="memory"}')
        double vcpu = kube.num('ai_price_dollars_per_hour{item="vcpu"}', 0.0281d)
        List<Map> rows = tot.findAll { k, r -> r.v > 0 }.collect { String chat, Map r ->
            double t = r.v, qc = q[chat]?.v ?: 0, nq = n[chat]?.v ?: 0, b = busy[chat]?.v ?: 0, u = up[chat]?.v ?: 0
            double usage = u ? b / u * 100 : 0, cores = b ? ((qcpu[chat]?.v ?: 0) / vcpu * 3600) / b : 0
            String advice = nq == 0 ? 'Not used' : usage < 5 ? 'Mostly idle: smaller size' : cores > 2.5 ? 'Spills to CPU: try Medium' : usage > 40 ? 'Very busy: bigger size' : 'Good fit'
            [chat: chat, owner: r.m.owner ?: '-', size: (r.m.size ?: '-').capitalize(), model: r.m.model ?: '-', questions: nq as int,
             busy: secs(b), usage: fmt(usage, 1) + '%', cores: nq ? fmt(cores, 1) : '-', coresClass: cores > 2.5 ? 'crit' : 'ok',
             total: money(t), qcost: money(qc), idle: money(t - qc), idlePct: t ? Math.round((t - qc) / t * 100) : 0, perQuestion: nq ? money(qc / nq) : '-',
             advice: advice, adviceClass: advice.startsWith('Good') ? 'ok' : advice.startsWith('Mostly') ? 'warn' : advice.startsWith('Not') ? 'muted' : 'crit',
             t: t, q: qc, g: gpu[chat]?.v ?: 0, c: cpu[chat]?.v ?: 0, mm: mem[chat]?.v ?: 0]
        }.sort { -it.t }
        double max = rows ? rows*.t.max() : 0
        rows.each { Map r ->
            r.qPct = max ? r.q / max * 100 : 0; r.iPct = max ? (r.t - r.q) / max * 100 : 0
            r.gPct = max ? r.g / max * 100 : 0; r.cPct = max ? r.c / max * 100 : 0; r.mPct = max ? r.mm / max * 100 : 0
        }
        v.perChat = rows
        double sumT = rows ? rows*.t.sum() as double : 0d, sumQ = rows ? rows*.q.sum() as double : 0d
        v.perChatTotal = [questions: rows ? rows*.questions.sum() : 0, total: money(sumT), qcost: money(sumQ), idle: money(sumT - sumQ)]
    }

    static String secs(double s) { s >= 3600 ? "${fmt(s / 3600, 1)} h" : s >= 60 ? "${Math.round(s / 60)} min" : "${Math.round(s)} s" }

    private List<Map> activity(Map<String, List<Map>> questions) {
        List<Map> out = kube.logs(ACTIVITY, 1440, 12).collect { Map l ->
            Map m = l.m
            String detail = [Ordered: 'Order approved, Argo CD is deploying it.', Ready: 'The model server started.', Removed: 'Removed. Its GPU memory is free again.',
                             Waiting: 'Not enough free GPU memory yet.', Problem: 'Not healthy. See Argo CD.'][m.what] ?: ''
            [ms: l.ms, when: clock(l.ms), text: "${m.chat}  ${m.what}".toString(), detail: detail,
             cls: [Ordered: 'info', Ready: 'ok', Removed: 'muted', Waiting: 'warn'][m.what] ?: 'crit']
        }
        kube.logs('{namespace="chat-cost"} |= "\\"type\\": \\"question\\"" |= "\\"asked\\""', 1440, 8).each { Map l ->
            Map q = new JsonSlurper().parseText(l.line as String) as Map
            long ms = Instant.parse(q.asked as String).toEpochMilli()
            out << [ms: ms, when: clock(ms), text: "${q.who} asked ${q.chat}".toString(), detail: "\"${(q.question as String)?.take(70)}\"".toString(), cls: 'ok']
        }
        out.sort { -it.ms }.take(50)
    }

    private void platform(Map v) {
        List<Map> apps = kube.argoApps()
        List<Map> nodes = kube.nodes()
        v.platform = [argoOk: apps.count { it.status?.health?.status == 'Healthy' && it.status?.sync?.status == 'Synced' }, argoAll: apps.size(),
                      nodesOk: nodes.count { n -> n.status?.conditions?.find { it.type == 'Ready' }?.status == 'True' }, nodesAll: nodes.size(),
                      hami: kube.num('count(hami_gpu_memory_limit_bytes)') > 0, loki: true]
    }

    // ---------- helpers ----------

    private Map<String, Double> byNs(String q) { kube.prom(q).collectEntries { [(it.m.namespace): it.v] } }
    private Map<String, Double> byLabel(String q) { kube.prom(q).collectEntries { [(it.m.chat): it.v] } }

    static String gb(Double bytes) { bytes ? "${fmt(bytes / 1073741824d, bytes < 1073741824d ? 1 : 0)} GB".toString() : '-' }
    static String fmt(Double d, int places) { d == null ? '-' : String.format("%.${places}f", d) }
    static String money(Double d) { d == null ? '-' : d >= 1 ? String.format('$%.2f', d) : d >= 0.01 ? String.format('$%.3f', d) : String.format('$%.5f', d) }

    static String clock(long ms) { DateTimeFormatter.ofPattern('HH:mm').withZone(ZoneId.systemDefault()).format(Instant.ofEpochMilli(ms)) }

    static String ago(long ms) {
        long s = (System.currentTimeMillis() - ms).intdiv(1000)
        s < 90 ? 'just now' : s < 3600 ? "${s.intdiv(60)} min ago" : s < 86400 ? "${s.intdiv(3600)} h ago" : "${s.intdiv(86400)} d ago"
    }

    /** SVG polyline points for a 300 x 40 sparkline, 0 to 100 percent. */
    static String spark(List<Double> values) {
        if (values.size() < 2) return ''
        values.withIndex().collect { Double val, int i -> "${String.format('%.1f', i * 300d / (values.size() - 1))},${String.format('%.1f', 38 - Math.min(100d, val ?: 0d) * 0.36)}" }.join(' ')
    }
}
