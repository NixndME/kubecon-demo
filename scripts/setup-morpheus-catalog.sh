#!/usr/bin/env bash
# Sets up the Morpheus side of the AI chat demo. Safe to run again: every item is found by name and updated.
#   - Argo CD token for the "morpheus" account, Argo CD plugin settings
#   - Blueprint and catalog item "Private AI chat": each order is a Morpheus app holding an Argo CD app
#   - Catalog item "Remove AI chat": pick a running chat, type its name, it is removed
#   - Role "AI Developer" and approval of chat orders; a developer user only when DEV_USER is set
# Usage: scripts/setup-morpheus-catalog.sh <morpheus env file> <login file>
#   morpheus env file: MORPHEUS_URL, MORPHEUS_TOKEN (admin API token)
#   login file: APPS_USER, APPS_PASSWORD (Argo CD admin; also the developer user's password)
# Optional: DOMAIN (default kubeforge.live), REPO_URL, DEV_USER (makes a developer user with that name), CLUSTER (default kubecon-hks)
set -euo pipefail

set -a; . "${1:?morpheus env file}"; . "${2:?login file}"; set +a
DOMAIN="${DOMAIN:-kubeforge.live}"
ARGOCD="https://argocd.$DOMAIN"
REPO_URL="${REPO_URL:-https://github.com/NixndME/kubecon-demo.git}"
DEV_USER="${DEV_USER:-}"
CLUSTER="${CLUSTER:-kubecon-hks}"
HERE="$(cd "$(dirname "$0")" && pwd)"
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
# Token ids must be unique, so each run makes a new one; older ones are removed at the end
TOKEN_ID="morpheus-$(date +%Y%m%d%H%M%S)"
TOKEN=$(curl -sf -X POST -H "Authorization: Bearer $admin" -H 'Content-Type: application/json' \
  -d "{\"id\":\"$TOKEN_ID\"}" "$ARGOCD/api/v1/account/morpheus/token" | jq -r .token)
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "Could not make an Argo CD token" >&2; exit 1; }

echo "==> Argo CD plugin settings"
pid=$(api GET "/api/plugins?max=100" | jq -r '.plugins[] | select(.code=="argocd") | .id')
if [ -n "$pid" ]; then
  api PUT "/api/plugins/$pid" "$(jq -n --arg u "$ARGOCD" --arg t "$TOKEN" \
    '{plugin:{config:{argocdUrl:$u, argocdToken:$t, argocdVerifyTls:"on", argocdDefaultProject:"default"}}}')" >/dev/null
else echo "    Argo CD plugin not installed, skipped"; fi

echo "==> Cluster"
cluster=$(api GET "/api/clusters?max=100" | jq -r --arg n "$CLUSTER" '.clusters[] | select(.name==$n) | .id' | head -1)
[ -n "$cluster" ] || { echo "Cluster $CLUSTER not found in Morpheus" >&2; exit 1; }
# The Argo CD namespace: the blueprint's Argo CD app lives there
pool=$(api GET "/api/clusters/$cluster/namespaces?max=500" | jq -r '.namespaces[] | select(.name=="argocd") | .id' | head -1)
[ -n "$pool" ] || { echo "No argocd namespace in $CLUSTER" >&2; exit 1; }
zone=$(api GET "/api/clusters/$cluster" | jq -r .cluster.zone.id)

echo "==> Group \"AI chats\" (chat apps live here; orders in it need approval)"
group=$(find_id /api/groups groups name "AI chats")
[ -n "$group" ] || group=$(api POST /api/groups '{"group":{"name":"AI chats","code":"ai-chats","location":"HKS"}}' | jq -r .group.id)
api PUT "/api/groups/$group/update-zones" "{\"group\":{\"zones\":[{\"id\":$zone}]}}" >/dev/null

