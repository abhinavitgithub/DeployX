#!/usr/bin/env bash
# DeployX — Production Kubernetes Deployment Controller
# Automates manifest validation, multi-tier deployment, rollout synchronization,
# and post-deployment health verification for DeployX on Kubernetes.
#
# Usage:
#   ./deploy.sh [OPTIONS]
#
# Options:
#   -m, --include-monitoring  Deploy Prometheus and Grafana monitoring stack (Phase 6)
#   -d, --dry-run             Validate manifests with client-side dry-run without applying
#   -c, --color <color>       Initial active routing color (blue|green, default: blue)
#   -t, --timeout <seconds>   Rollout wait timeout per deployment in seconds (default: 60)
#   -n, --namespace <ns>      Target Kubernetes namespace (default: deployx)
#   --skip-health-check       Skip post-deployment synthetic health verification
#   -h, --help                Display this help message and exit
#
# Configurable Environment Variables:
#   DEPLOYX_NAMESPACE           Target Kubernetes namespace (default: deployx)
#   DEPLOYX_TIMEOUT             Rollout timeout in seconds (default: 60)
#   DEPLOYX_LOG_FILE            Path to operations audit log (default: data/deployx_operations.log)
#   DEPLOYX_INCLUDE_MONITORING  Set to 'true' to include monitoring stack

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Defaults & Configuration
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
K8S_DIR="$ROOT_DIR/infrastructure/kubernetes"
MONITORING_DIR="$ROOT_DIR/infrastructure/monitoring"

NAMESPACE="${DEPLOYX_NAMESPACE:-deployx}"
TIMEOUT="${DEPLOYX_TIMEOUT:-60}"
LOG_FILE="${DEPLOYX_LOG_FILE:-$ROOT_DIR/data/deployx_operations.log}"
INCLUDE_MONITORING="${DEPLOYX_INCLUDE_MONITORING:-false}"
INITIAL_COLOR="blue"
DRY_RUN=false
SKIP_HEALTH_CHECK=false

# ------------------------------------------------------------------------------
# 2. Logging & Output Helpers
# ------------------------------------------------------------------------------
log_msg() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $msg"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "[$timestamp] [$level] [deploy] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

show_help() {
    cat <<EOF
DeployX — Kubernetes Deployment Controller

Usage:
  $0 [OPTIONS]

Options:
  -m, --include-monitoring  Deploy Prometheus and Grafana monitoring stack
  -d, --dry-run             Validate manifests client-side without applying
  -c, --color <color>       Active routing color: blue or green (default: blue)
  -t, --timeout <seconds>   Rollout wait timeout in seconds (default: 60)
  -n, --namespace <ns>      Target Kubernetes namespace (default: deployx)
  --skip-health-check       Skip post-deployment synthetic health check
  -h, --help                Display this help message and exit

Environment Variables:
  DEPLOYX_NAMESPACE           Default namespace (default: deployx)
  DEPLOYX_TIMEOUT             Default rollout timeout (default: 60)
  DEPLOYX_LOG_FILE            Audit log file path
  DEPLOYX_INCLUDE_MONITORING  Set to 'true' to deploy monitoring

Examples:
  $0                                # Standard Blue-Green deployment
  $0 --include-monitoring           # Deploy core app + Prometheus & Grafana
  $0 --dry-run                      # Validate all manifests without applying
  $0 --color green                  # Deploy with Green actively routed
EOF
}

# ------------------------------------------------------------------------------
# 3. Argument Parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--include-monitoring)
            INCLUDE_MONITORING=true
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -c|--color)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --color requires an argument ('blue' or 'green')." >&2
                exit 1
            fi
            INITIAL_COLOR="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
            if [[ "$INITIAL_COLOR" != "blue" && "$INITIAL_COLOR" != "green" ]]; then
                echo "Error: Invalid color '$2'. Must be 'blue' or 'green'." >&2
                exit 1
            fi
            shift 2
            ;;
        -t|--timeout)
            if [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --timeout requires a positive integer." >&2
                exit 1
            fi
            TIMEOUT="$2"
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
        --skip-health-check)
            SKIP_HEALTH_CHECK=true
            shift
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

