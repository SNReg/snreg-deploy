#!/usr/bin/env bash
# DM-1 (spec §6.2): a blank VM installed from a snreg-iso image shows up `active` with no manual
# steps, and its asset carries the VM's serial number (IG-1).
#
#   iso/test.sh <ubuntu-24.04|debian-12|fedora-41|rhel-9|arch>
#
# Starts a real snreg-server (container, TLS, WireGuard) with its own Postgres, makes an
# auto-approve token, builds the ISO and installs it into a UEFI QEMU VM with an empty disk
# (the disk boots first, so the installed system takes over after the installer's reboot).
# Needs: KVM, qemu-system-x86_64, OVMF, xorriso, mtools, docker, curl, openssl, python3, the
# kernel's wireguard module; agent packages in ../snreg-agent/packaging/dist (SNREG_PACKAGES).
# The server binary is built in a container unless SNREG_SERVER_BIN is set. BIOS=1 boots
# SeaBIOS instead of UEFI. KEEP=1 leaves everything running when the test fails.
set -euo pipefail
distro=${1:?usage: test.sh <distro>}
here=$(cd "$(dirname "$0")" && pwd)
ws=$(cd "$here/../.." && pwd)
cache=${XDG_CACHE_HOME:-$HOME/.cache}
packages=${SNREG_PACKAGES:-$ws/snreg-agent/packaging/dist}
# RHEL itself needs a subscription to download; AlmaLinux is its binary-compatible rebuild.
case $distro in
  ubuntu-24.04) url=https://releases.ubuntu.com/24.04/ubuntu-24.04.5-live-server-amd64.iso ;;
  debian-12) url=https://cdimage.debian.org/cdimage/archive/12.15.0/amd64/iso-cd/debian-12.15.0-amd64-netinst.iso ;;
  fedora-41) url=https://archives.fedoraproject.org/pub/archive/fedora/linux/releases/41/Server/x86_64/iso/Fedora-Server-dvd-x86_64-41-1.4.iso ;;
  rhel-9) url=https://repo.almalinux.org/almalinux/9/isos/x86_64/AlmaLinux-9-latest-x86_64-minimal.iso ;;
  arch) url=https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso ;;
  *) echo "unknown distro $distro" >&2; exit 2 ;;
esac
work=$(mktemp -d -p "${TMPDIR:-/var/tmp}") # the ISO copy is GBs; /tmp is often RAM
id=$$
port=$((18500 + RANDOM % 400))
wgport=$((51900 + RANDOM % 90))
net=snreg-iso-$id srv=snreg-iso-srv-$id db=snreg-iso-db-$id
serial=SNREG-DM1-$id
qemu_pid='' ok=0

