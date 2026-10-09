#!/usr/bin/env bash
# Sets up the Morpheus side of the AI chat demo. Safe to run again: every item is found by name and updated.
#   - Argo CD token for the "morpheus" account, Argo CD plugin settings
#   - Catalog items "Private AI chat" and "Remove AI chat", their inputs, lists, tasks and workflows
#   - Role "AI Developer", a developer user, and an approval policy for that user's orders
# Usage: scripts/setup-morpheus-catalog.sh <morpheus env file> <login file>
#   morpheus env file: MORPHEUS_URL, MORPHEUS_TOKEN (admin API token)
#   login file: APPS_USER, APPS_PASSWORD (Argo CD admin; also the developer user's password)
# Optional: DOMAIN (default kubeforge.live), REPO_URL, DEV_USER (default dev1)
set -euo pipefail

set -a; . "${1:?morpheus env file}"; . "${2:?login file}"; set +a
DOMAIN="${DOMAIN:-kubeforge.live}"
ARGOCD="https://argocd.$DOMAIN"
REPO_URL="${REPO_URL:-https://github.com/NixndME/kubecon-demo.git}"
DEV_USER="${DEV_USER:-dev1}"
M="${MORPHEUS_URL%/}"

api() { # method path [json]
  curl -sf -X "$1" -H "Authorization: Bearer $MORPHEUS_TOKEN" -H "Content-Type: application/json" "$M$2" ${3:+-d "$3"}
}
# Id of an item by its name, from a list call (empty if not found)
find_id() { # path list-key name-field name
  api GET "$1?max=500" | jq -r --arg k "$2" --arg f "$3" --arg n "$4" '.[$k][]? | select(.[$f]==$n) | .id' | head -1
}
# Create or update: upsert <list path> <list key> <name field> <name> <wrapper key> <json body>
upsert() {
  local id; id=$(find_id "$1" "$2" "$3" "$4")
  if [ -n "$id" ]; then api PUT "$1/$id" "$6" >/dev/null; echo "$id"
  else api POST "$1" "$6" | jq -r --arg w "$5" '.[$w].id'; fi
}

echo "==> Argo CD token for the morpheus account"
admin=$(jq -n --arg u "$APPS_USER" --arg p "$APPS_PASSWORD" '{username:$u,password:$p}' \
  | curl -sf -H 'Content-Type: application/json' -d @- "$ARGOCD/api/v1/session" | jq -r .token)
TOKEN=$(curl -sf -X POST -H "Authorization: Bearer $admin" -H 'Content-Type: application/json' \
  -d '{"id":"morpheus"}' "$ARGOCD/api/v1/account/morpheus/token" | jq -r .token)
[ -n "$TOKEN" ] && [ "$TOKEN" != null ]

echo "==> Argo CD plugin settings"
pid=$(api GET "/api/plugins?max=100" | jq -r '.plugins[] | select(.code=="argocd") | .id')
if [ -n "$pid" ]; then
  api PUT "/api/plugins/$pid" "$(jq -n --arg u "$ARGOCD" --arg t "$TOKEN" \
    '{plugin:{config:{argocdUrl:$u, argocdToken:$t, argocdVerifyTls:"on", argocdDefaultProject:"default"}}}')" >/dev/null
else echo "    Argo CD plugin not installed, skipped"; fi

echo "==> Lists"
models=$(upsert /api/library/option-type-lists optionTypeLists name "AI models" optionTypeList "$(jq -n '{optionTypeList:{
  name:"AI models", type:"manual", description:"Small models that fit a GPU slice",
  initialDataset:([{name:"Llama 3.2 3B (fast, general)",value:"llama3.2:3b"},{name:"Phi-4 mini 3.8B (MIT license)",value:"phi4-mini"}]|tojson)}}')")
