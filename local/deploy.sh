#!/usr/bin/env bash
# builds the service images and deploys them to the local kind cluster.
# this is the local stand-in for the aws build->push(ecr)->deploy(eks) pipeline.
# runs on the self-hosted runner from the checked-out repo root.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.docker/bin:/opt/anaconda3/bin:$PATH"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER=pr-reviewer
ECR="789438508565.dkr.ecr.us-east-1.amazonaws.com"
SERVICES=(gateway webhook orchestrator reviewer learner)

kubectl config use-context "kind-$CLUSTER" >/dev/null

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

echo "==> migrate db"
kubectl delete job db-migrate --ignore-not-found >/dev/null 2>&1 || true
sed "s#image: $ECR/webhook:latest#image: pr-reviewer/webhook:local#" "$ROOT/infra/k8s/migration-job.yaml" | kubectl apply -f -
kubectl wait --for=condition=complete job/db-migrate --timeout=150s || echo "   (migration warn - check logs)"

echo "==> deploy services (ecr refs -> local images)"
for f in webhook orchestrator reviewer learner gateway webhook-worker learner-worker; do
  [ -f "$ROOT/infra/k8s/$f.yaml" ] || continue
  sed -E "s#image: $ECR/([a-z-]+):latest#image: pr-reviewer/\1:local#g" "$ROOT/infra/k8s/$f.yaml" | kubectl apply -f -
done
kubectl scale deployment --all --replicas=1 >/dev/null 2>&1 || true
kubectl rollout status deploy/gateway --timeout=150s

echo "deployed. gateway health:"
curl -s --max-time 5 http://localhost:8080/health || true
