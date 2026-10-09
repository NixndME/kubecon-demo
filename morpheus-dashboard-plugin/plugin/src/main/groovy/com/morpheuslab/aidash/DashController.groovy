package com.morpheuslab.aidash

import com.morpheusdata.core.MorpheusContext
import com.morpheusdata.core.Plugin
import com.morpheusdata.model.Permission
import com.morpheusdata.views.HTMLResponse
import com.morpheusdata.views.ViewModel
import com.morpheusdata.web.PluginController
import com.morpheusdata.web.Route
import groovy.util.logging.Slf4j

/** Refresh of the dashboard content, and Approve / Reject of a waiting order. */
@Slf4j
class DashController implements PluginController {
    AiDashPlugin plugin
    MorpheusContext morpheus

    DashController(AiDashPlugin plugin, MorpheusContext morpheus) { this.plugin = plugin; this.morpheus = morpheus }

    String getCode() { 'hks-ai-dashboard-controller' }
    String getName() { 'AI on HKS Controller' }
    MorpheusContext getMorpheus() { morpheus }
    Plugin getPlugin() { plugin }

    // Approving also needs the user's own approval rights: Morpheus checks them on the API call
    List<Route> getRoutes() {
        Permission read = Permission.build(AiDashPlugin.PERMISSION, 'read')
        [Route.build('/hks-ai-dashboard/content', 'content', read),
         Route.build('/hks-ai-dashboard/approval', 'approval', read)]
    }

    /** The dashboard content again, for the 30 s refresh. */
    def content(ViewModel<Map> model) {
        ViewModel<Map> m = new ViewModel<>()
        m.object = AiDashItemProvider.view(plugin)
        plugin.getRenderer().renderTemplate('hbs/dash-main', m)
    }

    /** Approves or rejects one approval item with the user's own rights, then goes back to the dashboard. */
    def approval(ViewModel<Map> model) {
        def req = model.request
        String done = 'failed'
        if ('POST'.equalsIgnoreCase(req?.method as String)) {
            String id = req.getParameter('item') as String, action = req.getParameter('do') as String
            if (id?.isLong() && action in ['approve', 'deny']) {
                Map r = SelfApi.of(req).put("/api/approval-items/${id}/${action}", [:])
                boolean ok = (r._status as Integer) < 300 && r.success != false
                log.info("AI on HKS: ${model.user?.username} ${action} approval item ${id}: ${ok ? 'ok' : r._status}")
                done = ok ? (action == 'approve' ? 'approved' : 'rejected') : 'failed'
            }
        }
        String url = "/operations/dashboard?done=${done}"
        try {
            if (model.response && !model.response.committed) { model.response.sendRedirect(url); return HTMLResponse.success('') }
        } catch (Throwable ignored) { }
        HTMLResponse.success("<!doctype html><html><head><meta http-equiv=\"refresh\" content=\"0;url=${url}\"></head><body><a href=\"${url}\">Back</a></body></html>")
    }
}