echo "============================================================"
echo "==> [DeployX] Executing Deployment Pipeline"
echo "    Namespace:          $NAMESPACE"
echo "    Active Color:       $INITIAL_COLOR"
echo "    Include Monitoring: $INCLUDE_MONITORING"
echo "    Dry Run Mode:       $DRY_RUN"
echo "    Rollout Timeout:    ${TIMEOUT}s"
echo "============================================================"
log_msg "INFO" "Starting deployment pipeline: namespace=$NAMESPACE active_color=$INITIAL_COLOR monitoring=$INCLUDE_MONITORING dry_run=$DRY_RUN"

# ------------------------------------------------------------------------------
# 4. Pre-Flight Dependency & Connectivity Checks
# ------------------------------------------------------------------------------
echo "==> [Pre-flight] Checking CLI tool availability..."
if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: 'kubectl' command not found in PATH. Please install kubectl." >&2
    log_msg "ERROR" "Pre-flight failed: kubectl not found in PATH"
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "Warning: 'docker' CLI not found in PATH. Continuing with kubectl only."
    log_msg "WARN" "Pre-flight: docker CLI not found in PATH"
fi

if [[ "$DRY_RUN" == "false" ]]; then
    echo "==> [Pre-flight] Verifying Kubernetes cluster connectivity..."
    if ! kubectl cluster-info >/dev/null 2>&1; then
        echo "Error: Cannot connect to Kubernetes cluster. Ensure cluster is running and KUBECONFIG is valid." >&2
        log_msg "ERROR" "Pre-flight failed: Cannot connect to Kubernetes cluster"
        exit 1
    fi
    echo "    Cluster is connected and responsive."
else
    echo "==> [Pre-flight] Skipping live cluster connectivity check (dry-run mode active)..."
fi

# ------------------------------------------------------------------------------
# 5. Manifest Validation (Dry-Run)
# ------------------------------------------------------------------------------
MANIFEST_FILES=(
    "$K8S_DIR/namespace.yaml"
    "$K8S_DIR/backend.yaml"
    "$K8S_DIR/backend-green.yaml"
    "$K8S_DIR/backend-alias.yaml"
    "$K8S_DIR/frontend.yaml"
)

if [[ "$INCLUDE_MONITORING" == "true" ]]; then
    MANIFEST_FILES+=("$MONITORING_DIR/prometheus.yaml" "$MONITORING_DIR/grafana.yaml")
fi

echo "==> [Validation] Validating manifests (client-side dry-run)..."
for manifest in "${MANIFEST_FILES[@]}"; do
    if [[ ! -f "$manifest" ]]; then
        echo "Error: Required manifest file not found: $manifest" >&2
        log_msg "ERROR" "Manifest missing: $manifest"
        exit 1
    fi
    if ! kubectl apply --dry-run=client -f "$manifest" >/dev/null 2>&1; then
        echo "Error: Manifest validation failed for: $manifest" >&2
        log_msg "ERROR" "Validation failed: $manifest"
        exit 1
    fi
    echo "    [VALID] $(basename "$manifest")"
done

if [[ "$DRY_RUN" == "true" ]]; then
    echo "============================================================"
    echo "[SUCCESS] Dry-run completed. All manifests validated successfully."
    echo "============================================================"
    log_msg "INFO" "Dry-run validation successful. No changes made."
    exit 0
fi

# ------------------------------------------------------------------------------
# 6. Apply Kubernetes Manifests
# ------------------------------------------------------------------------------
echo "==> [Deploy] Applying namespace manifest..."
kubectl apply -f "$K8S_DIR/namespace.yaml"

echo "==> [Deploy] Applying backend Blue and Green deployments..."
kubectl apply -f "$K8S_DIR/backend.yaml"
kubectl apply -f "$K8S_DIR/backend-green.yaml"

echo "==> [Deploy] Configuring backend routing service to '$INITIAL_COLOR'..."
kubectl apply -f "$K8S_DIR/backend-alias.yaml"
if [[ "$INITIAL_COLOR" == "green" ]]; then
    PATCH_PAYLOAD="{\"spec\":{\"selector\":{\"app\":\"deployx-backend\",\"deployment-color\":\"green\"}}}"
    kubectl patch service backend -n "$NAMESPACE" --type=merge -p "$PATCH_PAYLOAD"
fi

