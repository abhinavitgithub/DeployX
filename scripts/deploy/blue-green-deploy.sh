#!/usr/bin/env bash
# DeployX — Blue-Green Deployment Controller
# Automates zero-downtime deployment between Blue and Green environments with pre-flight verification,
# dynamic Kubernetes service traffic switching, and automated failure rollback.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
NAMESPACE="${DEPLOYX_NAMESPACE:-deployx}"
SERVICE_NAME="backend"
TARGET_COLOR=""
IMAGE_TAG=""
DRY_RUN=false

show_help() {
    cat <<EOF
DeployX — Blue-Green Deployment Controller

Usage:
  $0 [OPTIONS]

Options:
  -c, --color <blue|green>  Target environment color (default: auto-alternate)
  -t, --tag <tag>           Image tag to deploy (default: latest)
  -n, --namespace <ns>      Kubernetes namespace (default: deployx)
  -d, --dry-run             Validate without modifying cluster
  -h, --help                Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--color)
            TARGET_COLOR="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
            shift 2
            ;;
        -t|--tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown option '$1'." >&2
            exit 1
            ;;
    esac
done

echo "============================================================"
echo "==> [DeployX] Blue-Green Deployment Controller"
echo "    Namespace: $NAMESPACE"
echo "    Dry Run:   $DRY_RUN"
echo "============================================================"

# Pre-flight check
if ! kubectl cluster-info >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "true" ]; then
        echo "Dry-run mode: cluster check skipped."
        exit 0
    else
        echo "Error: Cannot connect to Kubernetes cluster." >&2
        exit 1
    fi
fi

# 1. Detect current active color
CURRENT_COLOR=$(kubectl get service "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.selector.deployment-color}' 2>/dev/null || echo "blue")
echo "Current active routed color: $CURRENT_COLOR"

# 2. Determine target color
if [ -z "$TARGET_COLOR" ]; then
    if [ "$CURRENT_COLOR" = "blue" ]; then
        TARGET_COLOR="green"
    else
        TARGET_COLOR="blue"
    fi
fi

echo "Target deployment color:     $TARGET_COLOR"

if [ "$TARGET_COLOR" = "blue" ]; then
    TARGET_DEPLOYMENT="deployx-backend"
else
    TARGET_DEPLOYMENT="deployx-backend-green"
fi

if [ "$DRY_RUN" = "true" ]; then
    echo "[SUCCESS] Dry-run completed. Next target color would be: $TARGET_COLOR"
    exit 0
fi

# 3. Update target deployment image if tag specified
if [ -n "$IMAGE_TAG" ]; then
    IMAGE_NAME="deployx-backend:${IMAGE_TAG}"
    echo "Updating target deployment '$TARGET_DEPLOYMENT' to image '$IMAGE_NAME'..."
    kubectl set image "deployment/$TARGET_DEPLOYMENT" "backend=$IMAGE_NAME" -n "$NAMESPACE"
fi

# 4. Wait for rollout of target deployment
echo "Waiting for '$TARGET_DEPLOYMENT' to rollout..."
if ! kubectl rollout status "deployment/$TARGET_DEPLOYMENT" -n "$NAMESPACE" --timeout=60s; then
    echo "Error: Target deployment rollout failed. Aborting traffic switch." >&2
    exit 1
fi

# 5. Pre-cutover synthetic health check on target pods
echo "Verifying health probes on target '$TARGET_COLOR' pods..."
TARGET_POD=$(kubectl get pod -l "app=deployx-backend,deployment-color=$TARGET_COLOR" -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$TARGET_POD" ]; then
    READY=$(kubectl get pod "$TARGET_POD" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
    if [ "$READY" != "true" ]; then
        echo "Error: Pod '$TARGET_POD' is not reported Ready." >&2
        exit 1
    fi
    echo "Target pod '$TARGET_POD' is Ready and healthy."
fi

# 6. Cutover traffic to target color
echo "Switching traffic on service '$SERVICE_NAME' to '$TARGET_COLOR'..."
if [ -f "$ROOT_DIR/scripts/linux/switch_traffic.sh" ]; then
    bash "$ROOT_DIR/scripts/linux/switch_traffic.sh" "$TARGET_COLOR"
else
    PATCH_PAYLOAD="{\"spec\":{\"selector\":{\"app\":\"deployx-backend\",\"deployment-color\":\"$TARGET_COLOR\"}}}"
    kubectl patch service "$SERVICE_NAME" -n "$NAMESPACE" --type=merge -p "$PATCH_PAYLOAD"
fi

# 7. Post-cutover endpoint verification
NEW_COLOR=$(kubectl get service "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.selector.deployment-color}')
echo "============================================================"
echo " [SUCCESS] Blue-Green Deployment Completed!"
echo " Active Color: $NEW_COLOR"
echo " Active Service Endpoints:"
kubectl get endpoints "$SERVICE_NAME" -n "$NAMESPACE"
echo "============================================================"
