package com.morpheuslab.aidash

import groovy.json.JsonSlurper
import groovy.util.logging.Slf4j

import javax.net.ssl.HttpsURLConnection

/** Reads the cluster through its API with a read-only token: Prometheus and Loki through the service proxy. */
@Slf4j
class Kube {
    String url, token

    static final String PROM = '/api/v1/namespaces/monitoring/services/prometheus-k8s:9090/proxy'
    static final String LOKI = '/api/v1/namespaces/loki/services/loki:3100/proxy'

    boolean isConfigured() { url && token }

    Object get(String path) {
        HttpURLConnection c = (HttpURLConnection) new URL(url.replaceAll('/+$', '') + path).openConnection()
        if (c instanceof HttpsURLConnection) {
            // the cluster API uses its own certificate authority
            c.SSLSocketFactory = SelfApi.TRUST_ALL.socketFactory
            c.hostnameVerifier = { h, s -> true }
        }
        c.connectTimeout = 5000
        c.readTimeout = 15000
        c.setRequestProperty('Authorization', "Bearer ${token}")
        c.setRequestProperty('Accept', 'application/json')
        int code = c.responseCode
        if (code >= 300) throw new IOException("cluster answered ${code} for ${path.take(80)}")
        new JsonSlurper().parseText(c.inputStream.getText('UTF-8'))
    }

    static String q(String s) { URLEncoder.encode(s, 'UTF-8') }

    /** Instant PromQL query: list of [labels, value]. */
    List<Map> prom(String query) {
        (get("${PROM}/api/v1/query?query=${q(query)}").data.result as List<Map>).collect { [m: it.metric ?: [:], v: (it.value[1] as String) as Double] }
    }

    /** One number, or the fallback when the query has no result. */
    Double num(String query, Double fallback = 0d) {
        List<Map> r = prom(query)
        r ? (r[0].v.isNaN() ? fallback : r[0].v) : fallback
    }

    /** Values of a range query, for a small sparkline. */
    List<Double> range(String query, int minutes, int stepSeconds) {
        long end = System.currentTimeMillis().intdiv(1000), start = end - minutes * 60
        List r = get("${PROM}/api/v1/query_range?query=${q(query)}&start=${start}&end=${end}&step=${stepSeconds}").data.result as List
        r ? (r[0].values as List).collect { ((it[1] as String) as Double) } : []
    }

    /** Log lines, newest first: list of [labels, line, time in ms]. */
    List<Map> logs(String query, int minutes, int limit) {
        long end = System.currentTimeMillis() * 1000000L, start = end - minutes * 60L * 1000000000L
        List streams = get("${LOKI}/loki/api/v1/query_range?query=${q(query)}&start=${start}&end=${end}&limit=${limit}&direction=backward").data.result as List
        List<Map> out = []
        streams.each { s -> (s.values as List).each { v -> out << [m: s.stream, line: v[1], ms: ((v[0] as String) as Long).intdiv(1000000L)] } }
        out.sort { -it.ms }.take(limit)
    }

    /** Loki metric query: list of [labels, value]. */
    List<Map> logMetric(String query) {
        (get("${LOKI}/loki/api/v1/query?query=${q(query)}").data.result as List<Map>).collect { [m: it.metric ?: [:], v: (it.value[1] as String) as Double] }
    }

    List<Map> argoApps() { get('/apis/argoproj.io/v1alpha1/namespaces/argocd/applications').items as List<Map> }

    List<Map> nodes() { get('/api/v1/nodes').items as List<Map> }
}
