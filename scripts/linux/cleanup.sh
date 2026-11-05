#!/usr/bin/env bash
# DeployX — Cluster Cleanup & Teardown Controller
# Provides safe, tiered teardown of DeployX Kubernetes resources (all, monitoring-only, or green-only).
# Requires explicit confirmation unless --force / -y is passed.
#
# Usage:
#   ./cleanup.sh [OPTIONS]
#
# Options:
#   --all                     Remove all DeployX resources including namespace
#   --monitoring-only         Remove only Prometheus & Grafana monitoring stack
#   --green-only              Remove only inactive Green deployment
#   -d, --dry-run             Preview resources to be deleted without executing deletion
#   -f, -y, --force           Bypass interactive confirmation prompt
#   -n, --namespace <ns>      Target Kubernetes namespace (default: deployx)
#   -h, --help                Display this help message and exit

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Defaults & Configuration
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

NAMESPACE="${DEPLOYX_NAMESPACE:-deployx}"
LOG_FILE="${DEPLOYX_LOG_FILE:-$ROOT_DIR/data/deployx_operations.log}"

MODE="all"
DRY_RUN=false
FORCE=false

log_msg() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $msg"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "[$timestamp] [$level] [cleanup] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

show_help() {
    cat <<EOF
DeployX — Cluster Cleanup & Teardown Controller

Usage:
  $0 [OPTIONS]

Options:
  --all               Remove all DeployX resources (default mode)
  --monitoring-only   Remove only Phase 6 Prometheus & Grafana monitoring stack
  --green-only        Remove only inactive Green deployment
  -d, --dry-run       Preview targeted resources without executing deletion
  -f, -y, --force     Bypass interactive confirmation prompt
  -n, --namespace <ns> Target namespace (default: deployx)
  -h, --help          Display this help message and exit

Examples:
  $0 --dry-run                  # Preview complete teardown
  $0 --all -y                   # Teardown everything without prompt
  $0 --monitoring-only          # Remove monitoring stack only
  $0 --green-only               # Remove Green deployment to free memory
EOF
}

# ------------------------------------------------------------------------------
# 2. Argument Parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            MODE="all"
            shift
            ;;
        --monitoring-only)
            MODE="monitoring-only"
            shift
            ;;
        --green-only)
            MODE="green-only"
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -f|-y|--force)
            FORCE=true
            shift
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
            echo "Error: Unknown option '$1'. Use --help for usage." >&2
            exit 1
            ;;
    esac
done

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: 'kubectl' command not found in PATH." >&2
    exit 1
fi

echo "============================================================"
echo "==> [DeployX] Cluster Teardown Controller"
echo "    Namespace:  $NAMESPACE"
echo "    Mode:       $MODE"
echo "    Dry Run:    $DRY_RUN"
echo "============================================================"
log_msg "INFO" "Cleanup initiated: mode=$MODE namespace=$NAMESPACE dry_run=$DRY_RUN"

# ------------------------------------------------------------------------------
# 3. Preview Resources Based on Mode
# ------------------------------------------------------------------------------
echo "==> [Inventory] Targeted resources for removal ($MODE):"

case "$MODE" in
    all)
        echo "  - Complete Namespace: $NAMESPACE"
        echo "  - Deployments:        deployx-backend, deployx-backend-green, deployx-frontend, deployx-prometheus, deployx-grafana"
        echo "  - Services:           deployx-backend, backend, deployx-frontend, prometheus, grafana"
        echo "  - ConfigMaps/Secrets: all associated with deployx"
        ;;
    monitoring-only)
        echo "  - Deployments:        deployx-prometheus, deployx-grafana"
        echo "  - Services:           prometheus, grafana"
        echo "  - ConfigMaps:         deployx-prometheus-config, deployx-grafana-datasources, deployx-grafana-dashboards, deployx-grafana-dashboard-provider"
        echo "  - Secrets:            deployx-grafana-secret"
        ;;
    green-only)
        echo "  - Deployment:         deployx-backend-green"
        ;;
esac

if [[ "$DRY_RUN" == "true" ]]; then
    echo "============================================================"
    echo "[SUCCESS] Dry-run completed. No resources were deleted."
    echo "============================================================"
    log_msg "INFO" "Cleanup dry-run completed successfully"
    exit 0
fi

# ------------------------------------------------------------------------------
# 4. Interactive Safety Confirmation
# ------------------------------------------------------------------------------
if [[ "$FORCE" == "false" ]]; then
    read -r -p "WARNING: Are you sure you want to proceed with teardown ($MODE)? [y/N]: " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" && "$CONFIRM" != "yes" ]]; then
        echo "Cleanup cancelled by user."
        log_msg "INFO" "Cleanup cancelled by user"
        exit 0
    fi
fi

# ------------------------------------------------------------------------------
# 5. Execute Resource Removal
# ------------------------------------------------------------------------------
echo "==> [Teardown] Executing resource deletion..."

case "$MODE" in
    all)
        if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
            echo "    Deleting namespace '$NAMESPACE' and all enclosed resources..."
            kubectl delete namespace "$NAMESPACE" --wait=true 2>/dev/null || true
            echo "    Namespace '$NAMESPACE' deleted."
        else
            echo "    Namespace '$NAMESPACE' does not exist."
        fi
        ;;
    monitoring-only)
        echo "    Deleting monitoring deployments and services..."
        kubectl delete deployment deployx-prometheus deployx-grafana -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
        kubectl delete service prometheus deployx-prometheus grafana deployx-grafana -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
        kubectl delete configmap deployx-prometheus-config deployx-grafana-datasources deployx-grafana-dashboards deployx-grafana-dashboard-provider -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
        kubectl delete secret deployx-grafana-secret -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
        echo "    Monitoring stack removed."
        ;;
    green-only)
        # Protect against deleting green if it is currently active!
        ACTIVE_COLOR="$(kubectl get service backend -n "$NAMESPACE" -o jsonpath='{.spec.selector.deployment-color}' 2>/dev/null || echo "unknown")"
        if [[ "$ACTIVE_COLOR" == "green" ]]; then
            echo "Error: Cannot delete Green deployment because it is currently actively receiving traffic!" >&2
            echo "Roll back active traffic to Blue first using ./rollback.sh blue." >&2
            log_msg "ERROR" "Cleanup green-only aborted: Green deployment is currently actively routed"
            exit 1
        fi
        echo "    Deleting inactive deployment 'deployx-backend-green'..."
        kubectl delete deployment deployx-backend-green -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
        echo "    Deployment 'deployx-backend-green' removed."
        ;;
esac

echo "============================================================"
echo "[SUCCESS] Cleanup completed successfully for mode: $MODE"
echo "============================================================"
log_msg "INFO" "Cleanup completed successfully: mode=$MODE namespace=$NAMESPACE"
exit 0
