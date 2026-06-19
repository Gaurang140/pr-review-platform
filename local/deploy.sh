#!/usr/bin/env bash
# builds the service images, loads them into the local kind cluster, and
# deploys the local kustomize overlay. the local stand-in for the aws
# build->push(ecr)->deploy(eks) pipeline. runs from the checked-out repo root.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.docker/bin:/opt/anaconda3/bin:$PATH"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER=pr-reviewer
SERVICES=(gateway webhook orchestrator reviewer learner)

kubectl config use-context "kind-$CLUSTER" >/dev/null

if ! kubectl get secret app-secrets >/dev/null 2>&1; then
  echo "app-secrets not found. run 'bash local/sync-secret.sh' first, then re-run this."
  exit 1
fi

echo "==> build images (retries cover flaky network)"
build_one() {
  for a in 1 2 3 4 5; do
    docker build -q -f "$ROOT/services/$1/Dockerfile" -t "pr-reviewer/$1:local" "$ROOT" && return 0
    echo "   $1 build retry $a"; sleep 3
  done
  return 1
}
for s in "${SERVICES[@]}"; do echo "   $s"; build_one "$s"; done

echo "==> load images into kind"
for s in "${SERVICES[@]}"; do kind load docker-image "pr-reviewer/$s:local" --name "$CLUSTER"; done

echo "==> deploy (kustomize local overlay)"
# the migration job is immutable once it has run, so recreate it each deploy
kubectl delete job db-migrate --ignore-not-found >/dev/null 2>&1 || true
# gateway-lb is the aws-only LoadBalancer; locally the NodePort owns 30080,
# so drop a leftover gateway-lb (e.g. from an older deploy) to free the port
kubectl delete svc gateway-lb --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -k "$ROOT/infra/k8s/overlays/local"
kubectl wait --for=condition=complete job/db-migrate --timeout=150s || echo "   (migration warn - check logs)"
kubectl rollout status deploy/gateway --timeout=150s

echo "deployed. gateway health:"
curl -s --max-time 5 http://localhost:8080/health || true
