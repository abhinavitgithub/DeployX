#!/usr/bin/env bash
# DeployX — Health Verification & Synthetic Diagnostics Controller
# Inspects Kubernetes pods, services, endpoints, and executes synthetic HTTP probes
# across backend, frontend, and monitoring layers.
#
# Usage:
#   ./health_check.sh [OPTIONS]
#
# Options:
#   -m, --include-monitoring  Enforce Prometheus & Grafana health checks as required
#   -v, --verbose             Print detailed component specs and HTTP response bodies
#   -j, --json                Output health summary in JSON format
#   -t, --timeout <seconds>   Probe timeout in seconds (default: 10)
#   -n, --namespace <ns>      Target Kubernetes namespace (default: deployx)
#   -h, --help                Display this help message and exit

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Defaults & Configuration
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

NAMESPACE="${DEPLOYX_NAMESPACE:-deployx}"
PROBE_TIMEOUT="${DEPLOYX_PROBE_TIMEOUT:-10}"
LOG_FILE="${DEPLOYX_LOG_FILE:-$ROOT_DIR/data/deployx_operations.log}"
INCLUDE_MONITORING="${DEPLOYX_INCLUDE_MONITORING:-false}"
VERBOSE=false
JSON_OUTPUT=false

log_msg() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "[$timestamp] [$level] [health_check] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

show_help() {
    cat <<EOF
DeployX — Health Check & Diagnostics Controller

Usage:
  $0 [OPTIONS]

Options:
  -m, --include-monitoring  Check Prometheus & Grafana monitoring components
  -v, --verbose             Detailed diagnostic logs with IPs and response bodies
  -j, --json                Output status in machine-readable JSON format
  -t, --timeout <seconds>   Synthetic probe timeout in seconds (default: 10)
  -n, --namespace <ns>      Kubernetes namespace (default: deployx)
  -h, --help                Display this help message and exit

Exit Codes:
  0   All inspected components and synthetic probes are healthy
  1   One or more components or synthetic probes failed
EOF
}

# ------------------------------------------------------------------------------
# 2. Argument Parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--include-monitoring)
            INCLUDE_MONITORING=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -j|--json)
            JSON_OUTPUT=true
            shift
            ;;
        -t|--timeout)
            if [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --timeout requires a positive integer." >&2
                exit 1
            fi
            PROBE_TIMEOUT="$2"
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
            echo "Error: Unknown option '$1'. Use --help for usage." >&2
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# 3. Diagnostic Data Collection
# ------------------------------------------------------------------------------
OVERALL_HEALTH="HEALTHY"
FAILURES=()

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: 'kubectl' command not found in PATH." >&2
    exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    OVERALL_HEALTH="UNHEALTHY"
    FAILURES+=("Kubernetes cluster is not reachable")
fi

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    OVERALL_HEALTH="UNHEALTHY"
    FAILURES+=("Namespace '$NAMESPACE' does not exist")
fi

# Active color detection
ACTIVE_COLOR="$(kubectl get service backend -n "$NAMESPACE" -o jsonpath='{.spec.selector.deployment-color}' 2>/dev/null || echo "unknown")"

# Pod check helper
check_deployment() {
    local dep_name="$1"
    local is_required="$2"

    if ! kubectl get deployment "$dep_name" -n "$NAMESPACE" >/dev/null 2>&1; then
        if [[ "$is_required" == "true" ]]; then
            OVERALL_HEALTH="UNHEALTHY"
            FAILURES+=("Required deployment '$dep_name' is missing")
        fi
        return 1
    fi

    local ready
    ready="$(kubectl get deployment "$dep_name" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
    if [[ -z "$ready" || "$ready" -lt 1 ]]; then
        if [[ "$is_required" == "true" ]]; then
            OVERALL_HEALTH="UNHEALTHY"
            FAILURES+=("Deployment '$dep_name' has zero ready replicas")
        fi
        return 1
    fi
    return 0
}

# Service endpoint check helper
check_service_endpoints() {
    local svc_name="$1"
    local is_required="$2"

    local eps
    eps="$(kubectl get endpoints "$svc_name" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")"
    if [[ -z "$eps" ]]; then
        if [[ "$is_required" == "true" ]]; then
            OVERALL_HEALTH="UNHEALTHY"
            FAILURES+=("Service '$svc_name' has zero ready endpoints")
        fi
        return 1
    fi
    return 0
}

# Deployments check
DEP_BACKEND_STATUS="PASS"
DEP_GREEN_STATUS="PASS"
DEP_FRONTEND_STATUS="PASS"
DEP_PROM_STATUS="PASS"
DEP_GRAF_STATUS="PASS"

check_deployment "deployx-backend" "true" || DEP_BACKEND_STATUS="FAIL"
check_deployment "deployx-backend-green" "true" || DEP_GREEN_STATUS="FAIL"
check_deployment "deployx-frontend" "true" || DEP_FRONTEND_STATUS="FAIL"

if [[ "$INCLUDE_MONITORING" == "true" ]]; then
    check_deployment "deployx-prometheus" "true" || DEP_PROM_STATUS="FAIL"
    check_deployment "deployx-grafana" "true" || DEP_GRAF_STATUS="FAIL"
