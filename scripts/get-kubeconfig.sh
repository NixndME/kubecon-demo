#!/usr/bin/env bash
# Gets the admin kubeconfig from the HKS master for a laptop (Lens, kubectl). Same file as Morpheus View Kube Config.
# Usage: scripts/get-kubeconfig.sh <master public name> <output file> [ssh key] [ssh user]
set -euo pipefail

HOST="${1:?master public name, e.g. k8s.example.com}"
OUT="${2:?output file}"
KEY="${3:-$HOME/.ssh/kubecon-key}"
USER_NAME="${4:-ubuntu}"

umask 077
ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$USER_NAME@$HOST" \
  'sudo cat /etc/kubernetes/admin.conf' > "$OUT.tmp"

# The layout already sets the public name; this keeps older clusters working too
sed -E "s#^( *)server: https://[^:]+:6443#\1server: https://$HOST:6443#" "$OUT.tmp" > "$OUT"
rm -f "$OUT.tmp"

kubectl --kubeconfig "$OUT" get nodes
echo "Saved $OUT"
