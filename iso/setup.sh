#!/bin/sh
# Runs as root inside the freshly installed system, from the installer's post-install hook
# (spec §6.2): installs the agent packages from the ISO, wires PAM/NSS (the packages do that),
# and enables first-boot enrollment. Usage: setup.sh <dir with the ISO's /snreg payload>
set -eu
src=${1:?usage: setup.sh <payload dir>}
# The installed kernel, not the installer's (uname -r would name that one).
kver=$(ls /lib/modules | sort -V | tail -1)
degraded() { echo "snreg-iso: kernel module not installed ($1); the device will report degraded" >&2; }

install -d -m 700 /etc/snreg /var/lib/snreg
install -m 600 "$src/enroll.toml" /etc/snreg/enroll.toml

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q || true
  apt-get install -y -q "$src"/snreg-agent_*.deb
  apt-get install -y -q dkms "linux-headers-$kver" "$src"/snreg-kmod-dkms_*.deb || degraded "no dkms or kernel headers"
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y "$src"/snreg-agent-*.rpm
  # RHEL and its rebuilds carry dkms in EPEL only.
  dnf -q list dkms >/dev/null 2>&1 || dnf install -y epel-release ||
    dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm" || true
  dnf install -y dkms "kernel-devel-$kver" "$src"/snreg-kmod-dkms-*.rpm || degraded "no dkms or kernel headers"
elif command -v pacman >/dev/null 2>&1; then
  pacman -U --noconfirm "$src"/snreg-agent-*-x86_64.pkg.tar.zst
  { pacman -S --noconfirm --needed dkms linux-headers && pacman -U --noconfirm "$src"/snreg-kmod-dkms-*.pkg.tar.zst; } ||
    degraded "no dkms or kernel headers"
else
  echo "snreg-iso: no apt-get, dnf or pacman" >&2
  exit 1
fi

# Package hooks build for the running (installer) kernel; build for the installed one.
for d in /usr/src/snreg-kmod-*; do
  [ -d "$d" ] && command -v dkms >/dev/null 2>&1 || continue
  v=${d#/usr/src/snreg-kmod-}
  dkms add -m snreg-kmod -v "$v" >/dev/null 2>&1 || true
  dkms install -m snreg-kmod -v "$v" -k "$kver" || degraded "build failed for $kver"
done

# Secure Boot: queue the DKMS signing key for enrollment. MokManager asks for this password once,
# at the console, on the next boot (spec §6.2, ADR 0010).
if [ -f "$src/mok-password" ] && command -v mokutil >/dev/null 2>&1; then
  key=
  for k in /var/lib/dkms/mok.pub /var/lib/shim-signed/mok/MOK.der; do [ -f "$k" ] && key=$k && break; done
  if [ -n "$key" ]; then
    pw=$(cat "$src/mok-password")
    printf '%s\n%s\n' "$pw" "$pw" | mokutil --import "$key" || echo "snreg-iso: MOK import failed" >&2
  else
    echo "snreg-iso: no DKMS signing key to enroll" >&2
  fi
fi

systemctl enable snreg-enroll.service snreg-agentd.service