translate='for (var i = 0; i < data.items.length; i++) { var a = data.items[i]; var p = {}; var ps = (a.spec.source.helm || {}).parameters || []; for (var j = 0; j < ps.length; j++) { p[ps[j].name] = ps[j].value; } var h = (a.status && a.status.health && a.status.health.status) || "?"; results.push({name: p.team + " (" + p.model + ", " + (p.ownerName || p.requestedBy || "?") + ", " + (h == "Healthy" ? "running" : h == "Progressing" ? "starting or waiting for a GPU slice" : h) + ")", value: p.team}); }'
chats=$(upsert /api/library/option-type-lists optionTypeLists name "AI chats (live)" optionTypeList "$(jq -n \
  --arg url "$ARGOCD/api/v1/applications?selector=kubecon-demo/catalog%3Dteam-ai" --arg t "$TOKEN" --arg tr "$translate" '{optionTypeList:{
  name:"AI chats (live)", type:"rest", description:"Team AI chats that exist now, read from Argo CD",
  sourceUrl:$url, sourceMethod:"GET", realTime:true, translationScript:$tr,
  config:{sourceHeaders:[{name:"Authorization",value:("Bearer " + $t)}]}}}')")

echo "==> Inputs"
in_team=$(upsert /api/library/option-types optionTypes name "AI team name" optionType "$(jq -n --arg d "$DOMAIN" '{optionType:{
  name:"AI team name", fieldName:"aiTeam", fieldLabel:"Team", type:"text", required:true, displayOrder:3,
  verifyPattern:"^[a-z][a-z0-9]{1,14}$", placeHolder:"alpha",
  helpBlock:("Lowercase letters and numbers, 2 to 15 characters. Your chat will be at https://<team>." + $d)}}')")
in_model=$(upsert /api/library/option-types optionTypes name "AI model" optionType "$(jq -n --argjson l "$models" '{optionType:{
  name:"AI model", fieldName:"aiModel", fieldLabel:"Model", type:"select", required:true, displayOrder:4,
  optionList:{id:$l}, defaultValue:"llama3.2:3b", helpBlock:"Runs on one GPU slice"}}')")
in_name=$(upsert /api/library/option-types optionTypes name "AI owner name" optionType "$(jq -n '{optionType:{
  name:"AI owner name", fieldName:"aiName", fieldLabel:"Your name", type:"text", required:true, displayOrder:1,
  verifyPattern:"^[A-Za-z][A-Za-z .-]{1,49}$", placeHolder:"Jane Doe"}}')")
in_email=$(upsert /api/library/option-types optionTypes name "AI owner email" optionType "$(jq -n '{optionType:{
  name:"AI owner email", fieldName:"aiEmail", fieldLabel:"Your email", type:"text", required:true, displayOrder:2,
  verifyPattern:"^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}$", placeHolder:"jane@example.com",
  helpBlock:"You log in to your chat with this email"}}')")
in_chat=$(upsert /api/library/option-types optionTypes name "AI chat to remove" optionType "$(jq -n --argjson l "$chats" '{optionType:{
  name:"AI chat to remove", fieldName:"aiChat", fieldLabel:"Chat", type:"select", required:true, displayOrder:1,
  optionList:{id:$l}, helpBlock:"Chats running in the HKS cluster now"}}')")
in_confirm=$(upsert /api/library/option-types optionTypes name "AI chat remove confirm" optionType "$(jq -n '{optionType:{
  name:"AI chat remove confirm", fieldName:"aiConfirm", fieldLabel:"Type the chat name to confirm", type:"text", required:true,
  displayOrder:2, helpBlock:"The chat, its model server and its GPU slice are removed. This cannot be undone."}}')")
# Old password input from an earlier version
old=$(find_id /api/library/option-types optionTypes name "AI chat password"); [ -z "$old" ] || api DELETE "/api/library/option-types/$old" >/dev/null || true

echo "==> Tasks"
headers=$(jq -n --arg t "$TOKEN" '[{key:"Authorization",value:("Bearer " + $t)},{key:"Content-Type",value:"application/json"}]|tojson')
body=$(jq -cn --arg repo "$REPO_URL" '{
  metadata:{name:"team-<%=customOptions.aiTeam%>-ai", namespace:"argocd",
    labels:{"kubecon-demo/catalog":"team-ai","kubecon-demo/team":"<%=customOptions.aiTeam%>"},
    annotations:{"kubecon-demo/requested-by":"<%=username%>"}},
  spec:{project:"default",
    source:{repoURL:$repo, targetRevision:"main", path:"gitops/charts/team-ai",
      helm:{parameters:[{name:"team",value:"<%=customOptions.aiTeam%>"},{name:"model",value:"<%=customOptions.aiModel%>"},
        {name:"requestedBy",value:"<%=username%>"},{name:"ownerName",value:"<%=customOptions.aiName%>"},
        {name:"ownerEmail",value:"<%=customOptions.aiEmail%>"},{name:"chatPassword",value:"<%=results.aiChatPassword%>"}]}},
    destination:{server:"https://kubernetes.default.svc", namespace:"team-<%=customOptions.aiTeam%>"},
    syncPolicy:{automated:{prune:true,selfHeal:true}}}}')
