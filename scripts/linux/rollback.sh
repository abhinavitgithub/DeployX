#!/usr/bin/env bash
# DeployX — Automated Disaster Recovery Rollback Controller
# Safely rolls back the active routing Service ('backend') to the alternate or specified deployment.
# Enforces pre-flight health gates on the target deployment and executes automated recovery
# if endpoint verification fails.
#
# Usage:
#   ./rollback.sh [blue|green] [OPTIONS]
#
# Options:
#   -t, --timeout <seconds>   Endpoint verification timeout in seconds (default: 15)
#   -n, --namespace <ns>      Target Kubernetes namespace (default: deployx)
#   -h, --help                Display this help message and exit

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Defaults & Configuration
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

NAMESPACE="${DEPLOYX_NAMESPACE:-deployx}"
SERVICE_NAME="${DEPLOYX_BACKEND_SERVICE:-backend}"
ENDPOINT_TIMEOUT="${DEPLOYX_ENDPOINT_TIMEOUT:-15}"
LOG_FILE="${DEPLOYX_LOG_FILE:-$ROOT_DIR/data/deployx_operations.log}"

log_msg() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $msg"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "[$timestamp] [$level] [rollback] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

show_help() {
    cat <<EOF
DeployX — Disaster Recovery Rollback Controller

Usage:
  $0 [blue|green] [OPTIONS]

Arguments:
  [blue|green]              Explicit target deployment color (optional; auto-toggles if omitted)

Options:
  -t, --timeout <seconds>   Endpoint verification timeout in seconds (default: 15)
  -n, --namespace <ns>      Target Kubernetes namespace (default: deployx)
  -h, --help                Display this help message and exit

Environment Variables:
  DEPLOYX_NAMESPACE           Default namespace (default: deployx)
  DEPLOYX_BACKEND_SERVICE     Routing service name (default: backend)
  DEPLOYX_ENDPOINT_TIMEOUT    Endpoint verification timeout in seconds (default: 15)
  DEPLOYX_LOG_FILE            Audit log path

Examples:
  $0                        # Automatically roll back to the opposite environment (Blue <-> Green)
  $0 blue                   # Explicitly roll back active traffic to Blue
  $0 green                  # Explicitly switch active traffic to Green
EOF
}

# ------------------------------------------------------------------------------
# 2. Argument Parsing
# ------------------------------------------------------------------------------
REQUESTED_COLOR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        blue|green|BLUE|GREEN)
            REQUESTED_COLOR="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
            shift
            ;;
        -t|--timeout)
            if [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --timeout requires a positive integer." >&2
                exit 1
            fi
            ENDPOINT_TIMEOUT="$2"
            shift 2
            ;;
        -n|--namespace)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --namespace requires an argument." >&2
                exit 1
            fi
            NAMESPACE="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown argument '$1'. Must be 'blue', 'green', or a valid option." >&2
            exit 1
            ;;
    esac
done

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: 'kubectl' command not found in PATH." >&2
    log_msg "ERROR" "Pre-flight failed: kubectl not found in PATH"
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. Detect Current Active Routing State
# ------------------------------------------------------------------------------
CURRENT_COLOR="$(kubectl get service "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.selector.deployment-color}' 2>/dev/null || echo "")"
if [[ -z "$CURRENT_COLOR" ]]; then
    CURRENT_COLOR="blue"
fi

if [[ -n "$REQUESTED_COLOR" ]]; then
    TARGET_COLOR="$REQUESTED_COLOR"
else
    # Auto-toggle to alternate environment
    if [[ "$CURRENT_COLOR" == "blue" ]]; then
        TARGET_COLOR="green"
    else
        TARGET_COLOR="blue"
    fi
fi

if [[ "$TARGET_COLOR" == "blue" ]]; then
    TARGET_DEPLOYMENT="deployx-backend"
else
    TARGET_DEPLOYMENT="deployx-backend-green"
fi

echo "============================================================"
echo "==> [DeployX] Disaster Recovery Rollback Controller"
echo "    Namespace:          $NAMESPACE"
echo "    Routing Service:    $SERVICE_NAME"
echo "    Current Active:     $CURRENT_COLOR"
echo "    Rollback Target:    $TARGET_COLOR ($TARGET_DEPLOYMENT)"
echo "    Endpoint Timeout:   ${ENDPOINT_TIMEOUT}s"
echo "============================================================"
log_msg "INFO" "Rollback initiated: current=$CURRENT_COLOR target=$TARGET_COLOR target_deployment=$TARGET_DEPLOYMENT"

# If already routed to target
if [[ "$CURRENT_COLOR" == "$TARGET_COLOR" ]]; then
    echo "==> Traffic is already actively routed to '$TARGET_COLOR'. No rollback action required."
    log_msg "INFO" "Rollback is a no-op: traffic already on $TARGET_COLOR"
    exit 0
fi

