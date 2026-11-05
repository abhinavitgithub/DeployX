#!/usr/bin/env bash
# DeployX — Cluster State & Configuration Backup Controller
# Exports and archives Kubernetes manifests, active routing state, monitoring configurations,
# and runtime metadata with configurable backup retention.
#
# Usage:
#   ./backup.sh [OPTIONS]
#
# Options:
#   -d, --dir <path>          Output directory for backups (default: backups)
#   -r, --retention <count>   Maximum number of backups to retain (default: 5)
#   -n, --namespace <ns>      Target Kubernetes namespace (default: deployx)
#   -s, --s3-bucket <bucket>  Optional AWS S3 bucket for disaster recovery replication
#   -h, --help                Display this help message and exit

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Defaults & Configuration
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

NAMESPACE="${DEPLOYX_NAMESPACE:-deployx}"
BACKUP_ROOT="${DEPLOYX_BACKUP_DIR:-$ROOT_DIR/backups}"
RETENTION_COUNT="${DEPLOYX_BACKUP_RETENTION:-5}"
S3_BUCKET="${DEPLOYX_S3_BACKUP_BUCKET:-}"
LOG_FILE="${DEPLOYX_LOG_FILE:-$ROOT_DIR/data/deployx_operations.log}"

log_msg() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "[$timestamp] [$level] [backup] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

show_help() {
    cat <<EOF
DeployX — Cluster State & Configuration Backup Controller

Usage:
  $0 [OPTIONS]

Options:
  -d, --dir <path>          Output directory for backups (default: backups)
  -r, --retention <count>   Number of backups to keep (default: 5)
  -n, --namespace <ns>      Kubernetes namespace (default: deployx)
  -h, --help                Display this help message and exit

Environment Variables:
  DEPLOYX_BACKUP_DIR        Default backup directory
  DEPLOYX_BACKUP_RETENTION  Default backup retention count
  DEPLOYX_NAMESPACE         Target namespace
  DEPLOYX_LOG_FILE          Audit log path
EOF
}

# ------------------------------------------------------------------------------
# 2. Argument Parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dir)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --dir requires an argument." >&2
                exit 1
            fi
            BACKUP_ROOT="$2"
            shift 2
            ;;
        -r|--retention)
            if [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --retention requires a positive integer." >&2
                exit 1
            fi
            RETENTION_COUNT="$2"
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
        -s|--s3-bucket)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --s3-bucket requires an argument." >&2
                exit 1
            fi
            S3_BUCKET="$2"
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
    log_msg "ERROR" "Backup failed: kubectl not found in PATH"
    exit 1
fi

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_NAME="deployx_backup_$TIMESTAMP"
BACKUP_DIR="$BACKUP_ROOT/$BACKUP_NAME"

echo "============================================================"
echo "==> [DeployX] Executing Cluster State Backup"
echo "    Namespace:       $NAMESPACE"
echo "    Backup Target:   $BACKUP_DIR"
echo "    Retention Limit: $RETENTION_COUNT archives"
echo "============================================================"
log_msg "INFO" "Starting backup: name=$BACKUP_NAME namespace=$NAMESPACE"

mkdir -p "$BACKUP_DIR/kubernetes"
mkdir -p "$BACKUP_DIR/metadata"

# ------------------------------------------------------------------------------
# 3. Capture Active Routing & Git Metadata
# ------------------------------------------------------------------------------
ACTIVE_COLOR="$(kubectl get service backend -n "$NAMESPACE" -o jsonpath='{.spec.selector.deployment-color}' 2>/dev/null || echo "unknown")"
GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo "not_in_git")"
GIT_BRANCH="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"

cat <<EOF > "$BACKUP_DIR/metadata/manifest.json"
{
  "backup_name": "$BACKUP_NAME",
  "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "namespace": "$NAMESPACE",
  "active_routing_color": "$ACTIVE_COLOR",
  "git_commit": "$GIT_COMMIT",
  "git_branch": "$GIT_BRANCH"
}
EOF

# ------------------------------------------------------------------------------
# 4. Export Kubernetes Resources
# ------------------------------------------------------------------------------
echo "==> [Export] Capturing Kubernetes cluster resources..."

# Namespace
kubectl get namespace "$NAMESPACE" -o yaml > "$BACKUP_DIR/kubernetes/namespace.yaml" 2>/dev/null || echo "# namespace not found" > "$BACKUP_DIR/kubernetes/namespace.yaml"

# Deployments
kubectl get deployments -n "$NAMESPACE" -o yaml > "$BACKUP_DIR/kubernetes/deployments.yaml" 2>/dev/null || true

