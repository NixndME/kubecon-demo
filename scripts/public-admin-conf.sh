#!/bin/bash
# Keeps the public API name in /etc/kubernetes/admin.conf, so the kubeconfig Morpheus shows works from a laptop.
# Installs a systemd watcher: every time kubeadm writes admin.conf, the server line is set to the public name.
# Run before Kubernetes is installed. Safe to run again.
set -euo pipefail

API_NAME="${API_NAME:-k8s.kubeforge.live}"

cat > /usr/local/sbin/hks-public-admin-conf <<EOF
#!/bin/bash
f=/etc/kubernetes/admin.conf
[ -f "\$f" ] || exit 0
# Change only when needed, so the watcher does not trigger itself again
grep -q "server: https://$API_NAME:6443" "\$f" && exit 0
sed -i -E "s#server: https://[^ ]+:6443#server: https://$API_NAME:6443#" "\$f"
EOF
chmod 755 /usr/local/sbin/hks-public-admin-conf

cat > /etc/systemd/system/hks-public-admin-conf.service <<'EOF'
[Unit]
Description=Set the public API name in admin.conf

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hks-public-admin-conf
EOF

cat > /etc/systemd/system/hks-public-admin-conf.path <<'EOF'
[Unit]
Description=Watch admin.conf for the public API name

[Path]
PathChanged=/etc/kubernetes/admin.conf

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hks-public-admin-conf.path
/usr/local/sbin/hks-public-admin-conf
echo "Watching admin.conf on $(hostname), public name $API_NAME."
