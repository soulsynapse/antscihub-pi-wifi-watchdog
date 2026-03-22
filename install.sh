#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install systemd unit
cp "${SCRIPT_DIR}/wifi-watchdog.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable wifi-watchdog.service

# Make the watchdog script executable
chmod +x "${SCRIPT_DIR}/wifi-watchdog.sh"

echo "[wifi-watchdog] install complete"