# Services
kubectl get services -n "$NAMESPACE" -o yaml > "$BACKUP_DIR/kubernetes/services.yaml" 2>/dev/null || true

# ConfigMaps
kubectl get configmaps -n "$NAMESPACE" -o yaml > "$BACKUP_DIR/kubernetes/configmaps.yaml" 2>/dev/null || true

# Secrets (metadata & specs)
kubectl get secrets -n "$NAMESPACE" -o yaml > "$BACKUP_DIR/kubernetes/secrets.yaml" 2>/dev/null || true

# Pod Inventory
kubectl get pods -n "$NAMESPACE" -o wide > "$BACKUP_DIR/metadata/pods.txt" 2>/dev/null || true

# Copy local manifests for audit
if [[ -d "$ROOT_DIR/infrastructure/kubernetes" ]]; then
    mkdir -p "$BACKUP_DIR/local_manifests"
    cp -r "$ROOT_DIR/infrastructure/kubernetes/"* "$BACKUP_DIR/local_manifests/" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 5. Compress Archive
# ------------------------------------------------------------------------------
echo "==> [Archive] Compressing backup into tar.gz..."
ARCHIVE_PATH="$BACKUP_ROOT/$BACKUP_NAME.tar.gz"

if command -v tar >/dev/null 2>&1; then
    tar -czf "$ARCHIVE_PATH" -C "$BACKUP_ROOT" "$BACKUP_NAME"
    rm -rf "$BACKUP_DIR"
    BACKUP_FILE="$ARCHIVE_PATH"
else
    # Fallback to uncompressed directory if tar not present
    BACKUP_FILE="$BACKUP_DIR"
fi

echo "    Backup created: $BACKUP_FILE"

# ------------------------------------------------------------------------------
# 5.1 Optional AWS S3 Upload (Disaster Recovery Replication)
# ------------------------------------------------------------------------------
if [[ -n "$S3_BUCKET" ]]; then
    echo "==> [AWS S3] Replicating backup to S3 bucket '$S3_BUCKET'..."
    if command -v aws >/dev/null 2>&1; then
        aws s3 cp "$BACKUP_FILE" "s3://$S3_BUCKET/backups/$(basename "$BACKUP_FILE")" --sse AES256
        echo "    Replicated to: s3://$S3_BUCKET/backups/$(basename "$BACKUP_FILE")"
        log_msg "INFO" "Replicated backup to s3://$S3_BUCKET/backups/$(basename "$BACKUP_FILE")"
    else
        echo "    Warning: AWS CLI ('aws') not found in PATH; skipping S3 upload." >&2
        log_msg "WARN" "AWS CLI not found; skipped S3 replication to $S3_BUCKET"
    fi
fi

# ------------------------------------------------------------------------------
# 6. Enforce Backup Retention Limit
# ------------------------------------------------------------------------------
echo "==> [Retention] Enforcing retention limit ($RETENTION_COUNT)..."
if [[ -d "$BACKUP_ROOT" ]]; then
    # Find all backup archives or dirs sorted by modification time (oldest first)
    mapfile -t EXISTING_BACKUPS < <(find "$BACKUP_ROOT" -maxdepth 1 \( -name 'deployx_backup_*.tar.gz' -o -name 'deployx_backup_*' \) -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{print $2}')
    TOTAL_BACKUPS="${#EXISTING_BACKUPS[@]}"

    if [[ "$TOTAL_BACKUPS" -gt "$RETENTION_COUNT" ]]; then
        EXCESS=$((TOTAL_BACKUPS - RETENTION_COUNT))
        echo "    Pruning $EXCESS oldest backup(s)..."
        for ((i=0; i<EXCESS; i++)); do
            OLD_BACKUP="${EXISTING_BACKUPS[i]}"
            echo "    Pruned: $(basename "$OLD_BACKUP")"
            rm -rf "$OLD_BACKUP"
            log_msg "INFO" "Pruned old backup: $(basename "$OLD_BACKUP")"
        done
    else
        echo "    Total backups ($TOTAL_BACKUPS) within retention limit ($RETENTION_COUNT)."
    fi
fi

# ------------------------------------------------------------------------------
# 7. Summary & Success Output
# ------------------------------------------------------------------------------
echo "============================================================"
echo "[SUCCESS] Backup completed successfully!"
echo "Archive:          $BACKUP_FILE"
echo "Active Color:     $ACTIVE_COLOR"
echo "Git Commit:       $GIT_COMMIT"
echo "Retention Limit:  $RETENTION_COUNT"
echo "============================================================"
log_msg "INFO" "Backup created successfully: file=$BACKUP_FILE active_color=$ACTIVE_COLOR"
exit 0
