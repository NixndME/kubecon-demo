#!/bin/bash
# Adds public names to the Kubernetes API certificate, so a kubeconfig with the public name works from a laptop.
# Runs on every node; only the control plane node does something. Safe to run again.
set -euo pipefail

API_NAMES="${API_NAMES:-k8s.kubeforge.live}"
CFG=/etc/kubernetes/admin.conf
PKI=/etc/kubernetes/pki

if [ ! -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
  echo "Not a control plane node ($(hostname)). Nothing to do."
  exit 0
fi

# Also add this machine's public IP, read from AWS
token=$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)
public_ip=$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/public-ipv4 || true)
names="$API_NAMES $public_ip"

# Check the certificate the API server really serves, not only the file
have=$(echo | openssl s_client -connect 127.0.0.1:6443 2>/dev/null | openssl x509 -noout -ext subjectAltName | tail -1)
sans=$(kubectl --kubeconfig "$CFG" -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}')
missing=""; cert_ok=1
for n in $names; do
  echo "$have" | grep -qE "(DNS|IP Address):$n(,|$)" || { missing="$missing $n"; cert_ok=0; }
  echo "$sans" | grep -qE "^ *- $n$" || missing="$missing $n"
done
if [ -z "$missing" ]; then
  echo "API certificate already has:$names"
  exit 0
fi
echo "Adding to the API certificate:$missing"

# Current cluster settings, plus the new names
kubectl --kubeconfig "$CFG" -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' > /root/kubeadm-cluster.yaml
python3 - /root/kubeadm-cluster.yaml $missing <<'EOF'
import sys, yaml
path, new = sys.argv[1], sys.argv[2:]
c = yaml.safe_load(open(path))
sans = c.setdefault('apiServer', {}).setdefault('certSANs', [])
for n in new:
    if n not in sans:
        sans.append(n)
yaml.safe_dump(c, open(path, 'w'), default_flow_style=False)
EOF

if [ "$cert_ok" = 1 ]; then
  kubeadm init phase upload-config kubeadm --config /root/kubeadm-cluster.yaml
  echo "Saved the names in the cluster config on $(hostname)."
  exit 0
fi

# New certificate, keep the old one next to it
stamp=$(date +%Y%m%d%H%M%S)
mv "$PKI/apiserver.crt" "$PKI/apiserver.crt.$stamp"
mv "$PKI/apiserver.key" "$PKI/apiserver.key.$stamp"
kubeadm init phase certs apiserver --config /root/kubeadm-cluster.yaml

# The API server reloads its certificate by itself; restart it only if it has not after a minute
served() { echo | openssl s_client -connect 127.0.0.1:6443 2>/dev/null | openssl x509 -noout -ext subjectAltName | tail -1; }
for i in $(seq 1 12); do
  served | grep -q "DNS:${API_NAMES%% *}" && break
  sleep 5
done
if ! served | grep -q "DNS:${API_NAMES%% *}"; then
# kubelet stops the API server when its manifest goes away, and starts it again when it is back
mv /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/kube-apiserver.yaml.restart
for i in $(seq 1 30); do
  curl -sk -m 2 https://127.0.0.1:6443/livez >/dev/null 2>&1 || break
  sleep 2
done
mv /etc/kubernetes/kube-apiserver.yaml.restart /etc/kubernetes/manifests/kube-apiserver.yaml
fi
for i in $(seq 1 60); do
  kubectl --kubeconfig "$CFG" get --raw /readyz >/dev/null 2>&1 && break
  sleep 5
done
kubectl --kubeconfig "$CFG" get --raw /readyz >/dev/null

# Save the names in the cluster config, so kubeadm upgrades keep them
kubeadm init phase upload-config kubeadm --config /root/kubeadm-cluster.yaml

openssl x509 -in "$PKI/apiserver.crt" -noout -ext subjectAltName | tail -1
echo "API certificate updated on $(hostname)."
