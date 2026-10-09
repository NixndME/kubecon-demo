package com.morpheuslab.aidash

import com.morpheusdata.core.MorpheusContext
import com.morpheusdata.core.Plugin
import com.morpheusdata.core.dashboard.AbstractDashboardProvider
import com.morpheusdata.model.Dashboard
import com.morpheusdata.model.DashboardItem
import com.morpheusdata.views.HTMLResponse
import com.morpheusdata.views.ViewModel
import groovy.util.logging.Slf4j

/** The "AI on HKS" dashboard on Operations > Dashboard. */
@Slf4j
class AiDashboardProvider extends AbstractDashboardProvider {
    Plugin plugin
    MorpheusContext morpheusContext

    AiDashboardProvider(Plugin plugin, MorpheusContext context) { this.plugin = plugin; this.morpheusContext = context }

    MorpheusContext getMorpheus() { morpheusContext }
    Plugin getPlugin() { plugin }
    String getCode() { 'hks-ai-dashboard' }
    String getName() { 'AI on HKS' }

    @Override
    Dashboard getDashboard() {
        Dashboard d = new Dashboard()
        d.name = getName()
        d.code = getCode()
        d.dashboardId = 'hks-ai-dashboard'
        d.category = 'hks-ai-dashboard'
        d.title = 'AI on HKS'
        d.description = 'Private AI chats on HKS'
        // must be true, or Morpheus can not select this dashboard and never renders it
        d.defaultDashboard = true
        d.enabled = true
        d.sourceType = 'system'
        d.templatePath = 'hbs/dash-shell'
        // must not be empty, or Morpheus unloads the plugin
        d.scriptPath = 'hks-ai-dashboard.js'
        DashboardItem item = null
        try {
            def type = morpheus.getDashboard().getDashboardItemType(AiDashItemProvider.CODE).blockingGet()
            if (type) item = new DashboardItem(type: type, itemRow: 0, itemColumn: 0, itemGroup: 'hks-ai-dashboard', groupRow: 0)
        } catch (Throwable t) {
            log.warn("AI on HKS: dashboard item not ready yet: ${t}")
        }
        d.dashboardItems = item ? [item] : []
        d
    }

    @Override
    HTMLResponse renderDashboard(Dashboard dashboard, Map<String, Object> opts) {
        ViewModel<Dashboard> model = new ViewModel<>()
        model.object = dashboard
        model.opts = opts
        getRenderer().renderTemplate(dashboard.templatePath, model)
    }
}
