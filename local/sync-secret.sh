#!/usr/bin/env bash
# reads local/.env + the .pem in local/ and syncs app-secrets into the kind cluster.
# run this any time you change env values or rotate the github app key.
# only credentials go in the secret - non-secret wiring lives in the app-config
# ConfigMap (infra/k8s/overlays/local/configmap.yaml).
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.docker/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
PEM_FILE="$(ls "$SCRIPT_DIR"/*.pem 2>/dev/null | head -1)"

if [ ! -f "$ENV_FILE" ]; then
  echo "error: local/.env not found. copy local/.env.example and fill it in."
  exit 1
fi

kubectl config use-context kind-pr-reviewer >/dev/null

# read one value out of .env (kept bash 3.2 friendly - no associative arrays)
getval() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true; }

args=()
for key in \
  DATABASE_URL \
  GITHUB_APP_ID \
  GITHUB_WEBHOOK_SECRET \
  LANGFUSE_PUBLIC_KEY \
  LANGFUSE_SECRET_KEY \
  AWS_ACCESS_KEY_ID \
  AWS_SECRET_ACCESS_KEY; do
  val="$(getval "$key")"
  [ -n "$val" ] && args+=("--from-literal=${key}=${val}")
done

# groq key goes in as GROQ_API_KEY and also as OPENAI_API_KEY
# (some manifests reference OPENAI_API_KEY; our code prefers GROQ_API_KEY)
groq="$(getval GROQ_API_KEY)"
if [ -n "$groq" ]; then
  args+=("--from-literal=GROQ_API_KEY=${groq}")
  args+=("--from-literal=OPENAI_API_KEY=${groq}")
fi

# private key: prefer the .pem file over the .env value (multiline safe)
if [ -n "$PEM_FILE" ]; then
  args+=("--from-file=GITHUB_APP_PRIVATE_KEY=${PEM_FILE}")
  echo "  private key: using $PEM_FILE"
else
  pem_val="$(getval GITHUB_APP_PRIVATE_KEY)"
  [ -n "$pem_val" ] && args+=("--from-literal=GITHUB_APP_PRIVATE_KEY=${pem_val}")
fi

if [ "${#args[@]}" -eq 0 ]; then
  echo "error: no values found in local/.env"
  exit 1
fi

echo "==> syncing app-secrets to kind-pr-reviewer"
kubectl delete secret app-secrets --ignore-not-found >/dev/null
kubectl create secret generic app-secrets "${args[@]}"

echo "==> restarting deployments to pick up new values"
kubectl rollout restart deployment >/dev/null 2>&1 || true

echo "done. current secret keys:"
kubectl get secret app-secrets -o jsonpath='{.data}' \
  | tr ',' '\n' | grep -o '"[^"]*":' | tr -d '":'
