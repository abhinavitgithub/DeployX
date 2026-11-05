#!/usr/bin/env bash
# DeployX — Blue-Green Rollback Controller
# Instantly rolls back active Kubernetes routing to the previous standby environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
NAMESPACE="${DEPLOYX_NAMESPACE:-deployx}"
SERVICE_NAME="backend"

echo "============================================================"
echo "==> [DeployX] Blue-Green Emergency Rollback Controller"
echo "    Namespace: $NAMESPACE"
echo "============================================================"

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: Cannot connect to Kubernetes cluster." >&2
    exit 1
fi

# Detect current color
CURRENT_COLOR=$(kubectl get service "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.selector.deployment-color}' 2>/dev/null || echo "blue")

if [ "$CURRENT_COLOR" = "blue" ]; then
    ROLLBACK_COLOR="green"
else
    ROLLBACK_COLOR="blue"
fi

echo "Current routed color:  $CURRENT_COLOR"
echo "Reverting traffic to: $ROLLBACK_COLOR"

# Execute switch via existing verified traffic switch script
if [ -f "$ROOT_DIR/scripts/linux/switch_traffic.sh" ]; then
    bash "$ROOT_DIR/scripts/linux/switch_traffic.sh" "$ROLLBACK_COLOR"
else
    PATCH_PAYLOAD="{\"spec\":{\"selector\":{\"app\":\"deployx-backend\",\"deployment-color\":\"$ROLLBACK_COLOR\"}}}"
    kubectl patch service "$SERVICE_NAME" -n "$NAMESPACE" --type=merge -p "$PATCH_PAYLOAD"
fi

echo "============================================================"
echo " [SUCCESS] Rollback completed successfully!"
echo " Service '$SERVICE_NAME' is now routed to '$ROLLBACK_COLOR'."
echo "============================================================"
