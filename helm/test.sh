#!/usr/bin/env bash
# Helm smoke test (spec §9 P7) on a throwaway kind cluster: installs the chart against an
# in-cluster Postgres, waits for the pod, logs in as the first admin over the port-forward.
#   helm/test.sh <image>      e.g. snreg-server:dev (loaded into kind, never pulled)
# Needs docker, kind, kubectl, helm, openssl, curl.
set -euo pipefail
image=${1:?usage: test.sh <image>}
here=$(cd "$(dirname "$0")" && pwd)
cluster=snreg-helm-$$
work=$(mktemp -d)
pf=''
cleanup() {
  [[ -n $pf ]] && kill "$pf" 2>/dev/null || true
  [[ ${ok:-0} = 1 ]] || { kubectl --context "kind-$cluster" get pods -A 2>&1 | tail -20;
    kubectl --context "kind-$cluster" logs deploy/snreg --all-containers --tail 30 2>&1 || true; }
  kind delete cluster --name "$cluster" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# nftables: hosts without legacy iptables (recent kernels) break kube-proxy's default mode.
printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnetworking:\n  kubeProxyMode: nftables\n' >"$work/kind.yaml"
kind create cluster --name "$cluster" --config "$work/kind.yaml" --wait 120s >/dev/null 2>&1
k() { kubectl --context "kind-$cluster" "$@"; }
kind load docker-image "$image" --name "$cluster" >/dev/null

pgpw=$(openssl rand -hex 16)
k create secret generic pg --from-literal=password="$pgpw" >/dev/null
k apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: { name: pg }
spec:
  selector: { matchLabels: { app: pg } }
  template:
    metadata: { labels: { app: pg } }
    spec:
      containers:
        - name: pg
          image: postgres:16
          env:
            - { name: POSTGRES_USER, value: snreg }
            - { name: POSTGRES_PASSWORD, valueFrom: { secretKeyRef: { name: pg, key: password } } }
          readinessProbe: { exec: { command: [pg_isready, -U, snreg] }, periodSeconds: 3 }
---
apiVersion: v1
kind: Service
metadata: { name: pg }
spec: { selector: { app: pg }, ports: [{ port: 5432 }] }
YAML
k rollout status deploy/pg --timeout 180s >/dev/null

openssl req -x509 -newkey ed25519 -nodes -days 1 -subj /CN=localhost -keyout "$work/tls.key" -out "$work/tls.crt" 2>/dev/null
k create secret tls snreg-tls --cert "$work/tls.crt" --key "$work/tls.key" >/dev/null
k create secret generic snreg --from-literal=database-url="postgres://snreg:$pgpw@pg:5432/snreg" \
  --from-literal=master-key="$(openssl rand -base64 32)" >/dev/null
helm --kube-context "kind-$cluster" install snreg "$here/snreg" --wait --timeout 5m \
  --set image.repository="${image%:*}",image.tag="${image##*:}",image.pullPolicy=Never \
  --set publicUrl=https://localhost:8443,existingSecret=snreg,tlsSecret=snreg-tls \
  --set https.service.type=ClusterIP,wireguard.service.type=ClusterIP >/dev/null

port=$((19300 + RANDOM % 300))
k port-forward svc/snreg "$port:443" >/dev/null 2>&1 &
pf=$!
for _ in $(seq 30); do curl -skf "https://127.0.0.1:$port/api/v1/health" >/dev/null && break; sleep 1; done
pw=$(k logs deploy/snreg -c init | sed -n 's/.*password: //p')
[[ -n $pw ]] || { echo "FAIL: init printed no admin password"; exit 1; }
curl -skf -H 'X-SNReg-CSRF: 1' -H 'content-type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$pw\"}" "https://127.0.0.1:$port/api/v1/auth/login" >/dev/null
ok=1
echo "PASS helm: chart installs on kind, admin logs in"
