package com.morpheuslab.aidash

import com.morpheusdata.core.Plugin
import com.morpheusdata.model.OptionType
import com.morpheusdata.model.Permission
import com.morpheusdata.views.HandlebarsRenderer
import groovy.json.JsonSlurper

/** AI on HKS: a dashboard for private AI chats on HKS. */
class AiDashPlugin extends Plugin {

    static final String PERMISSION = 'hks-ai-dashboard'

    @Override
    String getCode() { 'hks-ai-dashboard' }

    @Override
    void initialize() {
        setName('AI on HKS')
        setDescription('Chats, GPU, approvals and cost of the private AI chats on HKS')
        // a plugin with routes needs its own renderer
        HandlebarsRenderer r = new HandlebarsRenderer('renderer', getClassLoader())
        r.registerAssetHelper(getName())
        r.registerNonceHelper(morpheus.getWebRequest())
        r.registerI18nHelper(this, morpheus)
        setRenderer(r)
        // plugin routes are only served with a permission; read lets a role use the refresh and the buttons
        Permission p = Permission.build('AI on HKS', PERMISSION, [Permission.AccessType.none, Permission.AccessType.read])
        p.subCategory = 'AI on HKS'
        setPermissions([p])
        registerProvider(new AiDashItemProvider(this, morpheus))
        registerProvider(new AiDashboardProvider(this, morpheus))
        controllers.add(new DashController(this, morpheus))
    }

    @Override
    List<OptionType> getSettings() {
        [setting('Cluster API address', 'kubeUrl', 'For example https://k8s.example.com:6443', OptionType.InputType.TEXT, 0),
         setting('Cluster read-only token', 'kubeToken', 'Token of the morpheus-dashboard service account', OptionType.InputType.PASSWORD, 1),
         setting('Grafana address', 'grafanaUrl', 'For the Open Grafana links', OptionType.InputType.TEXT, 2),
         setting('Argo CD address', 'argocdUrl', 'For the Open Argo CD link', OptionType.InputType.TEXT, 3),
         setting('Chat domain', 'domain', 'Chats open at https://<first name>.<domain>', OptionType.InputType.TEXT, 4)]
    }

    private OptionType setting(String label, String field, String help, OptionType.InputType type, int order) {
        new OptionType(name: label, code: "hks-ai-dashboard.${field}", fieldName: field, fieldLabel: label, inputType: type,
            helpText: help, required: false, displayOrder: order)
    }

    /** Current settings as a map. */
    Map settingsMap() {
        try {
            String raw = morpheus.getSettings(this).blockingGet()
            return raw ? new JsonSlurper().parseText(raw) as Map : [:]
        } catch (Throwable ignored) {
            return [:]
        }
    }

    /** Everything the dashboard shows, read now. */
    Map collect() {
        Map s = settingsMap()
        new Collector(kube: new Kube(url: s.kubeUrl, token: s.kubeToken), api: SelfApi.of(Req.current()), settings: s).collect()
    }

    @Override
    void onDestroy() { }
}