echo "==> Remove items from older versions of this script"
for n in "Order private AI chat:task-sets:taskSets" "Remove private AI chat:task-sets:taskSets" \
  "Make AI chat password:tasks:tasks" "Create private AI chat:tasks:tasks" "Show AI chat link:tasks:tasks" "Check AI chat remove confirm:tasks:tasks" \
  "AI owner name:library/option-types:optionTypes" "AI team name:library/option-types:optionTypes" "AI chat password:library/option-types:optionTypes"; do
  IFS=: read -r name path key <<<"$n"
  id=$(find_id "/api/$path" "$key" name "$name")
  # The old "Private AI chat" was a workflow item; it is replaced by a blueprint item below
  [ -z "$id" ] || api DELETE "/api/$path/$id" >/dev/null || echo "    could not remove $name"
done
old=$(api GET "/api/catalog-item-types?max=500" | jq -r '.catalogItemTypes[] | select(.name=="Private AI chat" and .type!="blueprint") | .id')
[ -z "$old" ] || api DELETE "/api/catalog-item-types/$old" >/dev/null

echo "==> Lists"
models=$(upsert /api/library/option-type-lists optionTypeLists name "AI models" optionTypeList "$(jq -n '{optionTypeList:{
  name:"AI models", type:"manual", description:"Small models that fit a GPU slice",
  initialDataset:([{name:"Llama 3.2 3B (fast, general)",value:"llama3.2:3b"},{name:"Phi-4 mini 3.8B (MIT license)",value:"phi4-mini:3.8b"}]|tojson)}}')")
translate='for (var i = 0; i < data.items.length; i++) { var a = data.items[i]; var l = a.metadata.labels || {}; var o = (a.metadata.annotations || {})["kubecon-demo/owner"] || "?"; var p = {}; var ps = (a.spec.source.helm || {}).parameters || []; for (var j = 0; j < ps.length; j++) { p[ps[j].name] = ps[j].value; } var h = (a.status && a.status.health && a.status.health.status) || "?"; results.push({name: a.metadata.name + " (" + o + ", " + p.model + ", " + (h == "Healthy" ? "running" : h == "Progressing" ? "starting or waiting for a GPU slice" : h) + ")", value: a.metadata.name}); }'
chats=$(upsert /api/library/option-type-lists optionTypeLists name "AI chats (live)" optionTypeList "$(jq -n \
  --arg url "$ARGOCD/api/v1/applications?selector=kubecon-demo/catalog%3Dai-chat" --arg t "$TOKEN" --arg tr "$translate" '{optionTypeList:{
  name:"AI chats (live)", type:"rest", description:"AI chats running in the cluster now, read from Argo CD",
  sourceUrl:$url, sourceMethod:"GET", realTime:true, translationScript:$tr,
  config:{sourceHeaders:[{name:"Authorization",value:("Bearer " + $t)}]}}}')")

echo "==> Inputs"
reserved="argocd|grafana|chat|traefik|morpheus|k8s|ingress|www|admin|api|loki|prometheus"
in_name=$(upsert /api/library/option-types optionTypes name "AI first name" optionType "$(jq -n --arg d "$DOMAIN" --arg r "$reserved" '{optionType:{
  name:"AI first name", fieldName:"aiName", fieldLabel:"First name", type:"text", required:true, displayOrder:1,
  verifyPattern:("^(?!(" + $r + ")$)[a-z][a-z0-9]{1,14}$"), placeHolder:"jane",
  helpBlock:("Lowercase letters or numbers. Your chat opens at https://<first name>." + $d)}}')")
in_email=$(upsert /api/library/option-types optionTypes name "AI owner email" optionType "$(jq -n '{optionType:{
  name:"AI owner email", fieldName:"aiEmail", fieldLabel:"Email", type:"text", required:true, displayOrder:2,
  verifyPattern:"^[a-z0-9._+-]+@[a-z0-9.-]+[.][a-z]{2,}$", placeHolder:"jane@example.com",
  helpBlock:"Lowercase. This is your chat login"}}')")
