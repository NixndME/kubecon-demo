// Removes one private AI chat: checks the typed name, removes the Argo CD app
// (its pods, namespace and GPU slice go with it), then the Morpheus app.
import groovy.json.JsonSlurper

def chat = (customOptions?.aiChat ?: '').toString()
def typed = (customOptions?.aiConfirm ?: '').toString().trim()
if (!chat || typed != chat) {
  throw new Exception("Not removed. You typed '${typed}' but the chat is '${chat}'.")
}

def call = { String method, String url, String token ->
  def c = new URL(url).openConnection()
  c.requestMethod = method
  c.setRequestProperty('Authorization', 'Bearer ' + token)
  c.connectTimeout = 15000
  c.readTimeout = 60000
  def code = c.responseCode
  [code, (code < 400 ? c.inputStream : c.errorStream)?.text]
}

def name = 'ai-' + chat
def argo = call('DELETE', "__ARGOCD_URL__/api/v1/applications/${name}?cascade=true", '__ARGOCD_TOKEN__')
if (argo[0] != 200 && argo[0] != 404) {
  throw new Exception("Argo CD could not remove ${name}: ${argo[0]} ${argo[1]}")
}

def list = call('GET', "__MORPHEUS_URL__/api/apps?max=100&phrase=${name}", '__MORPHEUS_TOKEN__')
def app = new JsonSlurper().parseText(list[1] ?: '{}').apps?.find { it.name == name }
if (app) {
  call('DELETE', "__MORPHEUS_URL__/api/apps/${app.id}?removeInstances=off", '__MORPHEUS_TOKEN__')
}
return "Removed ${chat}. Its page, model server and GPU slice are freed."