t_pass=$(upsert /api/tasks tasks name "Make AI chat password" task "$(jq -n '{task:{
  name:"Make AI chat password", code:"aiChatPassword", taskType:{code:"javascriptTask"}, executeTarget:"local", resultType:"value",
  taskOptions:{jsScript:"var c = \"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789\"; var p = \"\"; for (var i = 0; i < 16; i++) { p += c.charAt(Math.floor(Math.random() * c.length)); } p;"}}}')")
t_create=$(upsert /api/tasks tasks name "Create private AI chat" task "$(jq -n --arg u "$ARGOCD/api/v1/applications" --arg b "$body" --arg h "$headers" '{task:{
  name:"Create private AI chat", taskType:{code:"httpTask"}, executeTarget:"local",
  taskOptions:{webUrl:$u, webMethod:"POST", webBody:$b, webHeaders:$h}}}')")
t_link=$(upsert /api/tasks tasks name "Show AI chat link" task "$(jq -n --arg d "$DOMAIN" '{task:{
  name:"Show AI chat link", taskType:{code:"javascriptTask"}, executeTarget:"local",
  taskOptions:{jsScript:("\"Your private AI chat: https://<%=customOptions.aiTeam%>." + $d + " | Login: <%=customOptions.aiEmail%> | Password: <%=results.aiChatPassword%> | Ready in about 2 minutes. If all GPU slices are in use, it starts when one is free.\"")}}}')")
t_check=$(upsert /api/tasks tasks name "Check AI chat remove confirm" task "$(jq -n '{task:{
  name:"Check AI chat remove confirm", taskType:{code:"javascriptTask"}, executeTarget:"local",
  taskOptions:{jsScript:"var chat = \"<%=customOptions.aiChat%>\"; var typed = \"<%=customOptions.aiConfirm%>\"; if (chat == \"\" || typed != chat) { throw \"Not removed: you typed \" + typed + \" but the chat is \" + chat; } \"Confirmed: removing \" + chat;"}}}')")
t_remove=$(upsert /api/tasks tasks name "Remove private AI chat" task "$(jq -n --arg u "$ARGOCD/api/v1/applications/team-<%=customOptions.aiChat%>-ai?cascade=true" --arg h "$headers" '{task:{
  name:"Remove private AI chat", taskType:{code:"httpTask"}, executeTarget:"local",
  taskOptions:{webUrl:$u, webMethod:"DELETE", webHeaders:$h}}}')")

echo "==> Workflows"
w_order=$(upsert /api/task-sets taskSets name "Order private AI chat" taskSet "$(jq -n --argjson p "$t_pass" --argjson a "$t_create" --argjson b "$t_link" \
  --argjson i0 "$in_name" --argjson i1 "$in_email" --argjson i2 "$in_team" --argjson i3 "$in_model" '{taskSet:{
  name:"Order private AI chat", type:"operation", description:"Creates a private AI chat for a team on one GPU slice",
  tasks:[{taskId:$p, taskPhase:"operation"},{taskId:$a, taskPhase:"operation"},{taskId:$b, taskPhase:"operation"}], optionTypes:[$i0,$i1,$i2,$i3]}}')")
w_remove=$(upsert /api/task-sets taskSets name "Remove private AI chat" taskSet "$(jq -n --argjson c "$t_check" --argjson a "$t_remove" --argjson i "$in_chat" --argjson k "$in_confirm" '{taskSet:{
  name:"Remove private AI chat", type:"operation", description:"Removes a team AI chat and frees its GPU slice",
  tasks:[{taskId:$c, taskPhase:"operation"},{taskId:$a, taskPhase:"operation"}], optionTypes:[$i,$k]}}')")

