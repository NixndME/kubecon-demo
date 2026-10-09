package com.morpheuslab.aidash

import groovy.json.JsonOutput
import groovy.json.JsonSlurper
import groovy.util.logging.Slf4j

import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import java.security.cert.X509Certificate

/** Calls this Morpheus' own REST API as the signed-in user. */
@Slf4j
class SelfApi {
    String base
    String cookie
    Map csrf

    /** Uses the host, session cookie and CSRF token of the current request. */
    static SelfApi of(Object request) {
        String host = request?.getHeader('Host') ?: request?.serverName
        new SelfApi(base: "https://${host}", cookie: request?.getHeader('Cookie') as String, csrf: Csrf.token())
    }

    Map get(String path) { call('GET', path, null) }
    Map post(String path, Map body) { call('POST', path, body) }
    Map put(String path, Map body) { call('PUT', path, body) }
    Map delete(String path) { call('DELETE', path, null) }

    /** Reads a Morpheus UI page or form as text. */
    String html(String path) {
        HttpURLConnection c = open('GET', path, 'text/html')
        int code = c.responseCode
        code < 400 ? c.inputStream.getText('UTF-8') : ''
    }

    /** Posts a Morpheus UI form, field by field, like the browser does. Returns [status, text]. */
    Map form(String path, List<List> fields) {
        HttpURLConnection c = open('POST', path, 'text/html')
        c.setRequestProperty('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8')
        List<List> all = fields + (csrf?.value ? [[csrf.param, csrf.value]] : [])
        String body = all.collect { URLEncoder.encode(it[0] as String, 'UTF-8') + '=' + URLEncoder.encode((it[1] ?: '') as String, 'UTF-8') }.join('&')
        c.doOutput = true
        c.outputStream.withWriter('UTF-8') { it << body }
        int code = c.responseCode
        [status: code, text: (code < 400 ? c.inputStream : c.errorStream)?.getText('UTF-8') ?: '']
    }

    private HttpURLConnection open(String method, String path, String accept) {
        HttpURLConnection c = (HttpURLConnection) new URL(base + path).openConnection()
        if (c instanceof HttpsURLConnection) {
            c.SSLSocketFactory = TRUST_ALL.socketFactory
            c.hostnameVerifier = { h, s -> true }
        }
        c.requestMethod = method
        c.connectTimeout = 10000
        c.readTimeout = 60000
        c.instanceFollowRedirects = false
        c.setRequestProperty('Accept', accept)
        c.setRequestProperty('X-Requested-With', 'XMLHttpRequest')
        if (cookie) c.setRequestProperty('Cookie', cookie)
        if (csrf?.value) c.setRequestProperty(csrf.header as String, csrf.value as String)
        c
    }

    Map call(String method, String path, Map body) {
        HttpURLConnection c = (HttpURLConnection) new URL(base + path).openConnection()
        if (c instanceof HttpsURLConnection) {
            c.SSLSocketFactory = TRUST_ALL.socketFactory
            c.hostnameVerifier = { h, s -> true }
        }
        c.requestMethod = method
        c.connectTimeout = 10000
        c.readTimeout = 60000
        c.instanceFollowRedirects = false
        c.setRequestProperty('Accept', 'application/json')
        c.setRequestProperty('Content-Type', 'application/json')
        if (cookie) c.setRequestProperty('Cookie', cookie)
        if (csrf?.value) c.setRequestProperty(csrf.header as String, csrf.value as String)
        if (body != null) {
            c.doOutput = true
            c.outputStream.withWriter('UTF-8') { it << JsonOutput.toJson(body) }
        }
        int code = c.responseCode
        String text = (code < 400 ? c.inputStream : c.errorStream)?.getText('UTF-8') ?: ''
        Map out
        try {
            Object parsed = text ? new JsonSlurper().parseText(text) : [:]
            out = parsed instanceof Map ? (Map) parsed : [data: parsed]
        } catch (Exception ignored) {
            out = [raw: text.take(300)]
        }
        out._status = code
        out
    }

    static final SSLContext TRUST_ALL = trustAll()

    // Morpheus often has a self-signed certificate and we only call ourselves
    private static SSLContext trustAll() {
        TrustManager tm = new X509TrustManager() {
            void checkClientTrusted(X509Certificate[] c, String a) { }
            void checkServerTrusted(X509Certificate[] c, String a) { }
            X509Certificate[] getAcceptedIssuers() { new X509Certificate[0] }
        }
        SSLContext ctx = SSLContext.getInstance('TLS')
        ctx.init(null, [tm] as TrustManager[], null)
        ctx
    }
}
