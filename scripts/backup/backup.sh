#!/usr/bin/env bash
# DeployX — Application & Infrastructure Disaster Recovery Backup Controller
# Creates timestamped, SHA-256 verified backups of application data, configuration,
# and runtime state, with automated local retention pruning and optional S3 replication.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

BACKUP_DIR="${DEPLOYX_BACKUP_DIR:-$ROOT_DIR/backups}"
DATA_DIR="${DEPLOYX_DATA_DIR:-$ROOT_DIR/data}"
RETENTION_COUNT="${DEPLOYX_BACKUP_RETENTION:-5}"
S3_BUCKET="${S3_BACKUP_BUCKET:-${DEPLOYX_S3_BACKUP_BUCKET:-}}"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_NAME="deployx-backup-${TIMESTAMP}"
ARCHIVE_PATH="$BACKUP_DIR/${BACKUP_NAME}.tar.gz"
CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"
LOG_FILE="${DEPLOYX_LOG_FILE:-$ROOT_DIR/data/deployx_operations.log}"

show_help() {
    cat <<EOF
DeployX — Disaster Recovery Backup Controller

Usage:
  $0 [OPTIONS]

Options:
  -d, --dir <path>          Output directory for backups (default: backups)
  -s, --s3-bucket <bucket>  AWS S3 bucket name for disaster recovery replication
  -r, --retention <count>   Number of local backups to retain (default: 5)
  -h, --help                Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        -s|--s3-bucket)
            S3_BUCKET="$2"
            shift 2
            ;;
        -r|--retention)
            RETENTION_COUNT="$2"
            shift 2
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
echo "==> [DeployX] Executing Disaster Recovery Backup"
echo "    Timestamp: $TIMESTAMP"
echo "    Archive:   $ARCHIVE_PATH"
echo "    Retention: $RETENTION_COUNT"
echo "============================================================"

mkdir -p "$BACKUP_DIR"
TEMP_STAGING="$(mktemp -d)"

cleanup() {
    rm -rf "$TEMP_STAGING"
}
trap cleanup EXIT

# 1. Collect application data and configuration
mkdir -p "$TEMP_STAGING/data" "$TEMP_STAGING/config"
if [ -d "$DATA_DIR" ]; then
    cp -r "$DATA_DIR"/* "$TEMP_STAGING/data/" 2>/dev/null || true
fi

# 2. Collect Kubernetes and Compose manifests if present
if [ -d "$ROOT_DIR/infrastructure" ]; then
    cp -r "$ROOT_DIR/infrastructure" "$TEMP_STAGING/config/" 2>/dev/null || true
fi
if [ -f "$ROOT_DIR/compose.yaml" ]; then
    cp "$ROOT_DIR/compose.yaml" "$TEMP_STAGING/config/" 2>/dev/null || true
fi

# 3. Write metadata manifest
cat << META_EOF > "$TEMP_STAGING/metadata.json"
{
  "timestamp": "$(date -u '+%Y-%m-%d %H:%M:%SZ')",
  "version": "1.0.0",
  "backup_name": "$BACKUP_NAME",
  "hostname": "$(hostname)",
  "included_components": ["application_data", "infrastructure_configs"]
}
META_EOF

# 4. Create compressed archive
echo "Creating compressed archive..."
tar -czf "$ARCHIVE_PATH" -C "$TEMP_STAGING" .

# 5. Compute SHA256 checksum
echo "Generating SHA-256 checksum..."
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$ARCHIVE_PATH" | awk '{print $1}' > "$CHECKSUM_PATH"
elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}' > "$CHECKSUM_PATH"
fi

echo "Archive size: $(ls -lh "$ARCHIVE_PATH" | awk '{print $5}')"
echo "Checksum:     $(cat "$CHECKSUM_PATH" 2>/dev/null || echo "N/A")"

# 6. S3 Replication if bucket configured
if [ -n "$S3_BUCKET" ]; then
    echo "Replicating backup to AWS S3: s3://$S3_BUCKET/backups/..."
    if command -v aws >/dev/null 2>&1; then
        aws s3 cp "$ARCHIVE_PATH" "s3://$S3_BUCKET/backups/${BACKUP_NAME}.tar.gz" --only-show-errors || {
            echo "Warning: S3 upload failed. Local backup remains secure." >&2
        }
        if [ -f "$CHECKSUM_PATH" ]; then
            aws s3 cp "$CHECKSUM_PATH" "s3://$S3_BUCKET/backups/${BACKUP_NAME}.tar.gz.sha256" --only-show-errors || true
        fi
        echo "S3 replication completed."
    else
        echo "Warning: 'aws' CLI not available in PATH. Skipping S3 upload."
    fi
fi

# 7. Apply local retention pruning
echo "Applying local backup retention policy (keeping $RETENTION_COUNT)..."
# shellcheck disable=SC2012
EXISTING_BACKUPS=$(ls -t "$BACKUP_DIR"/deployx-backup-*.tar.gz 2>/dev/null || true)
TOTAL_BACKUPS=$(echo "$EXISTING_BACKUPS" | grep -c "deployx-backup-" || true)

if [ "$TOTAL_BACKUPS" -gt "$RETENTION_COUNT" ]; then
    EXCESS=$((TOTAL_BACKUPS - RETENTION_COUNT))
    echo "Pruning $EXCESS older backup(s)..."
    # shellcheck disable=SC2012
    ls -t "$BACKUP_DIR"/deployx-backup-*.tar.gz | tail -n "$EXCESS" | while read -r old_backup; do
        echo "  Deleting: $old_backup"
        rm -f "$old_backup" "${old_backup}.sha256"
    done
fi

echo "============================================================"
echo " [SUCCESS] Backup created successfully: $ARCHIVE_PATH"
echo "============================================================"
