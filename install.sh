#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Generate systemd unit with absolute path
cat > /etc/systemd/system/wifi-watchdog.service << EOF
[Unit]
Description=WiFi Watchdog - automatic network reconnection service
After=sys-subsystem-net-devices-wlan0.device fleet-shell.service
Wants=sys-subsystem-net-devices-wlan0.device

StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${SCRIPT_DIR}/wifi-watchdog.sh
WorkingDirectory=${SCRIPT_DIR}
Restart=always
RestartSec=3
User=root

StartLimitBurst=0
WatchdogSec=120

Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wifi-watchdog.service

chmod +x "${SCRIPT_DIR}/wifi-watchdog.sh"

echo "[wifi-watchdog] install complete"