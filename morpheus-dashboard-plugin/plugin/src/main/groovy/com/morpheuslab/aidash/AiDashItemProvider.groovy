package com.morpheuslab.aidash

import com.morpheusdata.core.MorpheusContext
import com.morpheusdata.core.Plugin
import com.morpheusdata.core.dashboard.AbstractDashboardItemTypeProvider
import com.morpheusdata.model.DashboardItem
import com.morpheusdata.model.DashboardItemType
import com.morpheusdata.views.HTMLResponse
import com.morpheusdata.views.ViewModel
import groovy.util.logging.Slf4j

/** The dashboard's one wide item: everything is drawn here, and redrawn every 30 s by the page script. */
@Slf4j
class AiDashItemProvider extends AbstractDashboardItemTypeProvider {
    static final String CODE = 'hks-ai-dashboard-main'
    AiDashPlugin plugin
    MorpheusContext morpheusContext

    AiDashItemProvider(AiDashPlugin plugin, MorpheusContext context) { this.plugin = plugin; this.morpheusContext = context }

    MorpheusContext getMorpheus() { morpheusContext }
    Plugin getPlugin() { plugin }
    String getCode() { CODE }
    String getName() { 'AI on HKS' }

    @Override
    DashboardItemType getDashboardItemType() {
        DashboardItemType t = new DashboardItemType()
        t.name = getName()
        t.code = CODE
        t.category = 'hks-ai-dashboard'
        t.title = 'AI on HKS'
        t.description = 'Chats, GPU, approvals and cost'
        t.uiSize = 'xl'
        t.templatePath = 'hbs/dash-main'
        t.scriptPath = 'hks-ai-dashboard.js'
        t
    }

    @Override
    HTMLResponse renderDashboardItem(DashboardItem item, Map<String, Object> opts) {
        ViewModel<Map> model = new ViewModel<>()
        model.object = view(plugin)
        getRenderer().renderTemplate('hbs/dash-main', model)
    }

    /** The view model, also used by the refresh route. */
    static Map view(AiDashPlugin plugin) {
        Map v
        try {
            v = plugin.collect()
        } catch (Throwable t) {
            log.warn("AI on HKS: collect failed: ${t}")
            v = [errors: ["Could not build the dashboard: ${t.message?.take(120)}".toString()]]
        }
        v.csrf = Csrf.token()
        Object req = Req.current()
        String flash = req?.getParameter('done') as String
        v.flash = [approved: 'Approved. The chat is being created.', rejected: 'Rejected.', failed: 'That did not work. You may not have permission to approve.'][flash]
        v
    }
}
