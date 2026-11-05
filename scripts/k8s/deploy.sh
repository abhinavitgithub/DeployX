#!/usr/bin/env bash
# DeployX — Kind Kubernetes Deployment Script
# Loads images and applies all manifests to the local Kind Kubernetes cluster.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
K8S_DIR="$ROOT_DIR/infrastructure/kubernetes"
CLUSTER_NAME="${CLUSTER_NAME:-deployx}"
NAMESPACE="${NAMESPACE:-deployx}"

echo "============================================================"
echo "==> [DeployX] Deploying to Kind Cluster '$CLUSTER_NAME'"
echo "    Namespace: $NAMESPACE"
echo "============================================================"

# Ensure kubectl is configured
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: Cannot connect to Kubernetes cluster." >&2
    exit 1
fi

# Load local Docker images if available
if command -v kind >/dev/null 2>&1; then
    if docker image inspect deployx-backend:latest >/dev/null 2>&1; then
        echo "Loading deployx-backend:latest into Kind cluster '$CLUSTER_NAME'..."
        kind load docker-image deployx-backend:latest --name "$CLUSTER_NAME" || true
    fi
    if docker image inspect deployx-frontend:latest >/dev/null 2>&1; then
        echo "Loading deployx-frontend:latest into Kind cluster '$CLUSTER_NAME'..."
        kind load docker-image deployx-frontend:latest --name "$CLUSTER_NAME" || true
    fi
fi

# Apply manifests in dependency order
echo "Applying Kubernetes manifests..."
kubectl apply -f "$K8S_DIR/namespace.yaml"
kubectl apply -f "$K8S_DIR/configmap.yaml"
kubectl apply -f "$K8S_DIR/backend.yaml"
kubectl apply -f "$K8S_DIR/backend-green.yaml"
kubectl apply -f "$K8S_DIR/backend-alias.yaml"
kubectl apply -f "$K8S_DIR/frontend.yaml"

# Wait for rollouts
echo "Waiting for backend rollout..."
kubectl rollout status deployment/deployx-backend -n "$NAMESPACE" --timeout=90s

echo "Waiting for frontend rollout..."
kubectl rollout status deployment/deployx-frontend -n "$NAMESPACE" --timeout=90s

echo "============================================================"
echo " [SUCCESS] Kubernetes resources deployed successfully!"
kubectl get pods,svc,endpoints -n "$NAMESPACE"
echo "============================================================"
