package com.morpheuslab.aidash

import groovy.util.logging.Slf4j

/** The CSRF token for forms and API calls. */
@Slf4j
class Csrf {
    static Map token() {
        try {
            Object req = Req.current()
            Object tok = req?.getAttribute('_csrf') ?: req?.getAttribute('org.springframework.security.web.csrf.CsrfToken')
            if (tok) return [param: tok.parameterName as String, header: tok.headerName as String, value: tok.token as String]
        } catch (Throwable t) {
            log.warn("AI on HKS: no CSRF token available: ${t}")
        }
        [param: '_csrf', header: 'X-CSRF-TOKEN', value: '']
    }
}

/** The current web request. */
class Req {
    static Object current() {
        try {
            ClassLoader cl = Thread.currentThread().contextClassLoader
            Class rch = Class.forName('org.springframework.web.context.request.RequestContextHolder', true, cl)
            return rch.getMethod('getRequestAttributes').invoke(null)?.getRequest()
        } catch (Throwable ignored) {
            return null
        }
    }
}