echo "==> [Deploy] Applying frontend deployment & service..."
kubectl apply -f "$K8S_DIR/frontend.yaml"

if [[ "$INCLUDE_MONITORING" == "true" ]]; then
    echo "==> [Deploy] Applying Phase 6 Prometheus & Grafana monitoring stack..."
    kubectl apply -f "$MONITORING_DIR/prometheus.yaml"
    kubectl apply -f "$MONITORING_DIR/grafana.yaml"
fi

# ------------------------------------------------------------------------------
# 7. Wait for Rollout Completion
# ------------------------------------------------------------------------------
echo "==> [Rollout] Synchronizing deployment rollouts (timeout: ${TIMEOUT}s)..."

DEPLOYMENTS=("deployx-backend" "deployx-backend-green" "deployx-frontend")
if [[ "$INCLUDE_MONITORING" == "true" ]]; then
    DEPLOYMENTS+=("deployx-prometheus" "deployx-grafana")
fi

for dep in "${DEPLOYMENTS[@]}"; do
    echo "    Waiting for rollout of '$dep'..."
    if ! kubectl rollout status deployment/"$dep" -n "$NAMESPACE" --timeout="${TIMEOUT}s"; then
        echo "Error: Rollout failed or timed out for deployment '$dep'." >&2
        log_msg "ERROR" "Deployment rollout failed for '$dep' in namespace '$NAMESPACE'"
        exit 1
    fi
    READY_REPLICAS="$(kubectl get deployment "$dep" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
    if [[ -z "$READY_REPLICAS" || "$READY_REPLICAS" -lt 1 ]]; then
        echo "Error: Deployment '$dep' has zero ready replicas." >&2
        log_msg "ERROR" "Deployment '$dep' ready replicas check failed"
        exit 1
    fi
done

log_msg "INFO" "All deployments rolled out successfully: ${DEPLOYMENTS[*]}"

# ------------------------------------------------------------------------------
# 8. Post-Deployment Health Verification
# ------------------------------------------------------------------------------
if [[ "$SKIP_HEALTH_CHECK" == "false" ]]; then
    echo "==> [Verification] Running post-deployment health verification..."
    HEALTH_SCRIPT="$SCRIPT_DIR/health_check.sh"
    if [[ -f "$HEALTH_SCRIPT" ]]; then
        HEALTH_FLAGS=()
        if [[ "$INCLUDE_MONITORING" == "true" ]]; then
            HEALTH_FLAGS+=("--include-monitoring")
        fi
        if ! bash "$HEALTH_SCRIPT" "${HEALTH_FLAGS[@]}"; then
            echo "Error: Post-deployment health verification reported failures." >&2
            log_msg "ERROR" "Post-deployment health check reported failure"
            exit 1
        fi
    else
        echo "    Health check script not found at $HEALTH_SCRIPT. Verifying basic endpoints..."
        BACKEND_EP="$(kubectl get endpoints backend -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")"
        FRONTEND_EP="$(kubectl get endpoints deployx-frontend -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")"
        echo "    Active Backend Endpoints:  ${BACKEND_EP:-none}"
        echo "    Active Frontend Endpoints: ${FRONTEND_EP:-none}"
        if [[ -z "$BACKEND_EP" || -z "$FRONTEND_EP" ]]; then
            echo "Error: Missing ready endpoints for core application services." >&2
            exit 1
        fi
    fi
else
    echo "==> [Verification] Health check skipped as requested (--skip-health-check)."
fi

# ------------------------------------------------------------------------------
# 9. Summary & Success Output
# ------------------------------------------------------------------------------
echo "============================================================"
echo "[SUCCESS] DeployX successfully deployed and verified!"
echo "Namespace:        $NAMESPACE"
echo "Active Color:     $INITIAL_COLOR"
echo "Deployments:      ${DEPLOYMENTS[*]}"
echo "Frontend Service: NodePort 30080"
if [[ "$INCLUDE_MONITORING" == "true" ]]; then
    echo "Prometheus:       ClusterIP Port 9090 (service: prometheus)"
    echo "Grafana:          ClusterIP Port 3000 (service: grafana)"
fi
echo "Log File:         $LOG_FILE"
echo "============================================================"
log_msg "INFO" "Deployment pipeline completed successfully for namespace '$NAMESPACE'"
exit 0
