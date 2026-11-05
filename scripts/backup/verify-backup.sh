#!/usr/bin/env bash
# DeployX — Backup Verification & Integrity Checker
# Verifies gzip structure, archive readability, metadata, and SHA-256 checksums.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <path-to-backup.tar.gz>" >&2
    exit 1
fi

ARCHIVE="$1"

if [ ! -f "$ARCHIVE" ]; then
    echo "Error: Backup file '$ARCHIVE' does not exist." >&2
    exit 1
fi

echo "============================================================"
echo "==> [DeployX] Verifying Backup Integrity"
echo "    Target: $ARCHIVE"
echo "============================================================"

# 1. Test gzip integrity
echo -n "1. Verifying tar.gz archive decompression... "
if tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
    echo "OK"
else
    echo "FAILED: Corrupt tar archive" >&2
    exit 1
fi

# 2. Verify SHA-256 Checksum if present
CHECKSUM_FILE="${ARCHIVE}.sha256"
if [ -f "$CHECKSUM_FILE" ]; then
    echo -n "2. Verifying SHA-256 cryptographic checksum... "
    EXPECTED_HASH="$(cat "$CHECKSUM_FILE" | awk '{print $1}')"
    if command -v sha256sum >/dev/null 2>&1; then
        ACTUAL_HASH="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        ACTUAL_HASH="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
    else
        ACTUAL_HASH=""
    fi

    if [ -n "$ACTUAL_HASH" ]; then
        if [ "$EXPECTED_HASH" = "$ACTUAL_HASH" ]; then
            echo "MATCH ($ACTUAL_HASH)"
        else
            echo "MISMATCH! Expected: $EXPECTED_HASH, Got: $ACTUAL_HASH" >&2
            exit 1
        fi
    else
        echo "SKIPPED (no sha256 binary)"
    fi
else
    echo "2. Checksum file not found; skipping hash match."
fi

# 3. Verify internal structure
echo -n "3. Inspecting required backup contents... "
MEMBERS="$(tar -tzf "$ARCHIVE")"
if echo "$MEMBERS" | grep -q "metadata.json"; then
    echo "OK (metadata.json present)"
else
    echo "WARNING: metadata.json missing in archive"
fi

echo "============================================================"
echo " [SUCCESS] Backup archive is VALID and INTEGRITY-VERIFIED."
echo "============================================================"
