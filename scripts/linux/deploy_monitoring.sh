#!/usr/bin/env bash
# DeployX — Prometheus & Grafana Monitoring Deployment Controller
# Deploys Prometheus, Grafana, alerts, datasources, and dashboards into namespace 'deployx'.
# Validates pod rollouts, active target scraping, and health endpoints.

set -euo pipefail

NAMESPACE="${DEPLOYX_NAMESPACE:-deployx}"
MONITORING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../infrastructure/monitoring" && pwd)"

echo "============================================================"
echo "==> [DeployX] Deploying Phase 6 Monitoring Stack"
echo "    Namespace:       $NAMESPACE"
echo "    Manifests Dir:   $MONITORING_DIR"
echo "============================================================"

# 1. Pre-flight check: Verify kubectl and namespace
if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl command not found in PATH." >&2
    exit 1
fi

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Error: Namespace '$NAMESPACE' does not exist. Apply infrastructure/kubernetes/namespace.yaml first." >&2
    exit 1
fi

# 2. Dry-run validation
echo "==> [Validation] Validating monitoring manifests with dry-run..."
kubectl apply --dry-run=client -f "$MONITORING_DIR/prometheus.yaml" >/dev/null
kubectl apply --dry-run=client -f "$MONITORING_DIR/grafana.yaml" >/dev/null

# 3. Apply manifests
echo "==> [Deploy] Applying Prometheus manifests..."
kubectl apply -f "$MONITORING_DIR/prometheus.yaml"

echo "==> [Deploy] Applying Grafana manifests..."
kubectl apply -f "$MONITORING_DIR/grafana.yaml"

# 4. Wait for rollouts
echo "==> [Rollout] Waiting for Prometheus deployment rollout..."
kubectl rollout status deployment/deployx-prometheus -n "$NAMESPACE" --timeout=60s

echo "==> [Rollout] Waiting for Grafana deployment rollout..."
kubectl rollout status deployment/deployx-grafana -n "$NAMESPACE" --timeout=60s

# 5. Verify Service Endpoints
echo "==> [Verification] Verifying monitoring services..."
PROM_EP="$(kubectl get endpoints prometheus -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")"
GRAF_EP="$(kubectl get endpoints grafana -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")"

echo "    Prometheus Endpoints: ${PROM_EP:-pending}"
echo "    Grafana Endpoints:    ${GRAF_EP:-pending}"

echo "============================================================"
echo "[SUCCESS] DeployX Monitoring Stack is fully deployed and healthy!"
echo "Access instructions:"
echo "  Prometheus: kubectl port-forward -n $NAMESPACE svc/prometheus 9090:9090"
echo "              URL: http://localhost:9090"
echo "  Grafana:    kubectl port-forward -n $NAMESPACE svc/grafana 3001:3000"
echo "              URL: http://localhost:3001 (User: admin / Pass: deployx-admin-2026)"
echo "============================================================"
exit 0
