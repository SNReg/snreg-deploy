#!/usr/bin/env bash
# Smoke test (spec §9 P7): `docker compose up` brings up a working stack. Checks health, that
# init printed the first admin's password, and that the admin can log in over TLS.
#   compose/test.sh [image]        (default: ghcr.io/snreg/snreg-server:$SNREG_VERSION)
# Uses a throwaway project and ports; SNREG_WG_ENABLED=false unless WG=1, so a local run
# doesn't add a WireGuard interface to the host.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
cp "$here/docker-compose.yml" "$work/"
port=$((18900 + RANDOM % 300)) pgport=$((55500 + RANDOM % 300))
cat >"$work/.env" <<ENV
POSTGRES_PASSWORD=$(openssl rand -hex 16)
SNREG_PUBLIC_URL=https://127.0.0.1:$port
SNREG_PORT=$port
POSTGRES_PORT=$pgport
SNREG_WG_ENABLED=$([[ ${WG:-0} = 1 ]] && echo true || echo false)
${1:+SNREG_IMAGE=$1}
ENV
mkdir -m 700 "$work/snreg"
openssl req -x509 -newkey ed25519 -nodes -days 1 -subj /CN=localhost \
  -keyout "$work/snreg/tls.key" -out "$work/snreg/tls.crt" 2>/dev/null
dc() { docker compose -p "snreg-compose-$$" --project-directory "$work" "$@"; }
cleanup() {
  dc logs --no-color >"$work/logs.txt" 2>&1 || true
  [[ ${ok:-0} = 1 ]] || tail -40 "$work/logs.txt"
  dc down -v >/dev/null 2>&1 || true
  docker run --rm -v "$work":/w alpine rm -rf /w/snreg >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

dc up -d --wait
curl -skf "https://127.0.0.1:$port/api/v1/health" >/dev/null
pw=$(dc logs --no-color init | sed -n 's/.*password: //p')
[[ -n $pw ]] || { echo "FAIL: init printed no admin password"; exit 1; }
curl -skf -H 'X-SNReg-CSRF: 1' -H 'content-type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$pw\"}" "https://127.0.0.1:$port/api/v1/auth/login" >/dev/null
# A second `up` reruns init: it must keep the master key and not make a second admin.
dc up -d --wait
[[ -z $(dc logs --no-color init | sed -n 's/.*password: //p' | sed -n 2p) ]]
curl -sk "https://127.0.0.1:$port/" | grep -qi '<div id="root"\|<html' || { echo "FAIL: no web UI"; exit 1; }
ok=1
echo "PASS compose: stack up, admin logs in, init is idempotent"
