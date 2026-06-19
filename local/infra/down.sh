#!/usr/bin/env bash
# tears down the local stack.
# use --keep-cluster to remove only the app workloads, keep the kind cluster.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
CLUSTER=pr-reviewer

if [[ "${1:-}" == "--keep-cluster" ]]; then
  kubectl --context "kind-$CLUSTER" delete all --all || true
  echo "workloads removed; cluster '$CLUSTER' kept"
else
  kind delete cluster --name "$CLUSTER"
  echo "cluster '$CLUSTER' deleted"
fi