cleanup() {
  if [[ $ok = 0 && ${KEEP:-0} = 1 ]]; then echo "KEEP=1: work dir $work, docker logs $srv"; return; fi
  [[ -n $qemu_pid ]] && kill "$qemu_pid" 2>/dev/null || true
  docker rm -f "$srv" "$db" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  docker run --rm -v "$work":/w alpine rm -rf /w/srv >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
log() { printf '\n== %s\n' "$*"; }
eventually() { # eventually <seconds> <command...>
  local t=$1; shift
  for _ in $(seq "$t"); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  "$@"
}

log "installer ISO"
iso=$cache/snreg-iso/$(basename "$url")
mkdir -p "$(dirname "$iso")"
[[ -f $iso ]] || { curl -fL --retry 3 -o "$iso.part" "$url" && mv "$iso.part" "$iso"; }

log "server"
bin=${SNREG_SERVER_BIN:-}
if [[ -z $bin ]]; then
  docker run --rm -v "$ws":/ws -v "$cache/snreg-build/cargo":/usr/local/cargo/registry -w /ws/snreg-server \
    -e CARGO_TARGET_DIR=/ws/snreg-server/target/vm rust:1.95-bookworm sh -ec "
      cargo build -q --release
      chown -R $(id -u):$(id -g) target/vm"
  bin=$ws/snreg-server/target/vm/release/snreg-server
fi
docker network create "$net" >/dev/null
docker run -d --name "$db" --network "$net" -e POSTGRES_USER=snreg -e POSTGRES_PASSWORD=snreg postgres:16 >/dev/null
eventually 60 docker exec "$db" pg_isready -U snreg -h 127.0.0.1
mkdir -p "$work/srv"
openssl req -x509 -newkey ed25519 -nodes -days 2 -subj /CN=snreg-iso -keyout "$work/srv/tls.key" -out "$work/srv/tls.crt" 2>/dev/null
pin=$(openssl x509 -in "$work/srv/tls.crt" -outform DER | sha256sum | cut -d' ' -f1)
# 10.0.2.2 is the host as QEMU's user network sees it.
env=(-e SNREG_DATABASE_URL="postgres://snreg:snreg@$db:5432/snreg" -e SNREG_MASTER_KEY_FILE=/srv/master.key
  -e SNREG_CONFIG=/srv/none.toml -e SNREG_TLS_CERT=/srv/tls.crt -e SNREG_TLS_KEY=/srv/tls.key
  -e SNREG_PUBLIC_URL="https://10.0.2.2:$port" -e SNREG_WG_ENDPOINT="10.0.2.2:$wgport")
admin_pw=$(docker run --rm --network "$net" -v "$work/srv":/srv -v "$bin":/usr/local/bin/snreg-server:ro "${env[@]}" \
  debian:12-slim snreg-server init | sed -n 's/.*password: //p')
docker run -d --name "$srv" --network "$net" --cap-add NET_ADMIN --device /dev/net/tun \
  -p "127.0.0.1:$port:8443" -p "127.0.0.1:$wgport:51820/udp" -v "$work/srv":/srv \
  -v "$bin":/usr/local/bin/snreg-server:ro "${env[@]}" debian:12-slim snreg-server serve >/dev/null
eventually 60 curl -skf "https://127.0.0.1:$port/api/v1/health"
api() { # api METHOD PATH [JSON]
  curl -skf -b "$work/jar" -c "$work/jar" -H 'X-SNReg-CSRF: 1' -H 'content-type: application/json' \
    -X "$1" "https://127.0.0.1:$port/api/v1$2" ${3:+-d "$3"}
}
api POST /auth/login "{\"username\":\"admin\",\"password\":\"$admin_pw\"}" >/dev/null
token=$(api POST /enrollment-tokens '{"name":"dm1","max_uses":1,"expires_in_days":1,"auto_approve":true}' |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')

log "build the $distro ISO"
"$here/snreg-iso" build --distro "$distro" --in "$iso" --server "https://10.0.2.2:$port" \
  --cert-sha256 "$pin" --token "$token" --packages "$packages" --out "$work/install.iso"

log "install into a blank VM (serial $serial)"
qemu-img create -q -f qcow2 "$work/disk.qcow2" 20G
fw=()
if [[ ${BIOS:-0} != 1 ]]; then
  first() { for f in "$@"; do [[ -f $f ]] && { echo "$f"; return; }; done; return 0; }
  ovmf=$(first /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd)
  vars=$(first /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd)
  [[ -n $ovmf && -n $vars ]] || { echo "no OVMF firmware (BIOS=1 to skip UEFI)" >&2; exit 1; }
  cp "$vars" "$work/vars.fd"
  # shellcheck disable=SC2054 # qemu option values, not array separators
  fw=(-drive if=pflash,format=raw,readonly=on,file="$ovmf" -drive if=pflash,format=raw,file="$work/vars.fd")
fi
qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 2 -display none "${fw[@]}" \
  -smbios type=1,manufacturer=SNReg,product=DM1-VM,serial="$serial" \
  -drive file="$work/disk.qcow2",if=none,id=disk -device virtio-blk-pci,drive=disk,bootindex=0 \
  -drive file="$work/install.iso",if=none,id=cd,media=cdrom,readonly=on -device ide-cd,drive=cd,bootindex=1 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -monitor unix:"$work/mon",server,nowait -serial file:"$work/console.log" -daemonize -pidfile "$work/qemu.pid"
qemu_pid=$(cat "$work/qemu.pid")

log "wait for the device (installs take 5-30 minutes)"
check() { # prints the device status; succeeds once it's active with the right asset
  api GET '/devices?limit=10' | python3 -c "
import json, sys
items = json.load(sys.stdin)['items']
if not items: sys.exit('no device yet')
d = items[0]
print(d['status'], d['kmod_status'], d['serial'], d['os_id'], d['os_version'])
sys.exit(0 if d['status'] in ('active', 'degraded') else 1)"
}
deadline=$((SECONDS + ${TIMEOUT_MIN:-45} * 60))
until out=$(check 2>&1); do
  if ((SECONDS > deadline)) || ! kill -0 "$qemu_pid" 2>/dev/null; then
    echo "FAIL DM-1 $distro: $out"
    # The screen shows installer errors that never reach the serial console.
    python3 -c "import socket,time; s=socket.socket(socket.AF_UNIX); s.connect('$work/mon'); time.sleep(.3); s.recv(9999); s.sendall(b'screendump $work/screen.ppm\\n'); time.sleep(1)" 2>/dev/null &&
      echo "screen: $work/screen.ppm" || true
    tail -40 "$work/console.log" 2>/dev/null || true
    docker logs --tail 40 "$srv" 2>&1 || true
    exit 1
  fi
  sleep 20
done
echo "device: $out"
dev=$(api GET '/devices?limit=1' | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["id"])')
api GET "/devices/$dev" | python3 -c "
import json, sys
d = json.load(sys.stdin)
dev, assets = d['device'], d['assets']
assert dev['status'] == 'active', f\"status {dev['status']} (kmod {dev['kmod_status']}): DM-1 wants active\"
assert dev['serial'] == '$serial', dev['serial']
assert len(assets) == 1 and assets[0]['serial'] == '$serial', assets
print('PASS DM-1 $distro:', dev['id'], 'asset', assets[0]['asset_tag'], 'serial', assets[0]['serial'])"
ok=1
