#!/bin/bash
# Installs the NVIDIA driver on nodes that have an NVIDIA GPU. Nodes without one are left alone.
# Uses Ubuntu's prebuilt driver for the running kernel: nothing is compiled and no reboot is needed.
set -euo pipefail

BRANCH="${NVIDIA_BRANCH:-580}"
KERNEL="$(uname -r)"

if ! grep -qsx '0x10de' /sys/bus/pci/devices/*/vendor; then
  echo "No NVIDIA GPU on $(hostname). Nothing to do."
  exit 0
fi

if nvidia-smi >/dev/null 2>&1; then
  echo "NVIDIA driver already works on $(hostname)."
  nvidia-smi --query-gpu=name,driver_version,memory.total,temperature.gpu --format=csv
  exit 0
fi

echo "NVIDIA GPU found on $(hostname), kernel $KERNEL. Installing driver branch $BRANCH."
export DEBIAN_FRONTEND=noninteractive

# apt can be busy right after boot
for i in $(seq 1 30); do
  fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
  sleep 10
done

apt-get update -q
if ! apt-cache show "linux-modules-nvidia-${BRANCH}-server-${KERNEL}" >/dev/null 2>&1; then
  echo "No prebuilt NVIDIA ${BRANCH} driver for kernel ${KERNEL}."
  exit 1
fi
apt-get install -y -q --no-install-recommends \
  "linux-modules-nvidia-${BRANCH}-server-${KERNEL}" \
  "nvidia-headless-no-dkms-${BRANCH}-server" \
  "nvidia-utils-${BRANCH}-server"

# Keep the kernel as is, so the driver keeps matching it
apt-mark hold linux-aws linux-image-aws linux-headers-aws >/dev/null 2>&1 || true

# The kernel's own nouveau driver takes the GPU at boot. Block it for next boots
# and release the GPU now, so the NVIDIA driver can load without a reboot.
printf 'blacklist nouveau\noptions nouveau modeset=0\n' > /etc/modprobe.d/blacklist-nouveau.conf
update-initramfs -u -k "$KERNEL" >/dev/null 2>&1 || true
for dev in /sys/bus/pci/drivers/nouveau/0000:*; do
  [ -e "$dev" ] && echo "$(basename "$dev")" > /sys/bus/pci/drivers/nouveau/unbind
done
modprobe -r nouveau 2>/dev/null || true

modprobe nvidia
systemctl enable --now nvidia-persistenced >/dev/null 2>&1 || true

nvidia-smi
echo "NVIDIA driver ready on $(hostname)."