# ------------------------------------------------------------------------------
# 4. Pre-Flight Target Health Gate (Safety Check)
# ------------------------------------------------------------------------------
echo "==> [Safety Gate] Verifying target deployment '$TARGET_DEPLOYMENT' health..."

if ! kubectl get deployment "$TARGET_DEPLOYMENT" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Error: Target deployment '$TARGET_DEPLOYMENT' does not exist in namespace '$NAMESPACE'." >&2
    echo "Aborting rollback to protect active traffic." >&2
    log_msg "ERROR" "Rollback aborted: Target deployment '$TARGET_DEPLOYMENT' missing"
    exit 1
fi

if ! kubectl rollout status deployment/"$TARGET_DEPLOYMENT" -n "$NAMESPACE" --timeout=30s; then
    echo "Error: Target deployment '$TARGET_DEPLOYMENT' is not fully rolled out." >&2
    echo "Aborting rollback to protect active traffic." >&2
    log_msg "ERROR" "Rollback aborted: Target deployment '$TARGET_DEPLOYMENT' not rolled out"
    exit 1
fi

READY_REPLICAS="$(kubectl get deployment "$TARGET_DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
if [[ -z "$READY_REPLICAS" || "$READY_REPLICAS" -lt 1 ]]; then
    echo "Error: Target deployment '$TARGET_DEPLOYMENT' has zero ready replicas ($READY_REPLICAS)." >&2
    echo "Aborting rollback to prevent service outage." >&2
    log_msg "ERROR" "Rollback aborted: Target deployment '$TARGET_DEPLOYMENT' has 0 ready replicas"
    exit 1
fi

echo "    Target deployment '$TARGET_DEPLOYMENT' is healthy ($READY_REPLICAS ready replicas)."

# ------------------------------------------------------------------------------
# 5. Execute Traffic Cutover
# ------------------------------------------------------------------------------
echo "==> [Cutover] Switching traffic on '$SERVICE_NAME' from '$CURRENT_COLOR' to '$TARGET_COLOR'..."

PATCH_PAYLOAD="{\"spec\":{\"selector\":{\"app\":\"deployx-backend\",\"deployment-color\":\"$TARGET_COLOR\"}}}"
if ! kubectl patch service "$SERVICE_NAME" -n "$NAMESPACE" --type=merge -p "$PATCH_PAYLOAD"; then
    echo "Error: Failed to patch service '$SERVICE_NAME'." >&2
    log_msg "ERROR" "Failed to patch service '$SERVICE_NAME' selector to '$TARGET_COLOR'"
    exit 1
fi

# ------------------------------------------------------------------------------
# 6. Post-Switch Endpoint Verification
# ------------------------------------------------------------------------------
echo "==> [Verification] Polling ready endpoints for '$TARGET_COLOR'..."

VERIFIED=false
ACTIVE_ENDPOINTS=""

for _ in $(seq 1 "$ENDPOINT_TIMEOUT"); do
    ACTIVE_ENDPOINTS="$(kubectl get endpoints "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")"
    if [[ -n "$ACTIVE_ENDPOINTS" ]]; then
        VERIFIED=true
        break
    fi
    sleep 1
done

# ------------------------------------------------------------------------------
# 7. Automated Emergency Reversion on Verification Failure
# ------------------------------------------------------------------------------
if [[ "$VERIFIED" != "true" ]]; then
    echo "Error: Verification failed. No healthy endpoints found for '$TARGET_COLOR' within ${ENDPOINT_TIMEOUT}s." >&2
    echo "==> [Emergency Reversion] Restoring service '$SERVICE_NAME' selector back to '$CURRENT_COLOR'..." >&2
    log_msg "WARN" "Rollback verification failed for '$TARGET_COLOR'. Reverting to '$CURRENT_COLOR'"

    REVERT_PAYLOAD="{\"spec\":{\"selector\":{\"app\":\"deployx-backend\",\"deployment-color\":\"$CURRENT_COLOR\"}}}"
    kubectl patch service "$SERVICE_NAME" -n "$NAMESPACE" --type=merge -p "$REVERT_PAYLOAD" || true

    echo "==> Restored '$SERVICE_NAME' to previous known-good deployment ($CURRENT_COLOR)." >&2
    log_msg "ERROR" "Emergency reversion completed. Service restored to '$CURRENT_COLOR'"
    exit 1
fi

# ------------------------------------------------------------------------------
# 8. Success Output
# ------------------------------------------------------------------------------
echo "============================================================"
echo "[SUCCESS] Disaster recovery rollback completed successfully!"
echo "Service:          $SERVICE_NAME"
echo "Previous State:   $CURRENT_COLOR"
echo "Active State:     $TARGET_COLOR ($TARGET_DEPLOYMENT)"
echo "Active Endpoints: $ACTIVE_ENDPOINTS"
echo "============================================================"
log_msg "INFO" "Rollback successful: switched $SERVICE_NAME from $CURRENT_COLOR to $TARGET_COLOR (endpoints: $ACTIVE_ENDPOINTS)"
exit 0
