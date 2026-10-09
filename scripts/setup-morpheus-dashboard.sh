#!/usr/bin/env bash
# Sets up the "AI on HKS" dashboard in Morpheus (Operations > Dashboard). Safe to run again.
#   - uploads the plugin jar when one is given
#   - fills in its settings: cluster API address and read-only token (from gitops/platform/morpheus-dashboard),
#     Grafana and Argo CD addresses, chat domain
#   - gives System Admins its permission, and adds the dashboard to the dashboards Morpheus shows
# Usage: KUBECONFIG=<kubeconfig> scripts/setup-morpheus-dashboard.sh <morpheus env file> [plugin jar]
#   morpheus env file: MORPHEUS_URL, MORPHEUS_TOKEN (admin API token)
# Optional: DOMAIN (default kubeforge.live)
set -euo pipefail

set -a; . "${1:?morpheus env file}"; set +a
JAR="${2:-}"
DOMAIN="${DOMAIN:-kubeforge.live}"
M="${MORPHEUS_URL%/}"
api() { curl -sf -X "$1" -H "Authorization: Bearer $MORPHEUS_TOKEN" -H "Content-Type: application/json" "$M$2" ${3:+-d "$3"}; }

if [ -n "$JAR" ]; then
  echo "==> Upload $(basename "$JAR")"
  curl -sf -H "Authorization: Bearer $MORPHEUS_TOKEN" -F "file=@$JAR" "$M/api/plugins/upload" >/dev/null
fi
pid=$(api GET "/api/plugins?max=200" | jq -r '.plugins[] | select(.code=="hks-ai-dashboard") | .id')
[ -n "$pid" ] || { echo "The AI on HKS plugin is not installed. Give the jar as the second argument." >&2; exit 1; }

echo "==> Cluster access"
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
for i in $(seq 1 30); do
  token=$(kubectl -n morpheus-dashboard get secret morpheus-dashboard-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
  [ -n "$token" ] && break; sleep 5
done
[ -n "$token" ] || { echo "No token yet: is the morpheus-dashboard app synced in Argo CD?" >&2; exit 1; }

echo "==> Plugin settings"
api PUT "/api/plugins/$pid" "$(jq -n --arg k "$server" --arg t "$token" --arg d "$DOMAIN" '{plugin:{config:{
  kubeUrl:$k, kubeToken:$t, grafanaUrl:("https://grafana." + $d), argocdUrl:("https://argocd." + $d), domain:$d}}}')" >/dev/null

echo "==> Let System Admins refresh the dashboard and use its Approve and Reject buttons"
admin=$(api GET "/api/roles?max=100" | jq -r '.roles[] | select(.authority=="System Admin") | .id')
[ -z "$admin" ] || api PUT "/api/roles/$admin/update-permission" '{"permissionCode":"hks-ai-dashboard","access":"read"}' >/dev/null || echo "    could not set the permission"

echo "==> Show the dashboard on Operations > Dashboard"
cur=$(api GET /api/appliance-settings | jq -r '.applianceSettings.dashboardsToDisplay // ""')
case ",$cur," in
  *,hks-ai-dashboard,*) ;;
  *) api PUT /api/appliance-settings "$(jq -n --arg v "hks-ai-dashboard${cur:+,$cur}" '{applianceSettings:{dashboardsToDisplay:$v}}')" >/dev/null ;;
esac
echo "Done. Open $M/operations/dashboard"
