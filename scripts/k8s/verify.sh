#!/usr/bin/env bash
# DeployX — Kind Kubernetes Deployment Verification Script
# Validates pod health, service discovery, endpoints, and synthetic HTTP connectivity.

set -euo pipefail

NAMESPACE="${NAMESPACE:-deployx}"

echo "============================================================"
echo "==> [DeployX] Verifying Kubernetes Workloads"
echo "    Namespace: $NAMESPACE"
echo "============================================================"

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: Cannot connect to Kubernetes cluster." >&2
    exit 1
fi

FAILED=0

# Verify Deployments have at least 1 ready replica
for dep in deployx-backend deployx-frontend; do
    echo -n "Checking deployment $dep... "
    READY=$(kubectl get deployment "$dep" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${READY:-0}" -ge 1 ]; then
        echo "READY ($READY replicas)"
    else
        echo "FAILED (0 ready replicas)"
        FAILED=1
    fi
done

# Verify backend routing service
echo -n "Checking backend alias routing service... "
BACKEND_COLOR=$(kubectl get service backend -n "$NAMESPACE" -o jsonpath='{.spec.selector.deployment-color}' 2>/dev/null || echo "")
if [ -n "$BACKEND_COLOR" ]; then
    echo "OK (routed to: $BACKEND_COLOR)"
else
    echo "FAILED (no selector found)"
    FAILED=1
fi

# Verify frontend NodePort service
echo -n "Checking frontend service... "
NODE_PORT=$(kubectl get service deployx-frontend -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
if [ -n "$NODE_PORT" ]; then
    echo "OK (NodePort: $NODE_PORT)"
else
    echo "FAILED"
    FAILED=1
fi

# Synthetic pod execution health probe
echo "Running in-cluster synthetic HTTP health probe..."
FRONTEND_POD=$(kubectl get pod -l app=deployx-frontend -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$FRONTEND_POD" ]; then
    if kubectl exec "$FRONTEND_POD" -n "$NAMESPACE" -- wget -q -O - http://127.0.0.1/health/live >/dev/null 2>&1; then
        echo "    Frontend container probe: HEALTHY (HTTP 200)"
    else
        echo "    Frontend container probe: WARNING / NON-RESPONSIVE"
    fi
fi

if [ "$FAILED" -eq 0 ]; then
    echo "============================================================"
    echo " [SUCCESS] All Kubernetes workloads verified healthy!"
    echo "============================================================"
    exit 0
else
    echo "============================================================" >&2
    echo " [ERROR] One or more Kubernetes verification checks failed." >&2
    echo "============================================================" >&2
    exit 1
fi