in_team=$(upsert /api/library/option-types optionTypes name "AI team" optionType "$(jq -n '{optionType:{
  name:"AI team", fieldName:"aiTeam", fieldLabel:"Team", type:"text", required:false, displayOrder:4,
  verifyPattern:"^([a-z][a-z0-9-]{1,29})?$", placeHolder:"platform", helpBlock:"Optional. Lowercase. Only a label for reports"}}')")
in_model=$(upsert /api/library/option-types optionTypes name "AI model" optionType "$(jq -n --argjson l "$models" '{optionType:{
  name:"AI model", fieldName:"aiModel", fieldLabel:"Model", type:"select", required:true, displayOrder:5,
  optionList:{id:$l}, defaultValue:"llama3.2:3b", helpBlock:"Runs on one GPU slice"}}')")
in_pass=$(upsert /api/library/option-types optionTypes name "AI chat login password" optionType "$(jq -n '{optionType:{
  name:"AI chat login password", fieldName:"aiPassword", fieldLabel:"Password", type:"password", required:true, displayOrder:3,
  verifyPattern:"^[A-Za-z0-9!@#$%^&*()_+=.:;?-]{8,64}$",
  helpBlock:"Your chat password. 8 to 64 characters, no spaces, quotes or commas"}}')")
in_chat=$(upsert /api/library/option-types optionTypes name "AI chat to remove" optionType "$(jq -n --argjson l "$chats" '{optionType:{
  name:"AI chat to remove", fieldName:"aiChat", fieldLabel:"Chat", type:"select", required:true, displayOrder:1,
  optionList:{id:$l}, helpBlock:"AI chats in the HKS cluster now, by app name"}}')")
in_confirm=$(upsert /api/library/option-types optionTypes name "AI chat remove confirm" optionType "$(jq -n '{optionType:{
  name:"AI chat remove confirm", fieldName:"aiConfirm", fieldLabel:"Type the app name to confirm", type:"text", required:true, placeHolder:"ai-jane",
  displayOrder:2, helpBlock:"The chat, its model server and its GPU slice are removed. This cannot be undone."}}')")

echo "==> Blueprint"
spec=$(upsert /api/library/spec-templates specTemplates name "AI chat (Argo CD app)" specTemplate "$(jq -n \
  --rawfile y "$HERE/../morpheus/ai-chat-app.yaml" --arg repo "$REPO_URL" '{specTemplate:{
  name:"AI chat (Argo CD app)", type:{code:"kubernetes"}, file:{sourceType:"local", content:($y | gsub("__REPO_URL__"; $repo))}}}')")
# config.specs links the spec to the blueprint (the kubernetes block alone is not enough)
blueprint=$(upsert /api/blueprints blueprints name "Private AI chat" blueprint "$(jq -n --argjson s "$spec" '{
  name:"Private AI chat", type:"kubernetes", visibility:"public", description:"One private AI chat, deployed by Argo CD",
  config:{specs:[{id:$s}]}, kubernetes:{configType:"spec", specs:[{id:$s}]}}')")
[ -n "$blueprint" ] && [ "$blueprint" != null ] || blueprint=$(find_id /api/blueprints blueprints name "Private AI chat")

echo "==> Remove task and workflow"
groovy=$(sed -e "s|__ARGOCD_URL__|$ARGOCD|g" -e "s|__ARGOCD_TOKEN__|$TOKEN|g" -e "s|__MORPHEUS_URL__|$M|g" -e "s|__MORPHEUS_TOKEN__|$MORPHEUS_TOKEN|g" "$HERE/../morpheus/remove-ai-chat.groovy")
t_remove=$(upsert /api/tasks tasks name "Remove AI chat (check and delete)" task "$(jq -n --arg g "$groovy" '{task:{
  name:"Remove AI chat (check and delete)", taskType:{code:"groovyTask"}, executeTarget:"local", file:{sourceType:"local", content:$g}}}')")
w_remove=$(upsert /api/task-sets taskSets name "Remove AI chat" taskSet "$(jq -n --argjson a "$t_remove" --argjson i "$in_chat" --argjson k "$in_confirm" '{taskSet:{
  name:"Remove AI chat", type:"operation", description:"Removes an AI chat and frees its GPU slice",
  tasks:[{taskId:$a, taskPhase:"operation"}], optionTypes:[$i,$k]}}')")
