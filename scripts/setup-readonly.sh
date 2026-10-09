#!/usr/bin/env bash
# Makes one look-only login for Morpheus, Argo CD and Grafana. Safe to run again.
#   Morpheus: role "Read Only" (read where it can, nothing that opens a shell or shows secrets) and the user
#   Argo CD:  password of the "readonly" account (the account and its read-only role are in gitops/platform/argocd)
#   Grafana:  a Viewer user
# Usage: KUBECONFIG=<kubeconfig> scripts/setup-readonly.sh <morpheus env file> <apps env file> <readonly env file>
#   readonly env file: READONLY_USER, READONLY_PASSWORD
# Optional: DOMAIN (default kubeforge.live)
set -euo pipefail

set -a; . "${1:?morpheus env file}"; . "${2:?apps env file}"; . "${3:?readonly env file}"; set +a
DOMAIN="${DOMAIN:-kubeforge.live}"
M="${MORPHEUS_URL%/}"
PY="${PYTHON:-python3}"
api() { curl -s -X "$1" -H "Authorization: Bearer $MORPHEUS_TOKEN" -H "Content-Type: application/json" "$M$2" ${3:+-d "$3"}; }

# Permissions that stay off: shells, secrets, keys, the license and appliance-wide settings
DENY='terminal|kube-cntl|cypher|credentials|keypairs|licenses|identity-sources|admin-appliance|admin-clients|trust-services|certificates|supportBundles|export-import|services-ai|admin-plugins|execution-request|billing|hks-layout-studio|integrations-ansible'

echo "==> Morpheus role \"Read Only\""
role=$(api GET "/api/roles?max=100" | jq -r '.roles[] | select(.authority=="Read Only") | .id')
if [ -z "$role" ]; then
  role=$(api POST /api/roles '{"role":{"authority":"Read Only","description":"Look at everything, change nothing","roleType":"user"}}' | jq -r .role.id)
fi
admin=$(api GET "/api/roles?max=100" | jq -r '.roles[] | select(.authority=="System Admin") | .id')
skipped=0
for code in $(api GET "/api/roles/$admin" | jq -r '.featurePermissions[].code'); do
  access=read; [[ "$code" =~ $DENY ]] && access=none
  ok=$(api PUT "/api/roles/$role/update-permission" "{\"permissionCode\":\"$code\",\"access\":\"$access\"}" | jq -r '.success // false')
  # some permissions have no read level, leave those off
  if [ "$ok" != true ]; then
    api PUT "/api/roles/$role/update-permission" "{\"permissionCode\":\"$code\",\"access\":\"none\"}" >/dev/null; skipped=$((skipped+1))
  fi
done
echo "    $skipped permissions have no read level and stay off"
# Access to all groups, clouds, blueprints and so on uses the same call with these codes
for pair in ComputeSite:read ComputeZone:read \
            CatalogItemType:none Persona:none Task:none TaskSet:none VdiPools:none; do
  api PUT "/api/roles/$role/update-permission" "{\"permissionCode\":\"${pair%%:*}\",\"access\":\"${pair##*:}\"}" \
    | jq -e '.success' >/dev/null || echo "    could not set ${pair%%:*}"
done
api PUT "/api/roles/$role/update-persona" '{"personaCode":"standard","access":"full"}' | jq -e '.success' >/dev/null || echo "    could not set the Standard persona"

echo "==> Morpheus user $READONLY_USER"
user=$(api GET "/api/users?max=500" | jq -r --arg u "$READONLY_USER" '.users[] | select(.username==$u) | .id')
body=$(jq -n --arg u "$READONLY_USER" --arg p "$READONLY_PASSWORD" --arg e "$READONLY_USER@$DOMAIN" --argjson r "$role" \
  '{user:{username:$u, email:$e, firstName:"Read", lastName:"Only", password:$p, roles:[{id:$r}]}}')
if [ -z "$user" ]; then r=$(api POST /api/users "$body"); else r=$(api PUT "/api/users/$user" "$body"); fi
jq -e '.success' >/dev/null <<<"$r" || { echo "    Morpheus said: $(jq -c '.msg, .errors' <<<"$r")" >&2; exit 1; }

echo "==> Argo CD password for $READONLY_USER"
"$PY" -c 'import bcrypt' 2>/dev/null || { echo "Python needs bcrypt (pip install bcrypt) or set PYTHON=<python with bcrypt>" >&2; exit 1; }
hash=$("$PY" -c 'import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt()).decode())' "$READONLY_PASSWORD")
kubectl -n argocd patch secret argocd-secret --type merge -p "$(jq -n --arg h "$hash" --arg u "$READONLY_USER" --arg t "$(date -u +%FT%TZ)" \
  '{stringData:{("accounts." + $u + ".password"):$h, ("accounts." + $u + ".passwordMtime"):$t}}')" >/dev/null

echo "==> Grafana viewer $READONLY_USER"
G="https://grafana.$DOMAIN"
g() { curl -s -u "$APPS_USER:$APPS_PASSWORD" -X "$1" -H "Content-Type: application/json" "$G$2" ${3:+-d "$3"}; }
gid=$(g GET "/api/users/lookup?loginOrEmail=$READONLY_USER" | jq -r '.id // empty')
if [ -z "$gid" ]; then
  gid=$(g POST /api/admin/users "$(jq -n --arg u "$READONLY_USER" --arg p "$READONLY_PASSWORD" --arg e "$READONLY_USER@$DOMAIN" \
    '{name:"Read Only", login:$u, email:$e, password:$p}')" | jq -r .id)
else
  g PUT "/api/admin/users/$gid/password" "$(jq -n --arg p "$READONLY_PASSWORD" '{password:$p}')" >/dev/null
fi
g PATCH "/api/org/users/$gid" '{"role":"Viewer"}' >/dev/null
echo "Done. Login $READONLY_USER on Morpheus, https://argocd.$DOMAIN and $G"