else
    check_deployment "deployx-prometheus" "false" || DEP_PROM_STATUS="NOT_DEPLOYED"
    check_deployment "deployx-grafana" "false" || DEP_GRAF_STATUS="NOT_DEPLOYED"
fi

# Services check
SVC_ROUTING_STATUS="PASS"
SVC_FRONTEND_STATUS="PASS"
SVC_PROM_STATUS="PASS"
SVC_GRAF_STATUS="PASS"

check_service_endpoints "backend" "true" || SVC_ROUTING_STATUS="FAIL"
check_service_endpoints "deployx-frontend" "true" || SVC_FRONTEND_STATUS="FAIL"

if [[ "$INCLUDE_MONITORING" == "true" ]]; then
    check_service_endpoints "prometheus" "true" || SVC_PROM_STATUS="FAIL"
    check_service_endpoints "grafana" "true" || SVC_GRAF_STATUS="FAIL"
fi

# ------------------------------------------------------------------------------
# 4. Synthetic HTTP Endpoint Probes
# ------------------------------------------------------------------------------
# We execute synthetic HTTP probes against the cluster services using kubectl exec in the frontend pod
# or via direct service proxy if available.
PROBE_LIVENESS="PASS"
PROBE_READINESS="PASS"
PROBE_STATUS="PASS"
PROBE_METRICS="PASS"
PROBE_FRONTEND="PASS"
PROBE_MON_PROM="PASS"
PROBE_MON_GRAF="PASS"

FRONTEND_POD="$(kubectl get pods -n "$NAMESPACE" -l app=deployx-frontend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")"

if [[ -n "$FRONTEND_POD" ]]; then
    # 1. Liveness probe
    if ! kubectl exec -n "$NAMESPACE" "$FRONTEND_POD" -- wget -qO- -T "$PROBE_TIMEOUT" http://backend:8000/health/live 2>/dev/null | grep -q '"status":"alive"'; then
        PROBE_LIVENESS="FAIL"
        OVERALL_HEALTH="UNHEALTHY"
        FAILURES+=("Synthetic probe failed: http://backend:8000/health/live")
    fi

    # 2. Readiness probe
    if ! kubectl exec -n "$NAMESPACE" "$FRONTEND_POD" -- wget -qO- -T "$PROBE_TIMEOUT" http://backend:8000/health/ready 2>/dev/null | grep -q '"status":"ready"'; then
        PROBE_READINESS="FAIL"
        OVERALL_HEALTH="UNHEALTHY"
        FAILURES+=("Synthetic probe failed: http://backend:8000/health/ready")
    fi

    # 3. Status probe
    if ! kubectl exec -n "$NAMESPACE" "$FRONTEND_POD" -- wget -qO- -T "$PROBE_TIMEOUT" http://backend:8000/api/v1/status 2>/dev/null | grep -q '"process_status":"running"'; then
        PROBE_STATUS="FAIL"
        OVERALL_HEALTH="UNHEALTHY"
        FAILURES+=("Synthetic probe failed: http://backend:8000/api/v1/status")
    fi

    # 4. Metrics probe
    if ! kubectl exec -n "$NAMESPACE" "$FRONTEND_POD" -- wget -qO- -T "$PROBE_TIMEOUT" http://backend:8000/metrics 2>/dev/null | grep -q 'deployx_'; then
        PROBE_METRICS="FAIL"
        OVERALL_HEALTH="UNHEALTHY"
        FAILURES+=("Synthetic probe failed: http://backend:8000/metrics")
    fi

    # 5. Frontend local serving
    if ! kubectl exec -n "$NAMESPACE" "$FRONTEND_POD" -- wget -qO- -T "$PROBE_TIMEOUT" http://127.0.0.1:80 2>/dev/null | grep -q 'DeployX'; then
        PROBE_FRONTEND="FAIL"
        OVERALL_HEALTH="UNHEALTHY"
        FAILURES+=("Synthetic probe failed: frontend HTML serving on port 80")
    fi

    # 6. Monitoring probes (if requested)
    if [[ "$INCLUDE_MONITORING" == "true" ]]; then
        if ! kubectl exec -n "$NAMESPACE" "$FRONTEND_POD" -- wget -qO- -T "$PROBE_TIMEOUT" http://prometheus:9090/-/healthy 2>/dev/null | grep -qi 'Prometheus Server is Healthy'; then
            PROBE_MON_PROM="FAIL"
            OVERALL_HEALTH="UNHEALTHY"
            FAILURES+=("Synthetic probe failed: http://prometheus:9090/-/healthy")
        fi

        if ! kubectl exec -n "$NAMESPACE" "$FRONTEND_POD" -- wget -qO- -T "$PROBE_TIMEOUT" http://grafana:3000/api/health 2>/dev/null | grep -qi '"database": "ok"'; then
            PROBE_MON_GRAF="FAIL"
            OVERALL_HEALTH="UNHEALTHY"
            FAILURES+=("Synthetic probe failed: http://grafana:3000/api/health")
        fi
    fi