echo "==> Catalog items"
c_order=$(upsert /api/catalog-item-types catalogItemTypes name "Private AI chat" catalogItemType "$(jq -n --argjson w "$w_order" \
  --argjson i0 "$in_name" --argjson i1 "$in_email" --argjson i2 "$in_team" --argjson i3 "$in_model" --arg d "$DOMAIN" '{catalogItemType:{
  name:"Private AI chat", type:"workflow", workflow:{id:$w}, context:"appliance", optionTypes:[$i0,$i1,$i2,$i3],
  enabled:true, featured:true, visibility:"public",
  description:"Your own AI chat on the HKS GPU. Tell us who you are, your team and the model.",
  content:("## Private AI chat\n\nYou get your own chat page at **https://<team>." + $d + "**, running a small AI model on one slice of the HKS GPU.\n\n- You log in with **your email**. The password is made for you and shown in this order once it runs (Order History or Executions).\n- Your data stays in the cluster.\n- An admin may need to approve the order.\n- The page is ready about 2 minutes after the order runs. See Executions for the link.")}}')")
c_remove=$(upsert /api/catalog-item-types catalogItemTypes name "Remove AI chat" catalogItemType "$(jq -n --argjson w "$w_remove" --argjson i "$in_chat" --argjson k "$in_confirm" '{catalogItemType:{
  name:"Remove AI chat", type:"workflow", workflow:{id:$w}, context:"appliance", optionTypes:[$i,$k],
  enabled:true, featured:false, visibility:"public",
  description:"Removes a team AI chat and frees its GPU slice.", content:"Pick a running chat, then type its name to confirm. Its page, model server and GPU slice are removed."}}')")

echo "==> Role, developer user, approval"
role=$(upsert /api/roles roles authority "AI Developer" role "$(jq -n '{role:{authority:"AI Developer",
  description:"Orders private AI chats from the Service Catalog", roleType:"user"}}')")
api PUT "/api/roles/$role/update-persona" '{"personaCode":"serviceCatalog","access":"full"}' >/dev/null
api PUT "/api/roles/$role/update-persona" '{"personaCode":"standard","access":"none"}' >/dev/null
api PUT "/api/roles/$role/update-group" '{"groupId":1,"access":"full"}' >/dev/null || true
for c in "$c_order" "$c_remove"; do api PUT "/api/roles/$role/update-catalog-item-type" "{\"catalogItemTypeId\":$c,\"access\":\"full\"}" >/dev/null; done
for p in service-catalog:full service-catalog-dashboard:read service-catalog-inventory:full provisioning-execute-workflow:full executions:read services-cypher:none; do
  api PUT "/api/roles/$role/update-permission" "{\"permissionCode\":\"${p%%:*}\",\"access\":\"${p#*:}\"}" >/dev/null || echo "    could not set ${p%%:*}"
done
user=$(api GET "/api/users?max=500" | jq -r --arg u "$DEV_USER" '.users[] | select(.username==$u) | .id' | head -1)
if [ -z "$user" ]; then
  user=$(api POST /api/users "$(jq -n --arg u "$DEV_USER" --arg d "$DOMAIN" --arg p "$APPS_PASSWORD" --argjson r "$role" '{user:{
    username:$u, email:($u + "@" + $d), firstName:"Dev", lastName:"One", password:$p, roles:[{id:$r}], receiveNotifications:false}}')" | jq -r .user.id)
fi
pol=$(api GET "/api/policies?max=500" | jq -r '.policies[] | select(.name=="Approve AI chat orders") | .id' | head -1)
[ -n "$pol" ] || api POST /api/policies "$(jq -n --argjson u "$user" '{policy:{name:"Approve AI chat orders",
  description:"An admin approves every AI chat order from the developer user", policyType:{code:"workflowApproval"},
  enabled:true, refType:"User", refId:$u, user:{id:$u}, config:{accountIntegrationId:-100}}}')" >/dev/null

echo "Done. Catalog items $c_order and $c_remove, role $role, user $DEV_USER ($user)."
echo "The developer switches to the catalog at $M/user-settings/switch-persona/serviceCatalog"
