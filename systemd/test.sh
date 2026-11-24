#!/usr/bin/env bash
# The "runs in minutes" path of spec §8, verbatim, in a Debian 12 container booted with systemd:
#   apt install ./snreg-server.deb postgresql ; snreg-server init ; systemctl enable --now snreg-server
# then the health endpoint over TLS and the first admin's login.
#   systemd/test.sh <snreg-server_*.deb>
set -euo pipefail
deb=$(realpath "${1:?usage: test.sh <snreg-server.deb>}")
c=snreg-systemd-$$
cleanup() { [[ ${ok:-0} = 1 ]] || docker exec "$c" journalctl -u snreg-server --no-pager -n 30 2>/dev/null; docker rm -f "$c" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker build -q -t snreg-systemd-debian:12 - >/dev/null <<'DOCKERFILE'
FROM debian:12
# Docker's Debian image blocks service starts during apt; a real host doesn't.
RUN rm -f /usr/sbin/policy-rc.d && apt-get update -qq && apt-get install -y -qq systemd systemd-sysv curl >/dev/null && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
DOCKERFILE
docker run -d --name "$c" --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
  --cap-add NET_ADMIN -v "$deb":/root/snreg-server.deb:ro snreg-systemd-debian:12 >/dev/null
ct() { docker exec "$c" "$@"; }
for _ in $(seq 30); do ct systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break; sleep 1; done
ct sh -ec 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq /root/snreg-server.deb postgresql >/dev/null 2>&1'
out=$(ct snreg-server init)
pw=$(sed -n 's/.*password: //p' <<<"$out")
ct systemctl enable --now snreg-server >/dev/null 2>&1
for _ in $(seq 30); do ct curl -skf https://127.0.0.1:8443/api/v1/health >/dev/null && break; sleep 1; done
ct curl -skf -H 'X-SNReg-CSRF: 1' -H 'content-type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$pw\"}" https://127.0.0.1:8443/api/v1/auth/login >/dev/null
# The master key stays root-only; the service reads it through LoadCredential.
[[ $(ct stat -c '%U %a' /etc/snreg/master.key) == 'root 600' ]]
[[ $(ct sh -c 'stat -c %U /proc/$(systemctl show -p MainPID --value snreg-server)') == snreg ]]
ok=1
echo "PASS systemd: .deb + postgresql, init, enable --now; runs as snreg, admin logs in"
