#!/usr/bin/env bash
# First install of cert-manager, Traefik and Argo CD on a new cluster, then Argo CD takes over from Git.
# Secrets come from a local file and go straight into the cluster, never into Git.
# Usage: KUBECONFIG=<file> scripts/bootstrap-gitops.sh <login file>
#   login file has APPS_USER=..., APPS_PASSWORD=... and APPS_EMAIL=... (the chat app logs in with an email)
# Needs: kubectl, helm, python3 with bcrypt (pip install bcrypt).
set -euo pipefail

LOGIN_FILE="${1:?login file with APPS_USER and APPS_PASSWORD}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
G="$HERE/gitops"
PY="${PYTHON:-python3}"

CERT_MANAGER_VERSION="v1.21.2"
TRAEFIK_VERSION="41.7.0"
ARGOCD_VERSION="10.10.1"

set -a; . "$LOGIN_FILE"; set +a
: "${APPS_USER:?}" "${APPS_PASSWORD:?}"

hash_pw() { "$PY" -c 'import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt()).decode())' "$1"; }

helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo add traefik https://traefik.github.io/charts >/dev/null
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null

echo "==> cert-manager"
helm upgrade --install cert-manager jetstack/cert-manager --version "$CERT_MANAGER_VERSION" \
  -n cert-manager --create-namespace -f "$G/platform/cert-manager/values.yaml" --wait
kubectl apply -f "$G/platform/cert-manager-issuer/cluster-issuer.yaml"

echo "==> Traefik login secret"
kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f -
# Traefik reads bcrypt hashes in the htpasswd form ($2y$)
users="$APPS_USER:$(hash_pw "$APPS_PASSWORD" | sed 's/^\$2b\$/$2y$/')"
kubectl -n traefik create secret generic dashboard-users --from-literal=users="$users" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Traefik"
helm upgrade --install traefik traefik/traefik --version "$TRAEFIK_VERSION" \
  -n traefik -f "$G/platform/traefik/values.yaml" --wait

echo "==> Argo CD admin password"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl -n argocd create secret generic argocd-secret \
  --from-literal=admin.password="$(hash_pw "$APPS_PASSWORD")" \
  --from-literal=admin.passwordMtime="$(date -u +%FT%TZ)" \
  --dry-run=client -o yaml | kubectl label --local -f - app.kubernetes.io/part-of=argocd -o yaml | kubectl apply -f -

echo "==> Argo CD"
helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_VERSION" \
  -n argocd -f "$G/platform/argocd/values.yaml" --wait

echo "==> Chat app admin login"
kubectl create namespace ai-chat --dry-run=client -o yaml | kubectl apply -f -
# Keep the session key of an existing install, so logins survive
key=$(kubectl -n ai-chat get secret open-webui-admin -o jsonpath='{.data.WEBUI_SECRET_KEY}' 2>/dev/null | base64 -d || true)
[ -n "$key" ] || key=$(openssl rand -hex 32)
kubectl -n ai-chat create secret generic open-webui-admin \
  --from-literal=WEBUI_ADMIN_EMAIL="${APPS_EMAIL:?APPS_EMAIL missing in the login file}" \
  --from-literal=WEBUI_ADMIN_PASSWORD="$APPS_PASSWORD" \
  --from-literal=WEBUI_ADMIN_NAME="$APPS_USER" \
  --from-literal=WEBUI_SECRET_KEY="$key" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Grafana admin login"
kubectl create namespace grafana --dry-run=client -o yaml | kubectl apply -f -
kubectl -n grafana create secret generic grafana-admin \
  --from-literal=admin-user="$APPS_USER" --from-literal=admin-password="$APPS_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

if [ "${ROOT_APP:-0}" = 1 ]; then
  echo "==> Argo CD takes over from Git"
  kubectl apply -f "$G/root-app.yaml"
fi
echo "Done."
