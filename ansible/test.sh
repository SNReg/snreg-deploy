#!/usr/bin/env bash
# Ansible smoke test (spec §9 P7): two Debian 12 containers booted with systemd. snreg_server
# installs and starts the server in one; snreg_agent enrolls the other against it. Ansible runs
# inside each target (connection local), so the host needs only docker.
#   ansible/test.sh <snreg-server .deb> <snreg-agent .deb>
set -euo pipefail
server_deb=$(realpath "${1:?usage: test.sh <server .deb> <agent .deb>}")
agent_deb=$(realpath "${2:?usage: test.sh <server .deb> <agent .deb>}")
here=$(cd "$(dirname "$0")" && pwd)
net=snreg-ansible-$$ srv=snreg-srv-$$ agt=snreg-agt-$$
cleanup() {
  [[ ${ok:-0} = 1 ]] || docker exec "$srv" journalctl -u snreg-server --no-pager -n 20 2>/dev/null || true
  docker rm -f "$srv" "$agt" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker build -q -t snreg-ansible-debian:12 - >/dev/null <<'DOCKERFILE'
FROM debian:12
# Docker's Debian image blocks service starts during apt; a real host doesn't.
RUN rm -f /usr/sbin/policy-rc.d && apt-get update -qq \
 && apt-get install -y -qq systemd systemd-sysv ansible-core python3-apt curl openssl >/dev/null \
 && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
DOCKERFILE
docker network create "$net" >/dev/null
boot() { # boot <name> <package>
  docker run -d --name "$1" --hostname "$1" --network "$net" --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock --cap-add NET_ADMIN -v "$here":/ansible:ro -v "$2":"/pkg/$(basename "$2")":ro \
    snreg-ansible-debian:12 >/dev/null
  for _ in $(seq 30); do docker exec "$1" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break; sleep 1; done
}
play() { # play <container> <role> <extra vars json>: prints the play's output
  docker exec "$1" sh -c "printf -- '- hosts: localhost\n  roles: [$2]\n' >/tmp/play.yml &&
    ANSIBLE_ROLES_PATH=/ansible/roles ansible-playbook -i localhost, -c local /tmp/play.yml -e '$3'"
}

boot "$srv" "$server_deb"
vars="{\"snreg_server_package\":\"/pkg/$(basename "$server_deb")\"}"
out=$(play "$srv" snreg_server "$vars") || { echo "$out" | tail -30; exit 1; }
pw=$(sed -n 's/.*with password: \([A-Za-z0-9]*\).*/\1/p' <<<"$out" | head -1)
[[ -n $pw ]] || { echo "FAIL: the role didn't show the first admin's password"; exit 1; }
# Idempotent: a second run doesn't re-init.
out=$(play "$srv" snreg_server "$vars") || { echo "$out" | tail -30; exit 1; }
grep -q 'snreg-server init.*' <<<"$out" && ! grep -q 'with password' <<<"$out"

api() { docker exec "$srv" curl -skf -b /root/jar -c /root/jar -H 'X-SNReg-CSRF: 1' -H 'content-type: application/json' \
  -X "$1" "https://127.0.0.1:8443/api/v1$2" ${3:+-d "$3"}; }
api POST /auth/login "{\"username\":\"admin\",\"password\":\"$pw\"}" >/dev/null
token=$(api POST /enrollment-tokens '{"name":"ansible","max_uses":1,"expires_in_days":1,"auto_approve":true}' |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
pin=$(docker exec "$srv" sh -c 'openssl x509 -in /etc/snreg/tls.crt -outform DER | sha256sum | cut -d" " -f1')

# No kernel module in a container: the device enrolls and reports degraded.
boot "$agt" "$agent_deb"
vars="{\"snreg_agent_packages\":[\"/pkg/$(basename "$agent_deb")\"],\"snreg_agent_kmod\":false,
  \"snreg_server_url\":\"https://$srv:8443\",\"snreg_server_cert_sha256\":\"$pin\",\"snreg_enrollment_token\":\"$token\"}"
out=$(play "$agt" snreg_agent "$vars") || { echo "$out" | tail -30; exit 1; }
! grep -q "$token" <<<"$out" || { echo "FAIL: the enrollment token leaked into the play's output"; exit 1; }
for _ in $(seq 60); do
  status=$(api GET '/devices?limit=1' | python3 -c 'import json,sys; i=json.load(sys.stdin)["items"]; print(i[0]["status"] if i else "")')
  [[ $status =~ ^(active|degraded)$ ]] && break
  sleep 2
done
[[ $status =~ ^(active|degraded)$ ]] || { echo "FAIL: device status '$status'"; docker exec "$agt" journalctl -u snreg-enroll -u snreg-agentd --no-pager -n 30; exit 1; }
ok=1
echo "PASS ansible: snreg_server installs and is idempotent; snreg_agent enrolls ($status)"
