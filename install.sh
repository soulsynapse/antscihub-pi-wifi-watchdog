#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_TEMPLATE="${SCRIPT_DIR}/wifi-watchdog.service"
UNIT_TARGET="/etc/systemd/system/wifi-watchdog.service"

if [ ! -f "${UNIT_TEMPLATE}" ]; then
    echo "[wifi-watchdog] missing service template: ${UNIT_TEMPLATE}" >&2
    exit 1
fi

escaped_script_dir=$(printf '%s\n' "${SCRIPT_DIR}" | sed 's/[\\/&]/\\&/g')
sed "s/__WATCHDOG_DIR__/${escaped_script_dir}/g" "${UNIT_TEMPLATE}" > "${UNIT_TARGET}"

systemctl daemon-reload
systemctl enable wifi-watchdog.service

chmod +x "${SCRIPT_DIR}/wifi-watchdog.sh"

cat > /usr/local/bin/watchdog << EOF
#!/usr/bin/env bash
set -euo pipefail

exec "${SCRIPT_DIR}/wifi-watchdog.sh" "\$@"
EOF

chmod +x /usr/local/bin/watchdog

echo "[wifi-watchdog] install complete"
