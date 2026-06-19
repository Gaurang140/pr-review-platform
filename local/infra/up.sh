#!/usr/bin/env bash
# brings up the local AWS replacement: a kind cluster (EKS) running
# Postgres (RDS), Redis (ElastiCache) and MinIO (S3). no AWS, no cost.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.docker/bin:$PATH"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER=pr-reviewer

echo "==> [1/3] ensuring kind cluster '$CLUSTER' exists (replaces AWS EKS)"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "    cluster already exists"
else
  kind create cluster --config "$HERE/kind-config.yaml"
fi
kind export kubeconfig --name "$CLUSTER" >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=150s

# preload images so the node never pulls from docker hub mid-deploy
load_img() {
  img="$1"; mirror="$2"
  docker image inspect "$img" >/dev/null 2>&1 || docker pull "$img" 2>/dev/null || {
    [ -n "$mirror" ] && docker pull "$mirror" && docker tag "$mirror" "$img"
  }
  docker save "$img" | docker exec -i "${CLUSTER}-control-plane" ctr -n k8s.io images import - >/dev/null 2>&1 || true
}
echo "    preloading data-plane images"
load_img postgres:15-alpine public.ecr.aws/docker/library/postgres:15-alpine
load_img redis:7-alpine     public.ecr.aws/docker/library/redis:7-alpine
load_img minio/minio:latest ""
load_img minio/mc:latest    ""

echo "==> [2/3] deploying data plane: Postgres(RDS) + Redis(ElastiCache) + MinIO(S3)"
kubectl delete job minio-make-bucket --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -f "$HERE/data-plane/"

echo "==> [3/3] waiting for data plane to become ready"
kubectl rollout status deploy/postgres --timeout=120s
kubectl rollout status deploy/redis    --timeout=120s
kubectl rollout status deploy/minio    --timeout=120s
kubectl wait --for=condition=complete job/minio-make-bucket --timeout=120s || true

echo ""
echo "================  LOCAL STACK IS UP  ================"
kubectl get pods -o wide
echo ""
echo "Postgres (RDS)      -> postgres:5432   db=codereviewer user=dbadmin"
echo "Redis (ElastiCache) -> redis:6379"
echo "MinIO  (S3)         -> minio:9000      bucket=ai-code-reviewer-reports"
echo "MinIO console       -> http://localhost:9001  (minioadmin/minioadmin)"
echo ""
echo "next: fill in local/.env then run:  bash local/sync-secret.sh && bash local/deploy.sh"
