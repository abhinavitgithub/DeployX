#!/usr/bin/env bash
# DeployX — AWS EC2 systemd Service Installer
# Installs and enables the deployx.service systemd unit for automatic host reboot recovery
# without disrupting running containers.

set -euo pipefail

SERVICE_PATH="/etc/systemd/system/deployx.service"
DEPLOYX_DIR="${DEPLOYX_DIR:-/opt/deployx}"

echo "============================================================"
echo "==> [DeployX] Installing systemd Service Unit"
echo "    Target Unit: $SERVICE_PATH"
echo "    App Dir:     $DEPLOYX_DIR"
echo "============================================================"

# Ensure root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root (or via sudo)." >&2
    exit 1
fi

if [ ! -d "$DEPLOYX_DIR" ]; then
    echo "Creating application directory: $DEPLOYX_DIR..."
    mkdir -p "$DEPLOYX_DIR/data" "$DEPLOYX_DIR/backups"
fi

# Detect docker-compose command
COMPOSE_BIN="/usr/local/bin/docker-compose"
if [ ! -x "$COMPOSE_BIN" ]; then
    if [ -x "/usr/local/lib/docker/cli-plugins/docker-compose" ]; then
        COMPOSE_BIN="/usr/local/lib/docker/cli-plugins/docker-compose"
    elif command -v docker >/dev/null 2>&1; then
        COMPOSE_BIN="docker compose"
    else
        echo "Error: Neither docker-compose binary nor docker CLI plugin found." >&2
        exit 1
    fi
fi

echo "Detected Compose command: $COMPOSE_BIN"

# Write systemd service unit
cat << SYSTEMD_EOF > "$SERVICE_PATH"
[Unit]
Description=DeployX Multi-Container Docker Application
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$DEPLOYX_DIR
User=root
Group=docker
ExecStart=/bin/sh -c 'if [ -x /usr/local/bin/docker-compose ]; then /usr/local/bin/docker-compose up -d --remove-orphans; elif [ -x /usr/local/lib/docker/cli-plugins/docker-compose ]; then /usr/local/lib/docker/cli-plugins/docker-compose up -d --remove-orphans; else docker compose up -d --remove-orphans; fi'
ExecStop=/bin/sh -c 'if [ -x /usr/local/bin/docker-compose ]; then /usr/local/bin/docker-compose down; elif [ -x /usr/local/lib/docker/cli-plugins/docker-compose ]; then /usr/local/lib/docker/cli-plugins/docker-compose down; else docker compose down; fi'
ExecReload=/bin/sh -c 'if [ -x /usr/local/bin/docker-compose ]; then /usr/local/bin/docker-compose pull && /usr/local/bin/docker-compose up -d --remove-orphans; else docker compose pull && docker compose up -d --remove-orphans; fi'
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

chmod 644 "$SERVICE_PATH"
systemctl daemon-reload
systemctl enable deployx.service

echo "[SUCCESS] deployx.service successfully installed and enabled."

# Check if containers are already running; do NOT interrupt them unnecessarily
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -q "deployx-backend"; then
    echo "DeployX containers are already running. Preserving active application state."
    # Mark service active without restarting containers
    systemctl is-active deployx.service >/dev/null 2>&1 || systemctl start --no-block deployx.service || true
else
    echo "DeployX containers not running. Starting deployx.service..."
    if [ -f "$DEPLOYX_DIR/compose.yaml" ]; then
        systemctl start deployx.service
    else
        echo "Note: $DEPLOYX_DIR/compose.yaml not found yet. Service will start on next deployment or reboot."
    fi
fi

systemctl status deployx.service --no-pager || true
