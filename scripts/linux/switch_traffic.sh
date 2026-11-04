#!/usr/bin/env bash
# DeployX — Blue-Green Traffic Switching Controller
# Switches the active Kubernetes routing service ('backend') between Blue and Green deployments.
# Validates target deployment readiness before cutover and automatically rolls back on endpoint failure.

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Argument & Usage Validation
# ------------------------------------------------------------------------------
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <blue|green>" >&2
    exit 1
fi

TARGET_COLOR="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
if [[ "$TARGET_COLOR" != "blue" && "$TARGET_COLOR" != "green" ]]; then
    echo "Error: Invalid color '$1'. Must be 'blue' or 'green'." >&2
    exit 1
fi

NAMESPACE="${DEPLOYX_NAMESPACE:-deployx}"
SERVICE_NAME="${DEPLOYX_BACKEND_SERVICE:-backend}"
ENDPOINT_TIMEOUT="${DEPLOYX_ENDPOINT_TIMEOUT:-15}"

if [[ "$TARGET_COLOR" == "blue" ]]; then
    TARGET_DEPLOYMENT="deployx-backend"
else
    TARGET_DEPLOYMENT="deployx-backend-green"
fi

# ------------------------------------------------------------------------------
# 2. Pre-flight Target Deployment Health Check
# ------------------------------------------------------------------------------
echo "==> [Pre-flight] Verifying target deployment '$TARGET_DEPLOYMENT' in namespace '$NAMESPACE'..."

if ! kubectl get deployment "$TARGET_DEPLOYMENT" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Error: Deployment '$TARGET_DEPLOYMENT' does not exist in namespace '$NAMESPACE'." >&2
    exit 1
fi

if ! kubectl rollout status deployment/"$TARGET_DEPLOYMENT" -n "$NAMESPACE" --timeout=30s; then
    echo "Error: Target deployment '$TARGET_DEPLOYMENT' is not fully rolled out. Aborting traffic switch." >&2
    exit 1
fi

READY_REPLICAS="$(kubectl get deployment "$TARGET_DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
if [[ -z "$READY_REPLICAS" || "$READY_REPLICAS" -lt 1 ]]; then
    echo "Error: Deployment '$TARGET_DEPLOYMENT' has zero ready replicas ($READY_REPLICAS). Aborting traffic switch." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. Capture Current Service State for Reversion
# ------------------------------------------------------------------------------
PREV_COLOR="$(kubectl get service "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.selector.deployment-color}' 2>/dev/null || echo "")"
if [[ -z "$PREV_COLOR" ]]; then
    PREV_COLOR="blue"
fi

if [[ "$PREV_COLOR" == "$TARGET_COLOR" ]]; then
    echo "==> Traffic is already routed to '$TARGET_COLOR'. No switch required."
    exit 0
fi

# ------------------------------------------------------------------------------
# 4. Patch Service Selector to Target Color
# ------------------------------------------------------------------------------
echo "==> [Cutover] Switching traffic on service '$SERVICE_NAME' from '$PREV_COLOR' to '$TARGET_COLOR'..."

PATCH_PAYLOAD="{\"spec\":{\"selector\":{\"app\":\"deployx-backend\",\"deployment-color\":\"$TARGET_COLOR\"}}}"
if ! kubectl patch service "$SERVICE_NAME" -n "$NAMESPACE" --type=merge -p "$PATCH_PAYLOAD"; then
    echo "Error: Failed to patch service '$SERVICE_NAME'. Restoring previous state..." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 5. Verify Ready Endpoints for Target Color
# ------------------------------------------------------------------------------
echo "==> [Verification] Polling active endpoints for '$SERVICE_NAME' ($TARGET_COLOR)..."

VERIFIED=false
ENDPOINTS=""

for _ in $(seq 1 "$ENDPOINT_TIMEOUT"); do
    ENDPOINTS="$(kubectl get endpoints "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")"
    if [[ -n "$ENDPOINTS" ]]; then
        VERIFIED=true
        break
    fi
    sleep 1
done

# ------------------------------------------------------------------------------
# 6. Automatic Rollback on Verification Failure
# ------------------------------------------------------------------------------
if [[ "$VERIFIED" != "true" ]]; then
    echo "Error: Verification failed. No healthy endpoints found for '$TARGET_COLOR' within timeout." >&2
    echo "==> [Rollback] Restoring service '$SERVICE_NAME' selector to '$PREV_COLOR'..." >&2

    ROLLBACK_PAYLOAD="{\"spec\":{\"selector\":{\"app\":\"deployx-backend\",\"deployment-color\":\"$PREV_COLOR\"}}}"
    kubectl patch service "$SERVICE_NAME" -n "$NAMESPACE" --type=merge -p "$ROLLBACK_PAYLOAD" || true
    echo "==> [Rollback] Restored '$SERVICE_NAME' selector to '$PREV_COLOR'." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 7. Success Output
# ------------------------------------------------------------------------------
echo "============================================================"
echo "[SUCCESS] Traffic successfully switched to $TARGET_COLOR."
echo "Service:          $SERVICE_NAME"
echo "Target:           $TARGET_DEPLOYMENT"
echo "Active Endpoints: $ENDPOINTS"
echo "============================================================"
exit 0