# The HTTP remove task of an older version, no longer used by the workflow
old=$(find_id /api/tasks tasks name "Remove private AI chat"); [ -z "$old" ] || api DELETE "/api/tasks/$old" >/dev/null || echo "    could not remove the old remove task"

echo "==> Catalog items"
# Morpheus keeps the order values in app.input, which the blueprint spec reads; it needs both blocks below
appspec="name: ai-<%=customOptions.aiName%>
description: 'Chat page https://<%=customOptions.aiName%>.$DOMAIN, login <%=customOptions.aiEmail%>, team <%=customOptions.aiTeam%>, model <%=customOptions.aiModel%>'
group:
  id: $group
defaultPool:
  id: $pool
customOptions:
  aiName: '<%=customOptions.aiName%>'
  aiEmail: '<%=customOptions.aiEmail%>'
  aiTeam: '<%=customOptions.aiTeam%>'
  aiModel: '<%=customOptions.aiModel%>'
  aiPassword: '<%=customOptions.aiPassword%>'
config:
  customOptions:
    aiName: '<%=customOptions.aiName%>'
    aiEmail: '<%=customOptions.aiEmail%>'
    aiTeam: '<%=customOptions.aiTeam%>'
    aiModel: '<%=customOptions.aiModel%>'
    aiPassword: '<%=customOptions.aiPassword%>'
"
c_order=$(upsert /api/catalog-item-types catalogItemTypes name "Private AI chat" catalogItemType "$(jq -n --argjson b "$blueprint" --arg s "$appspec" \
  --argjson i0 "$in_name" --argjson i1 "$in_email" --argjson i2 "$in_team" --argjson i3 "$in_model" --argjson i4 "$in_pass" --arg d "$DOMAIN" '{catalogItemType:{
  name:"Private AI chat", type:"blueprint", blueprint:{id:$b}, appSpec:$s, optionTypes:[$i0,$i1,$i4,$i2,$i3],
  enabled:true, featured:true, visibility:"public",
  description:"Your own private AI chat, on a GPU in the HKS cluster.",
  content:("**What you get**\n\n- A chat page at **https://<first name>." + $d + "**\n- The AI model you pick, on its own GPU slice\n- Your questions stay inside the cluster\n\n**How it works**\n\n1. Fill in the form and order.\n2. An admin approves.\n3. About 2 minutes later, open **Apps > ai-<first name>** for the link. Log in with your email and password.")}}')")
c_remove=$(upsert /api/catalog-item-types catalogItemTypes name "Remove AI chat" catalogItemType "$(jq -n --argjson w "$w_remove" --argjson i "$in_chat" --argjson k "$in_confirm" '{catalogItemType:{
  name:"Remove AI chat", type:"workflow", workflow:{id:$w}, context:"appliance", optionTypes:[$i,$k],
  enabled:true, featured:false, visibility:"public",
  description:"Remove an AI chat you no longer need.",
  content:"**What happens**\n\n- The chat page, its model and its GPU slice are removed.\n- The chat history is deleted.\n\n**How**\n\nPick the chat, type its name (for example ai-jane) to confirm, and order."}}')")

echo "==> Logos"
for c in "$c_order:ai-chat.svg" "$c_remove:remove-ai-chat.svg"; do
  curl -sf -X PUT -H "Authorization: Bearer $MORPHEUS_TOKEN" -F "catalogItemType.logo=@$HERE/../morpheus/logos/${c#*:};type=image/svg+xml" \
    "$M/api/catalog-item-types/${c%%:*}/update-logo" >/dev/null || echo "    could not upload the logo ${c#*:}"
done

echo "==> Role, developer user, approval"
role=$(upsert /api/roles roles authority "AI Developer" role "$(jq -n '{role:{authority:"AI Developer",
  description:"Orders private AI chats from the Service Catalog", roleType:"user"}}')")
