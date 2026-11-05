#!/usr/bin/env bash
# DeployX — Kind Kubernetes Cluster Provisioner
# Creates a local, reproducible multi-port Kind Kubernetes cluster for DeployX testing.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-deployx}"
KIND_CONFIG_DIR="$(mktemp -d)"
KIND_CONFIG="$KIND_CONFIG_DIR/kind-config.yaml"

cleanup() {
    rm -rf "$KIND_CONFIG_DIR"
}
trap cleanup EXIT

echo "============================================================"
echo "==> [DeployX] Provisioning Kind Kubernetes Cluster"
echo "    Cluster Name: $CLUSTER_NAME"
echo "============================================================"

# Pre-flight dependency checks
if ! command -v kind >/dev/null 2>&1; then
    echo "Error: 'kind' CLI is not installed or not in PATH." >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "Error: 'docker' CLI is not installed or not in PATH." >&2
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker daemon is not running. Please start Docker first." >&2
    exit 1
fi

# Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "Kind cluster '$CLUSTER_NAME' already exists."
    kubectl cluster-info --context "kind-${CLUSTER_NAME}" || true
    echo "[SUCCESS] Cluster '$CLUSTER_NAME' is ready."
    exit 0
fi

# Generate Kind multi-port cluster configuration
cat << KIND_EOF > "$KIND_CONFIG"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
KIND_EOF

echo "Creating Kind cluster '$CLUSTER_NAME'..."
kind create cluster --config "$KIND_CONFIG"

echo "Waiting for control-plane node to become Ready..."
kubectl wait --for=condition=Ready node --all --timeout=120s --context "kind-${CLUSTER_NAME}"

echo "============================================================"
echo " [SUCCESS] Kind cluster '$CLUSTER_NAME' created and ready!"
echo " Context: kind-${CLUSTER_NAME}"
echo "============================================================"
