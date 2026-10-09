#!/usr/bin/env bash
# Installs Morpheus on a fresh Ubuntu 24.04 VM. Runs ON the VM as root.
# Usage: sudo FQDN=morpheus.example.com VERSION=9.1.0-2 bash install-morpheus.sh
set -euo pipefail

FQDN="${FQDN:?set FQDN}"
VERSION="${VERSION:?set VERSION}"
DEB="morpheus-appliance_${VERSION}_amd64.deb"
URL="https://downloads.morpheusdata.com/files/${DEB}"
RB=/etc/morpheus/morpheus.rb
UI_LOG=/var/log/morpheus/morpheus-ui/current
WAIT_SECS=2400

step() { echo; echo "==> $(date +%H:%M:%S) $*"; }
fail() { echo "FAILED: $*"; exit 1; }

step "Wait for cloud-init"
cloud-init status --wait >/dev/null || fail "cloud-init reported an error"
echo "host: $(hostname -f), memory: $(free -g | awk '/Mem/{print $2}') GB, swap: $(free -g | awk '/Swap/{print $2}') GB"
df -h / | tail -1

step "Time sync"
systemctl is-active --quiet chrony || systemctl enable --now chrony
chronyc tracking | grep -E 'Reference ID|System time' || true

if dpkg -s morpheus-appliance >/dev/null 2>&1; then
  echo "morpheus-appliance already installed: $(dpkg-query -W -f='${Version}' morpheus-appliance)"
else
  step "Download $DEB"
  want=$(curl -sI "$URL" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')
  [ -n "$want" ] || fail "package not found at $URL"
  curl -fsSL -o "/var/tmp/$DEB" "$URL"
  got=$(stat -c%s "/var/tmp/$DEB")
  [ "$got" = "$want" ] || fail "size mismatch: got $got, want $want"
  echo "downloaded $got bytes"

  step "Install package"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y "/var/tmp/$DEB"
  rm -f "/var/tmp/$DEB"
fi

step "Set appliance_url"
# The package writes the EC2 public name here; replace it, single or double quotes
grep -E '^appliance_url' "$RB" || fail "no appliance_url line in $RB"
sed -i -E "s#^appliance_url[[:space:]]+['\"][^'\"]*['\"]#appliance_url 'https://${FQDN}'#" "$RB"
grep -qx "appliance_url 'https://${FQDN}'" "$RB" || fail "appliance_url not set, check $RB"
grep -E '^appliance_url' "$RB"

step "morpheus-ctl reconfigure (takes a while)"
morpheus-ctl reconfigure

step "Wait for the UI (banner or /ping)"
start=$(date +%s)
until grep -q "Start Time:" "$UI_LOG" 2>/dev/null || \
      [ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://localhost/ping)" = 200 ]; do
  [ $(( $(date +%s) - start )) -gt $WAIT_SECS ] && fail "UI not up after $((WAIT_SECS / 60)) min, see $UI_LOG"
  sleep 10
done
echo "UI up after $(( ($(date +%s) - start) / 60 )) min"

step "Status"
morpheus-ctl status
echo "ping: $(curl -sk -o /dev/null -w '%{http_code}' https://localhost/ping)"
echo "login page: $(curl -sk -o /dev/null -w '%{http_code}' https://localhost/login/auth)"
echo "INSTALL_DONE"
