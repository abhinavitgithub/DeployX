#!/usr/bin/env bash
# DeployX — Kind Kubernetes Cluster Teardown Script
# Safely tears down the local Kind cluster and cleans up resources.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-deployx}"

echo "============================================================"
echo "==> [DeployX] Deleting Kind Kubernetes Cluster"
echo "    Cluster Name: $CLUSTER_NAME"
echo "============================================================"

if ! command -v kind >/dev/null 2>&1; then
    echo "Error: 'kind' command not found." >&2
    exit 1
fi

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "Deleting cluster '$CLUSTER_NAME'..."
    kind delete cluster --name "$CLUSTER_NAME"
    echo "[SUCCESS] Kind cluster '$CLUSTER_NAME' successfully deleted."
else
    echo "Cluster '$CLUSTER_NAME' does not exist. Nothing to delete."
fi
