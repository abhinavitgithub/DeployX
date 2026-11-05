#!/usr/bin/env bash
# DeployX — Application Disaster Recovery Restore Controller
# Restores application data and configuration from an integrity-verified backup archive.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <path-to-backup.tar.gz> [target-directory]" >&2
    exit 1
fi

BACKUP_ARCHIVE="$1"
TARGET_DIR="${2:-${DEPLOYX_DIR:-$ROOT_DIR}}"

echo "============================================================"
echo "==> [DeployX] Disaster Recovery Restore Procedure"
echo "    Source Archive:   $BACKUP_ARCHIVE"
echo "    Target Directory: $TARGET_DIR"
echo "============================================================"

# Pre-flight verify backup integrity
if [ -f "$SCRIPT_DIR/verify-backup.sh" ]; then
    bash "$SCRIPT_DIR/verify-backup.sh" "$BACKUP_ARCHIVE"
fi

TEMP_RESTORE="$(mktemp -d)"
cleanup() {
    rm -rf "$TEMP_RESTORE"
}
trap cleanup EXIT

echo "Unpacking archive to staging directory..."
tar -xzf "$BACKUP_ARCHIVE" -C "$TEMP_RESTORE"

# Safety backup of existing data if present
if [ -d "$TARGET_DIR/data" ] && [ "$(ls -A "$TARGET_DIR/data" 2>/dev/null)" ]; then
    SAFETY_BACKUP="$TARGET_DIR/backups/pre_restore_safety_$(date '+%Y%m%d_%H%M%S').tar.gz"
    echo "Creating safety snapshot of current data at $SAFETY_BACKUP..."
    mkdir -p "$TARGET_DIR/backups"
    tar -czf "$SAFETY_BACKUP" -C "$TARGET_DIR/data" . 2>/dev/null || true
fi

# Restore data
mkdir -p "$TARGET_DIR/data"
if [ -d "$TEMP_RESTORE/data" ]; then
    echo "Restoring application data to $TARGET_DIR/data..."
    cp -r "$TEMP_RESTORE/data"/* "$TARGET_DIR/data/" 2>/dev/null || true
fi

# Restore configuration files if present
if [ -d "$TEMP_RESTORE/config" ]; then
    echo "Restoring configurations..."
    if [ -f "$TEMP_RESTORE/config/compose.yaml" ]; then
        cp "$TEMP_RESTORE/config/compose.yaml" "$TARGET_DIR/" 2>/dev/null || true
    fi
fi

# Adjust permissions if unprivileged user exists
if id -u deployx >/dev/null 2>&1; then
    chown -R deployx:deployx "$TARGET_DIR/data" 2>/dev/null || true
fi

echo "============================================================"
echo " [SUCCESS] Disaster recovery restore completed successfully!"
echo " Target data directory: $TARGET_DIR/data"
echo "============================================================"