else
    # If no frontend pod found, check if mock mode or real failure
    OVERALL_HEALTH="UNHEALTHY"
    FAILURES+=("No running frontend pod found to execute synthetic probes")
    PROBE_LIVENESS="FAIL"
    PROBE_READINESS="FAIL"
    PROBE_STATUS="FAIL"
    PROBE_METRICS="FAIL"
    PROBE_FRONTEND="FAIL"
fi

# ------------------------------------------------------------------------------
# 5. Output Formatting
# ------------------------------------------------------------------------------
if [[ "$JSON_OUTPUT" == "true" ]]; then
    cat <<EOF
{
  "status": "$OVERALL_HEALTH",
  "namespace": "$NAMESPACE",
  "active_routing_color": "$ACTIVE_COLOR",
  "deployments": {
    "deployx-backend": "$DEP_BACKEND_STATUS",
    "deployx-backend-green": "$DEP_GREEN_STATUS",
    "deployx-frontend": "$DEP_FRONTEND_STATUS",
    "deployx-prometheus": "$DEP_PROM_STATUS",
    "deployx-grafana": "$DEP_GRAF_STATUS"
  },
  "services": {
    "backend": "$SVC_ROUTING_STATUS",
    "deployx-frontend": "$SVC_FRONTEND_STATUS",
    "prometheus": "$SVC_PROM_STATUS",
    "grafana": "$SVC_GRAF_STATUS"
  },
  "probes": {
    "backend_liveness": "$PROBE_LIVENESS",
    "backend_readiness": "$PROBE_READINESS",
    "backend_status": "$PROBE_STATUS",
    "backend_metrics": "$PROBE_METRICS",
    "frontend_html": "$PROBE_FRONTEND",
    "prometheus_healthy": "$PROBE_MON_PROM",
    "grafana_healthy": "$PROBE_MON_GRAF"
  },
  "failure_count": ${#FAILURES[@]}
}
EOF
else
    echo "============================================================"
    echo "==> [DeployX] System Health & Synthetic Verification"
    echo "    Namespace:       $NAMESPACE"
    echo "    Active Routing:  $ACTIVE_COLOR"
    echo "    Overall Status:  $OVERALL_HEALTH"
    echo "============================================================"
    echo "Deployments:"
    printf "  %-24s [%s]\n" "deployx-backend (Blue)" "$DEP_BACKEND_STATUS"
    printf "  %-24s [%s]\n" "deployx-backend-green" "$DEP_GREEN_STATUS"
    printf "  %-24s [%s]\n" "deployx-frontend" "$DEP_FRONTEND_STATUS"
    if [[ "$INCLUDE_MONITORING" == "true" || "$DEP_PROM_STATUS" != "NOT_DEPLOYED" ]]; then
        printf "  %-24s [%s]\n" "deployx-prometheus" "$DEP_PROM_STATUS"
        printf "  %-24s [%s]\n" "deployx-grafana" "$DEP_GRAF_STATUS"
    fi

    echo ""
    echo "Routing & Service Endpoints:"
    printf "  %-24s [%s]\n" "backend (active: $ACTIVE_COLOR)" "$SVC_ROUTING_STATUS"
    printf "  %-24s [%s]\n" "deployx-frontend (30080)" "$SVC_FRONTEND_STATUS"
    if [[ "$INCLUDE_MONITORING" == "true" || "$SVC_PROM_STATUS" != "PASS" ]]; then
        printf "  %-24s [%s]\n" "prometheus (9090)" "$SVC_PROM_STATUS"
        printf "  %-24s [%s]\n" "grafana (3000)" "$SVC_GRAF_STATUS"
    fi

    echo ""
    echo "Synthetic Probes:"
    printf "  %-24s [%s]\n" "/health/live" "$PROBE_LIVENESS"
    printf "  %-24s [%s]\n" "/health/ready" "$PROBE_READINESS"
    printf "  %-24s [%s]\n" "/api/v1/status" "$PROBE_STATUS"
    printf "  %-24s [%s]\n" "/metrics" "$PROBE_METRICS"
    printf "  %-24s [%s]\n" "Frontend HTTP (port 80)" "$PROBE_FRONTEND"
    if [[ "$INCLUDE_MONITORING" == "true" ]]; then
        printf "  %-24s [%s]\n" "Prometheus (/-/healthy)" "$PROBE_MON_PROM"
        printf "  %-24s [%s]\n" "Grafana (/api/health)" "$PROBE_MON_GRAF"
    fi

    if [[ ${#FAILURES[@]} -gt 0 ]]; then
        echo ""
        echo "Identified Failures / Degraded States:"
        for f in "${FAILURES[@]}"; do
            echo "  - [FAIL] $f"
        done
    fi
    echo "============================================================"
fi

if [[ "$OVERALL_HEALTH" != "HEALTHY" ]]; then
    log_msg "WARN" "Health check identified ${#FAILURES[@]} issues: ${FAILURES[*]:-none}"
    exit 1
fi

log_msg "INFO" "Health check succeeded: all components healthy, active color is '$ACTIVE_COLOR'"
exit 0
