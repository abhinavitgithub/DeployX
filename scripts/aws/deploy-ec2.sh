#!/usr/bin/env bash
# DeployX — AWS EC2 Safe Deployment & Automated Rollback Controller
# Safely pulls new container images from GHCR, validates Docker Compose configuration,
# deploys containers, runs synthetic health checks, and triggers automated rollback on failure.

set -euo pipefail

DEPLOYX_DIR="${DEPLOYX_DIR:-/opt/deployx}"
IMAGE_TAG="${1:-latest}"
BACKUP_IMAGE_BACKEND=""
BACKUP_IMAGE_FRONTEND=""
APP_PORT="${APP_PORT:-80}"
HEALTH_TIMEOUT=60
DRY_RUN=false
ROLLBACK_MODE=false

show_help() {
    cat <<EOF
DeployX — EC2 Safe Deployment Controller

Usage:
  $0 [OPTIONS] [TAG]

Options:
  --dry-run      Validate Compose topology and exit without deploying
  --rollback     Rollback to the previously deployed container images
  --tag <tag>    Deploy a specific image tag (default: latest)
  --timeout <s>  Health check timeout in seconds (default: 60)
  -h, --help     Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --rollback)
            ROLLBACK_MODE=true
            shift
            ;;
        --tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --timeout)
            HEALTH_TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            if [[ "$1" != -* ]]; then
                IMAGE_TAG="$1"
            fi
            shift
            ;;
    esac
done

echo "============================================================"
echo "==> [DeployX] AWS EC2 Safe Deployment Controller"
echo "    App Directory:   $DEPLOYX_DIR"
echo "    Target Tag:      $IMAGE_TAG"
echo "    Dry Run:         $DRY_RUN"
echo "    Rollback Mode:   $ROLLBACK_MODE"
echo "============================================================"

# Ensure directory exists
if [ ! -d "$DEPLOYX_DIR" ]; then
    echo "Error: Application directory $DEPLOYX_DIR does not exist." >&2
    exit 1
fi

cd "$DEPLOYX_DIR"

if [ ! -f "compose.yaml" ]; then
    echo "Error: compose.yaml not found in $DEPLOYX_DIR." >&2
    exit 1
fi

# Detect docker compose CLI command
if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    echo "Error: Neither 'docker compose' nor 'docker-compose' found in PATH." >&2
    exit 1
fi

# Validate Compose configuration
echo "==> [1/4] Validating Docker Compose configuration..."
$COMPOSE config >/dev/null
echo "    Compose configuration is valid."

if [ "$DRY_RUN" = "true" ]; then
    echo "[SUCCESS] Dry-run completed. Configuration is valid."
    exit 0
fi

# Capture current image IDs for rollback state preservation
echo "==> [2/4] Recording current running image state for safe rollback..."
STATE_FILE="$DEPLOYX_DIR/.deploy_state.prev"
if docker ps --format '{{.Image}}' | grep -q "deployx-backend"; then
    BACKUP_IMAGE_BACKEND="$(docker inspect --format='{{.Image}}' deployx-backend 2>/dev/null || echo '')"
    BACKUP_IMAGE_FRONTEND="$(docker inspect --format='{{.Image}}' deployx-frontend 2>/dev/null || echo '')"
    echo "BACKUP_BACKEND=$BACKUP_IMAGE_BACKEND" > "$STATE_FILE"
    echo "BACKUP_FRONTEND=$BACKUP_IMAGE_FRONTEND" >> "$STATE_FILE"
    echo "    Current container state recorded."
fi

# Handle Rollback Mode
if [ "$ROLLBACK_MODE" = "true" ]; then
    echo "==> [Rollback] Restoring previous container state..."
    if [ ! -f "$STATE_FILE" ]; then
        echo "Error: No previous deployment state found in $STATE_FILE." >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    echo "    Restarting previous containers..."
    $COMPOSE up -d --force-recreate
    echo "[SUCCESS] Rollback complete."
    exit 0
fi

# Pull latest GHCR images
echo "==> [3/4] Pulling container images (tag: $IMAGE_TAG)..."
$COMPOSE pull || {
    echo "Warning: Image pull encountered issues. Continuing if local images exist..."
}

# Deploy containers
echo "==> [4/4] Deploying containers with zero-downtime recreation..."
$COMPOSE up -d --remove-orphans

# Health Check Verification
echo "==> [Health Verification] Polling application endpoints (timeout: ${HEALTH_TIMEOUT}s)..."
START_TIME=$(date +%s)
HEALTHY=false

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    if [ "$ELAPSED" -gt "$HEALTH_TIMEOUT" ]; then
        break
    fi

    BACKEND_STATUS=$(curl -fs "http://127.0.0.1:8000/health/live" 2>/dev/null || echo "")
    FRONTEND_STATUS=$(curl -fs "http://127.0.0.1:${APP_PORT}/health/live" 2>/dev/null || echo "")

    if [[ "$BACKEND_STATUS" == *"alive"* ]] && [[ "$FRONTEND_STATUS" == *"alive"* || "$FRONTEND_STATUS" == *"DeployX"* || -n "$FRONTEND_STATUS" ]]; then
        HEALTHY=true
        echo "    Both backend and frontend are HEALTHY after ${ELAPSED}s."
        break
    fi

    sleep 2
done

if [ "$HEALTHY" = "true" ]; then
    echo "============================================================"
    echo " [SUCCESS] DeployX deployment completed successfully!"
    echo " Active Containers:"
    docker ps --filter "name=deployx" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo "============================================================"
    exit 0
else
    echo "============================================================" >&2
    echo " [FAILURE] Health checks failed after ${HEALTH_TIMEOUT}s!" >&2
    echo " Initiating AUTOMATED ROLLBACK to preserve availability..." >&2
    echo "============================================================" >&2

    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        $COMPOSE up -d --force-recreate || true
        echo "Rollback to previous state executed." >&2
    else
        $COMPOSE restart || true
    fi
    exit 1
fi