api PUT "/api/roles/$role/update-persona" '{"personaCode":"serviceCatalog","access":"full"}' >/dev/null
api PUT "/api/roles/$role/update-persona" '{"personaCode":"standard","access":"none"}' >/dev/null
api PUT "/api/roles/$role/update-group" "{\"groupId\":$group,\"access\":\"full\"}" >/dev/null || true
api PUT "/api/roles/$role/update-group" '{"groupId":1,"access":"none"}' >/dev/null || true
api PUT "/api/roles/$role/update-blueprint" "{\"blueprintId\":$blueprint,\"access\":\"full\"}" >/dev/null || echo "    could not give blueprint access"
for c in "$c_order" "$c_remove"; do api PUT "/api/roles/$role/update-catalog-item-type" "{\"catalogItemTypeId\":$c,\"access\":\"full\"}" >/dev/null; done
for p in service-catalog:full service-catalog-dashboard:read service-catalog-inventory:full provisioning-execute-workflow:full executions:read apps:full services-cypher:none; do
  api PUT "/api/roles/$role/update-permission" "{\"permissionCode\":\"${p%%:*}\",\"access\":\"${p#*:}\"}" >/dev/null || echo "    could not set ${p%%:*}"
done
user=""
if [ -n "$DEV_USER" ]; then
  user=$(api GET "/api/users?max=500" | jq -r --arg u "$DEV_USER" '.users[] | select(.username==$u) | .id' | head -1)
fi
if [ -n "$DEV_USER" ] && [ -z "$user" ]; then
  user=$(api POST /api/users "$(jq -n --arg u "$DEV_USER" --arg d "$DOMAIN" --arg p "$APPS_PASSWORD" --argjson r "$role" '{user:{
    username:$u, email:($u + "@" + $d), firstName:"Dev", lastName:"One", password:$p, roles:[{id:$r}], receiveNotifications:false}}')" | jq -r .user.id)
fi
# An admin approves chat orders (blueprint apps only follow group or cloud policies) and the developer's removals
rules=("provisionApproval:Approve AI chat orders:ComputeSite:$group")
[ -z "$user" ] || rules+=("workflowApproval:Approve AI chat removals:User:$user")
for t in "${rules[@]}"; do
  IFS=: read -r code name rtype rid <<<"$t"
  old=$(api GET "/api/policies?max=500" | jq -r --arg n "$name" --arg c "$code" --arg r "$rtype" \
    '.policies[] | select(.name==$n and (.policyType.code!=$c or .refType!=$r)) | .id')
  for o in $old; do api DELETE "/api/policies/$o" >/dev/null; done
  pol=$(api GET "/api/policies?max=500" | jq -r --arg n "$name" '.policies[] | select(.name==$n) | .id' | head -1)
  [ -n "$pol" ] || api POST /api/policies "$(jq -n --arg c "$code" --arg n "$name" --arg r "$rtype" --argjson i "$rid" '{policy:({name:$n,
    description:"An admin approves this for AI developers", policyType:{code:$c},
    enabled:true, refType:$r, refId:$i, config:{accountIntegrationId:-100}}
    + (if $r == "User" then {user:{id:$i}} else {site:{id:$i}} end))}')" >/dev/null
done

echo "==> Remove older Argo CD tokens of the morpheus account"
for t in $(curl -sf -H "Authorization: Bearer $admin" "$ARGOCD/api/v1/account/morpheus" | jq -r --arg k "$TOKEN_ID" '.tokens[]? | select(.id != $k) | .id'); do
  curl -sf -X DELETE -H "Authorization: Bearer $admin" -H 'Content-Type: application/json' "$ARGOCD/api/v1/account/morpheus/token/$t" >/dev/null || true
done

echo "Done. Blueprint $blueprint, catalog items $c_order and $c_remove, role $role${DEV_USER:+, user $DEV_USER ($user)}."
echo "The developer switches to the catalog at $M/user-settings/switch-persona/serviceCatalog"
