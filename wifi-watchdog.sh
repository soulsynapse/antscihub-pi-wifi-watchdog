#!/usr/bin/env bash
# ============================================================================
# WiFi Watchdog (Wired-Aware)
#
# Behavior:
#   - If wired (eth0) is up and has connectivity → chill. Check infrequently.
#     WiFi can be up or down, we don't care.
#   - If wired drops → immediately ensure WiFi is up and connected.
#     Escalate aggressively until we have connectivity on WiFi.
#   - If wired was never present → treat WiFi as primary, always aggressive.
#
# Escalation ladder (WiFi recovery):
#   1. nmcli reconnect (fallback: wpa_cli reassociate)
#   2. ifdown/ifup wlan0
#   3. rfkill power-cycle
#   4. Restart networking services
#   5. Full interface reset
#   6. Reboot (nuclear)
# ============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
WIFI_INTERFACE="${WIFI_INTERFACE:-wlan0}"
WIRED_INTERFACE="${WIRED_INTERFACE:-eth0}"
WIFI_CONNECTION_NAME="${WIFI_CONNECTION_NAME:-}"

# Optional non-ICMP probes (disabled unless configured)
CONNECTIVITY_HTTP_URL="${CONNECTIVITY_HTTP_URL:-}"
CONNECTIVITY_TCP_HOST="${CONNECTIVITY_TCP_HOST:-}"
CONNECTIVITY_TCP_PORT="${CONNECTIVITY_TCP_PORT:-443}"
HTTP_PROBE_TIMEOUT="${HTTP_PROBE_TIMEOUT:-6}"
TCP_PROBE_TIMEOUT="${TCP_PROBE_TIMEOUT:-5}"

# Check intervals
CHECK_INTERVAL_WIFI_PRIMARY=15    # WiFi is our only link — check aggressively
CHECK_INTERVAL_WIRED_OK=60        # Wired is healthy — just keep an eye on things
CHECK_INTERVAL_WIRED_JUST_DROPPED=5  # Wired JUST dropped — check fast

# Ping targets
PING_TARGETS=("8.8.8.8" "1.1.1.1" "9.9.9.9")
PING_TIMEOUT=5
PING_COUNT=2

# Escalation thresholds (consecutive WiFi failures)
REASSOCIATE_AFTER=1
IFUPDOWN_AFTER=3
RFKILL_AFTER=5
RESTART_SERVICES_AFTER=7
FULL_RESET_AFTER=10

# Cooldowns after escalation actions
COOLDOWN_SHORT=10
COOLDOWN_MEDIUM=20
COOLDOWN_LONG=30

# Logging
LOG_TAG="wifi-watchdog"
DEVICE_ID="${DEVICE_ID:-$(hostname -s 2>/dev/null || echo unknown-device)}"

# Runtime paths
WATCHDOG_STATE_DIR="${WATCHDOG_STATE_DIR:-/var/lib/wifi-watchdog}"
WATCHDOG_STATE_FILE="${WATCHDOG_STATE_FILE:-${WATCHDOG_STATE_DIR}/state.env}"
STATE_SYNC_INTERVAL="${STATE_SYNC_INTERVAL:-30}"
SINGLETON_LOCK_FILE="${SINGLETON_LOCK_FILE:-/run/wifi-watchdog.lock}"

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
CONSECUTIVE_WIFI_FAILURES=0
TOTAL_RECONNECTS=0
LAST_CONNECTED_TIME=$(date +%s)
STARTUP_TIME=$(date +%s)
LAST_FAILURE_REASON="none"
LAST_FAILURE_TIME=0
LAST_RECOVERY_TIME=0
LAST_STATE_SYNC_TIME=0

# Track wired state transitions
WIRED_WAS_UP=false
WIRED_JUST_DROPPED=false

# Current operating mode
# "wired_ok"       = eth0 has connectivity, WiFi is optional
# "wifi_primary"   = no wired connectivity, WiFi is critical
MODE="unknown"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_info() {
    logger -t "${LOG_TAG}" -p daemon.info "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"
}

log_warn() {
    logger -t "${LOG_TAG}" -p daemon.warning "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*"
}

log_error() {
    logger -t "${LOG_TAG}" -p daemon.err "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*"
}

mqtt_report() {
    local event="$1"
    local message="$2"
    if command -v fleet-publish &>/dev/null; then
        fleet-publish \
            --topic "fleet/response/${DEVICE_ID}" \
            --json "{\"schema\":\"fleet.service-manager.v1\",\"event\":\"${event}\",\"service\":\"wifi-watchdog\",\"device_id\":\"${DEVICE_ID}\",\"timestamp\":$(date +%s),\"message\":\"${message}\",\"mode\":\"${MODE}\",\"consecutive_failures\":${CONSECUTIVE_WIFI_FAILURES},\"total_reconnects\":${TOTAL_RECONNECTS}}" \
            2>/dev/null || true
    fi
}

notify_watchdog() {
    if [ -n "${WATCHDOG_USEC:-}" ]; then
        systemd-notify WATCHDOG=1 2>/dev/null || true
    fi
}

command_exists() {
    command -v "$1" &>/dev/null
}

ensure_state_dir() {
    mkdir -p "${WATCHDOG_STATE_DIR}" 2>/dev/null
}

mark_failure() {
    LAST_FAILURE_REASON="$1"
    LAST_FAILURE_TIME=$(date +%s)
}

load_persistent_state() {
    if [ ! -f "${WATCHDOG_STATE_FILE}" ]; then
        return 0
    fi

    while IFS='=' read -r key value; do
        key="${key%$'\r'}"
        value="${value%$'\r'}"
        case "${key}" in
            CONSECUTIVE_WIFI_FAILURES|TOTAL_RECONNECTS|LAST_CONNECTED_TIME|LAST_FAILURE_TIME|LAST_RECOVERY_TIME)
                if [[ "${value}" =~ ^[0-9]+$ ]]; then
                    printf -v "${key}" '%s' "${value}"
                fi
                ;;
            LAST_FAILURE_REASON)
                LAST_FAILURE_REASON="${value:-none}"
                ;;
        esac
    done < "${WATCHDOG_STATE_FILE}"
}

persist_state() {
    local tmp_file
    tmp_file="${WATCHDOG_STATE_FILE}.tmp"

    ensure_state_dir || return 1

    {
        printf 'CONSECUTIVE_WIFI_FAILURES=%s\n' "${CONSECUTIVE_WIFI_FAILURES}"
        printf 'TOTAL_RECONNECTS=%s\n' "${TOTAL_RECONNECTS}"
        printf 'LAST_CONNECTED_TIME=%s\n' "${LAST_CONNECTED_TIME}"
        printf 'LAST_FAILURE_REASON=%s\n' "${LAST_FAILURE_REASON}"
        printf 'LAST_FAILURE_TIME=%s\n' "${LAST_FAILURE_TIME}"
        printf 'LAST_RECOVERY_TIME=%s\n' "${LAST_RECOVERY_TIME}"
    } > "${tmp_file}" 2>/dev/null || return 1

    if ! mv -f "${tmp_file}" "${WATCHDOG_STATE_FILE}" 2>/dev/null; then
        rm -f "${tmp_file}" 2>/dev/null || true
        return 1
    fi

    LAST_STATE_SYNC_TIME=$(date +%s)
    return 0
}

persist_state_if_due() {
    local now
    now=$(date +%s)

    if [ "${LAST_STATE_SYNC_TIME}" -eq 0 ] || [ $((now - LAST_STATE_SYNC_TIME)) -ge "${STATE_SYNC_INTERVAL}" ]; then
        persist_state || log_warn "Failed to persist watchdog state to ${WATCHDOG_STATE_FILE}"
    fi
}

run_preflight_checks() {
    local missing_required=""
    local optional_available=""
    local optional_missing=""
    local cmd

    for cmd in ip ping; do
        if ! command_exists "${cmd}"; then
            missing_required="${missing_required}${missing_required:+,}${cmd}"
        fi
    done

    if [ -n "${missing_required}" ]; then
        log_error "Missing required commands: ${missing_required}"
        mqtt_report "dependency_missing" "Missing required commands: ${missing_required}"
        exit 1
    fi

    for cmd in nmcli iwgetid iw wpa_cli rfkill ifdown ifup dhclient dhcpcd curl wget nc timeout flock; do
        if command_exists "${cmd}"; then
            optional_available="${optional_available}${optional_available:+,}${cmd}"
        else
            optional_missing="${optional_missing}${optional_missing:+,}${cmd}"
        fi
    done

    if [ -n "${optional_available}" ]; then
        log_info "Optional commands available: ${optional_available}"
    fi
    if [ -n "${optional_missing}" ]; then
        log_warn "Optional commands missing: ${optional_missing}"
    fi

    if [ -n "${CONNECTIVITY_HTTP_URL}" ] && ! command_exists curl && ! command_exists wget; then
        log_warn "CONNECTIVITY_HTTP_URL is set, but curl/wget is unavailable; HTTP probe disabled"
    fi
    if [ -n "${CONNECTIVITY_TCP_HOST}" ] && ! command_exists nc && ! command_exists timeout; then
        log_warn "CONNECTIVITY_TCP_HOST is set, but nc/timeout is unavailable; TCP probe disabled"
    fi
}

acquire_singleton_lock() {
    local lock_dir

    if ! command_exists flock; then
        log_warn "flock not found; single-instance lock disabled"
        return 0
    fi

    lock_dir=$(dirname "${SINGLETON_LOCK_FILE}")
    mkdir -p "${lock_dir}" 2>/dev/null || true

    # Keep the FD open for the script lifetime so the lock remains held.
    exec 9>"${SINGLETON_LOCK_FILE}"
    if ! flock -n 9; then
        log_error "Another watchdog instance is already running (lock: ${SINGLETON_LOCK_FILE})"
        exit 1
    fi
}

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [run|report|help]

  run      Start WiFi watchdog loop (default)
  report   Write a concise watchdog diagnostic report to Desktop/5-UPLOAD/diagnostics
  help     Show this help message
EOF
}

resolve_report_output_dir() {
    local existing_dir
    existing_dir=$(find /home -maxdepth 5 -type d -path '/home/*/Desktop/5-UPLOAD/diagnostics' 2>/dev/null | head -1 || true)
    if [ -n "${existing_dir}" ]; then
        echo "${existing_dir}"
        return 0
    fi

    case "${SCRIPT_DIR}" in
        /home/*/Desktop/3-SYSTEM/wifi-watchdog)
            echo "${SCRIPT_DIR%/Desktop/3-SYSTEM/wifi-watchdog}/Desktop/5-UPLOAD/diagnostics"
            return 0
            ;;
    esac

    if [ -n "${SUDO_USER:-}" ] && [ -d "/home/${SUDO_USER}" ]; then
        echo "/home/${SUDO_USER}/Desktop/5-UPLOAD/diagnostics"
        return 0
    fi

    if [ -n "${HOME:-}" ]; then
        echo "${HOME}/Desktop/5-UPLOAD/diagnostics"
        return 0
    fi

    echo "${SCRIPT_DIR}/diagnostics"
}

read_watchdog_journal() {
    if journalctl "$@" 2>/dev/null; then
        return 0
    fi

    if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
        sudo -n journalctl "$@" 2>/dev/null
        return $?
    fi

    return 1
}

emit_recent_matches() {
    local logs="$1"
    local pattern="$2"
    local limit="$3"
    local matches

    matches=$(printf '%s\n' "${logs}" | grep -Ei "${pattern}" | tail -n "${limit}" || true)
    if [ -n "${matches}" ]; then
        printf '%s\n' "${matches}"
    else
        echo "(none)"
    fi
}

render_interface_snapshot() {
    local iface="$1"

    echo "-- ${iface} --"
    if ! interface_exists "${iface}"; then
        echo "Interface not found"
        return 0
    fi

    ip -brief addr show "${iface}" 2>/dev/null || true
    ip route show dev "${iface}" 2>/dev/null || true

    if [ "${iface}" = "${WIFI_INTERFACE}" ]; then
        local ssid
        ssid=$(iwgetid "${iface}" -r 2>/dev/null || true)
        if [ -n "${ssid}" ]; then
            echo "SSID: ${ssid}"
        else
            echo "SSID: (not associated)"
        fi
    fi
}

generate_watchdog_report() {
    local timestamp hostname_short hostname_safe output_dir output_file
    local logs_24h logs_recent
    local down_count recover_count action_count

    timestamp=$(date '+%Y-%m-%d_T-%H-%M-%S')
    hostname_short=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown-host)
    hostname_safe=$(printf '%s' "${hostname_short}" | tr -cd '[:alnum:]._-')
    output_dir=$(resolve_report_output_dir)
    output_file="${output_dir}/watchdog_report_${timestamp}__(${hostname_safe}).txt"

    mkdir -p "${output_dir}"

    logs_24h=$(read_watchdog_journal -u wifi-watchdog.service --since "24 hours ago" -o short-iso --no-pager || true)
    logs_recent=$(read_watchdog_journal -u wifi-watchdog.service -o short-iso --no-pager -n 80 || true)

    if [ -n "${logs_24h}" ]; then
        down_count=$(printf '%s\n' "${logs_24h}" | grep -Eic 'dropped|wifi check failed|not connected|cannot failover|failed to (locate executable|start)' || true)
        recover_count=$(printf '%s\n' "${logs_24h}" | grep -Eic 'recovered|failover successful|wired connection.*up' || true)
        action_count=$(printf '%s\n' "${logs_24h}" | grep -Eic 'escalation|reassociate|ifupdown|rfkill|restart|full interface reset|activating wifi' || true)
    else
        down_count=0
        recover_count=0
        action_count=0
    fi

    {
        echo "WiFi Watchdog Diagnostic Report"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "Host: ${hostname_short}"
        echo "Service: wifi-watchdog.service"
        echo "Script: ${SCRIPT_DIR}/wifi-watchdog.sh"
        echo

        echo "== Service State =="
        echo "Active: $(systemctl is-active wifi-watchdog.service 2>/dev/null || echo unknown)"
        echo "Enabled: $(systemctl is-enabled wifi-watchdog.service 2>/dev/null || echo unknown)"
        systemctl show wifi-watchdog.service --property=ExecMainPID,ExecMainStatus,NRestarts,WatchdogUSec --no-pager 2>/dev/null || true
        echo

        echo "== Event Summary (last 24h) =="
        echo "Down/failure signals: ${down_count}"
        echo "Recovery signals: ${recover_count}"
        echo "Recovery actions attempted: ${action_count}"
        echo

        echo "Recent down/failure events:"
        emit_recent_matches "${logs_24h}" 'dropped|wifi check failed|not connected|cannot failover|failed to' 10
        echo

        echo "Recent reconnect/recovery events:"
        emit_recent_matches "${logs_24h}" 'recovered|failover successful|wired connection.*up|switching to relaxed mode' 10
        echo

        echo "Recent watchdog actions:"
        emit_recent_matches "${logs_24h}" 'escalation|reassociate|ifupdown|rfkill|restart|full interface reset|activating wifi|bringing it up' 12
        echo

        echo "== Network Snapshot =="
        if command -v ip &>/dev/null; then
            render_interface_snapshot "${WIRED_INTERFACE}"
            echo
            render_interface_snapshot "${WIFI_INTERFACE}"
        else
            echo "ip command unavailable"
        fi
        echo

        if command -v nmcli &>/dev/null; then
            echo "nmcli device status (${WIRED_INTERFACE}/${WIFI_INTERFACE}):"
            nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device 2>/dev/null | grep -E "^(${WIRED_INTERFACE}|${WIFI_INTERFACE}):" || echo "(no nmcli rows for target interfaces)"
            echo
        fi

        echo "== Recent Service Log Tail (80 lines) =="
        if [ -n "${logs_recent}" ]; then
            printf '%s\n' "${logs_recent}"
        else
            echo "(journal unavailable or no recent entries)"
        fi
    } > "${output_file}"

    echo "[watchdog] report saved: ${output_file}"
}

handle_cli_command() {
    local command="${1:-run}"

    case "${command}" in
        run)
            return 0
            ;;
        report)
            generate_watchdog_report
            exit $?
            ;;
        help|-h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown command: ${command}" >&2
            print_usage >&2
            exit 2
            ;;
    esac
}

networkmanager_running() {
    command -v nmcli &>/dev/null || return 1
    nmcli -t -f RUNNING general 2>/dev/null | grep -qx "running"
}

get_nm_wifi_connection_name() {
    if [ -n "${WIFI_CONNECTION_NAME}" ]; then
        echo "${WIFI_CONNECTION_NAME}"
        return 0
    fi

    local active_connection
    active_connection=$(nmcli -g GENERAL.CONNECTION device show "${WIFI_INTERFACE}" 2>/dev/null | head -1 || true)
    if [ -n "${active_connection}" ] && [ "${active_connection}" != "--" ]; then
        echo "${active_connection}"
        return 0
    fi

    return 1
}

try_nmcli_reconnect() {
    networkmanager_running || return 1

    nmcli radio wifi on &>/dev/null || true
    nmcli device set "${WIFI_INTERFACE}" managed yes &>/dev/null || true
    nmcli device set "${WIFI_INTERFACE}" autoconnect yes &>/dev/null || true

    local connection_name
    connection_name=$(get_nm_wifi_connection_name || true)
    if [ -n "${connection_name}" ]; then
        nmcli connection modify "${connection_name}" connection.autoconnect yes &>/dev/null || true
        nmcli connection up id "${connection_name}" ifname "${WIFI_INTERFACE}" &>/dev/null && return 0
    fi

    nmcli device connect "${WIFI_INTERFACE}" &>/dev/null
}

# ---------------------------------------------------------------------------
# Interface checks
# ---------------------------------------------------------------------------

interface_exists() {
    local iface="$1"
    [ -d "/sys/class/net/${iface}" ]
}

interface_has_carrier() {
    local iface="$1"
    [ -d "/sys/class/net/${iface}" ] && [ "$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || echo 0)" = "1" ]
}

interface_has_ip() {
    local iface="$1"
    ip addr show "${iface}" 2>/dev/null | grep -q "inet "
}

get_interface_ipv4() {
    local iface="$1"
    ip -o -4 addr show dev "${iface}" scope global 2>/dev/null | awk 'NR==1 {split($4, ip, "/"); print ip[1]}'
}

ping_via_interface() {
    local iface="$1"
    local host="$2"
    ping -c "${PING_COUNT}" -W "${PING_TIMEOUT}" -I "${iface}" "$host" &>/dev/null
}

get_gateway_for_interface() {
    local iface="$1"
    ip route show default dev "${iface}" 2>/dev/null | awk '/default/ {print $3}' | head -1
}

tcp_probe_via_interface() {
    local iface="$1"
    local source_ip

    if [ -z "${CONNECTIVITY_TCP_HOST}" ]; then
        return 1
    fi

    source_ip=$(get_interface_ipv4 "${iface}")
    if [ -z "${source_ip}" ]; then
        return 1
    fi

    if command_exists nc; then
        nc -z -w "${TCP_PROBE_TIMEOUT}" -s "${source_ip}" "${CONNECTIVITY_TCP_HOST}" "${CONNECTIVITY_TCP_PORT}" &>/dev/null
        return $?
    fi

    if command_exists timeout; then
        # /dev/tcp fallback is less strict because it cannot bind to a specific source IP.
        timeout "${TCP_PROBE_TIMEOUT}" bash -c "exec 3<>/dev/tcp/${CONNECTIVITY_TCP_HOST}/${CONNECTIVITY_TCP_PORT}" &>/dev/null
        return $?
    fi

    return 1
}

http_probe_via_interface() {
    local iface="$1"
    local source_ip

    if [ -z "${CONNECTIVITY_HTTP_URL}" ]; then
        return 1
    fi

    if command_exists curl; then
        curl --silent --show-error --fail \
            --connect-timeout "${HTTP_PROBE_TIMEOUT}" \
            --max-time "${HTTP_PROBE_TIMEOUT}" \
            --interface "${iface}" \
            --output /dev/null \
            "${CONNECTIVITY_HTTP_URL}" &>/dev/null
        return $?
    fi

    source_ip=$(get_interface_ipv4 "${iface}")
    if [ -n "${source_ip}" ] && command_exists wget; then
        wget --quiet --spider \
            --tries=1 \
            --timeout="${HTTP_PROBE_TIMEOUT}" \
            --bind-address="${source_ip}" \
            "${CONNECTIVITY_HTTP_URL}" &>/dev/null
        return $?
    fi

    return 1
}

probe_non_icmp_connectivity() {
    local iface="$1"

    http_probe_via_interface "${iface}" && return 0
    tcp_probe_via_interface "${iface}" && return 0

    return 1
}

# Full connectivity check on a given interface
check_interface_connectivity() {
    local iface="$1"

    if ! interface_exists "$iface"; then
        return 1
    fi

    if ! interface_has_carrier "$iface"; then
        return 1
    fi

    if ! interface_has_ip "$iface"; then
        return 1
    fi

    # Try gateway first
    local gw
    gw=$(get_gateway_for_interface "$iface")
    if [ -n "$gw" ]; then
        if ping_via_interface "$iface" "$gw"; then
            return 0
        fi
    fi

    # Try fallback targets
    for target in "${PING_TARGETS[@]}"; do
        if ping_via_interface "$iface" "$target"; then
            return 0
        fi
    done

    # Optional fallback probes for networks that block ICMP.
    if probe_non_icmp_connectivity "${iface}"; then
        return 0
    fi

    return 1
}

# WiFi-specific checks
wifi_is_associated() {
    local ssid

    if command_exists iwgetid; then
        ssid=$(iwgetid "${WIFI_INTERFACE}" -r 2>/dev/null || true)
        if [ -n "${ssid}" ]; then
            return 0
        fi
    fi

    if command_exists iw && iw dev "${WIFI_INTERFACE}" link 2>/dev/null | grep -q '^Connected to '; then
        return 0
    fi

    if networkmanager_running; then
        if nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep -q "^${WIFI_INTERFACE}:connected$"; then
            return 0
        fi
    fi

    if command_exists wpa_cli; then
        if wpa_cli -i "${WIFI_INTERFACE}" status 2>/dev/null | grep -q '^wpa_state=COMPLETED$'; then
            return 0
        fi
    fi

    return 1
}

check_wifi_connectivity() {
    if ! interface_exists "${WIFI_INTERFACE}"; then
        return 1
    fi

    if ! wifi_is_associated; then
        return 1
    fi

    check_interface_connectivity "${WIFI_INTERFACE}"
}

check_wired_connectivity() {
    check_interface_connectivity "${WIRED_INTERFACE}"
}

# ---------------------------------------------------------------------------
# Wired state tracking
# ---------------------------------------------------------------------------

update_wired_state() {
    local wired_up_now=false

    if check_wired_connectivity; then
        wired_up_now=true
    fi

    if [ "$wired_up_now" = true ]; then
        # Wired is good
        if [ "$MODE" = "wifi_primary" ] || [ "$MODE" = "unknown" ]; then
            log_info "Wired connection (${WIRED_INTERFACE}) is UP — switching to relaxed mode"
            mqtt_report "wired_up" "Wired connection restored, switching to relaxed WiFi monitoring"
            LAST_RECOVERY_TIME=$(date +%s)
            persist_state || true
        fi
        MODE="wired_ok"
        WIRED_WAS_UP=true
        WIRED_JUST_DROPPED=false

        # Reset WiFi failure counter — we have connectivity via wired
        if [ "${CONSECUTIVE_WIFI_FAILURES}" -gt 0 ]; then
            log_info "Clearing WiFi failure counter (wired is healthy)"
            CONSECUTIVE_WIFI_FAILURES=0
            persist_state || true
        fi
    else
        # Wired is down
        if [ "$WIRED_WAS_UP" = true ]; then
            # Transition: wired just dropped
            log_warn "Wired connection (${WIRED_INTERFACE}) DROPPED — switching to aggressive WiFi mode"
            mqtt_report "wired_down" "Wired connection lost, ensuring WiFi is active"
            WIRED_JUST_DROPPED=true
            WIRED_WAS_UP=false
            mark_failure "wired_dropped"
            persist_state || true
        fi
        MODE="wifi_primary"
    fi
}

# ---------------------------------------------------------------------------
# WiFi recovery actions (escalation ladder)
# ---------------------------------------------------------------------------

do_reassociate() {
    if try_nmcli_reconnect; then
        log_info "Escalation 1/${FULL_RESET_AFTER}: nmcli reconnect"
        mqtt_report "reassociate" "Attempting NetworkManager reconnect"
    else
        log_info "Escalation 1/${FULL_RESET_AFTER}: wpa_cli reassociate"
        mqtt_report "reassociate" "Attempting wpa_cli reassociate"

        wpa_cli -i "${WIFI_INTERFACE}" reassociate &>/dev/null || true
        wpa_cli -i "${WIFI_INTERFACE}" reconfigure &>/dev/null || true
    fi

    sleep "${COOLDOWN_SHORT}"
}

do_ifupdown() {
    log_info "Escalation 2/${FULL_RESET_AFTER}: Bouncing interface ${WIFI_INTERFACE}"
    mqtt_report "ifupdown" "Bouncing WiFi interface"

    if try_nmcli_reconnect; then
        :
    elif command -v ifdown &>/dev/null; then
        ifdown "${WIFI_INTERFACE}" 2>/dev/null || true
        sleep 2
        ifup "${WIFI_INTERFACE}" 2>/dev/null || true
    else
        ip link set "${WIFI_INTERFACE}" down 2>/dev/null || true
        sleep 2
        ip link set "${WIFI_INTERFACE}" up 2>/dev/null || true
    fi

    sleep "${COOLDOWN_MEDIUM}"
    request_dhcp
}

do_rfkill_cycle() {
    log_info "Escalation 3/${FULL_RESET_AFTER}: rfkill power-cycle"
    mqtt_report "rfkill" "Power-cycling WiFi radio"

    if networkmanager_running; then
        nmcli radio wifi off &>/dev/null || true
        sleep 3
        nmcli radio wifi on &>/dev/null || true
        sleep 5
        try_nmcli_reconnect || true
    elif command -v rfkill &>/dev/null; then
        rfkill block wifi 2>/dev/null || true
        sleep 3
        rfkill unblock wifi 2>/dev/null || true
        sleep 5
        ip link set "${WIFI_INTERFACE}" up 2>/dev/null || true
    else
        log_warn "rfkill not available, skipping"
    fi

    sleep "${COOLDOWN_MEDIUM}"
    request_dhcp
}

do_restart_services() {
    log_info "Escalation 4/${FULL_RESET_AFTER}: Restarting networking services"
    if networkmanager_running; then
        mqtt_report "restart_services" "Restarting NetworkManager"
        systemctl restart NetworkManager 2>/dev/null || true
        sleep 5
        try_nmcli_reconnect || true
    else
        mqtt_report "restart_services" "Restarting wpa_supplicant, dhcpcd, networking"

        systemctl restart wpa_supplicant 2>/dev/null || true
        sleep 3

        if systemctl list-units --type=service --all 2>/dev/null | grep -q dhcpcd; then
            systemctl restart dhcpcd 2>/dev/null || true
            sleep 5
        fi

        systemctl restart networking 2>/dev/null || true
    fi

    sleep "${COOLDOWN_LONG}"
}

do_full_reset() {
    log_info "Escalation 5/${FULL_RESET_AFTER}: Full interface reset"
    mqtt_report "full_reset" "Full WiFi interface teardown and rebuild"

    ip addr flush dev "${WIFI_INTERFACE}" 2>/dev/null || true
    ip route flush dev "${WIFI_INTERFACE}" 2>/dev/null || true
    ip link set "${WIFI_INTERFACE}" down 2>/dev/null || true
    sleep 3
    ip link set "${WIFI_INTERFACE}" up 2>/dev/null || true
    sleep 5
    if ! try_nmcli_reconnect; then
        wpa_cli -i "${WIFI_INTERFACE}" reconfigure &>/dev/null || true
    fi
    sleep 5
    request_dhcp
    sleep "${COOLDOWN_LONG}"
}

request_dhcp() {
    if networkmanager_running; then
        return 0
    fi

    if command -v dhclient &>/dev/null; then
        dhclient -r "${WIFI_INTERFACE}" 2>/dev/null || true
        dhclient "${WIFI_INTERFACE}" 2>/dev/null || true
    elif command -v dhcpcd &>/dev/null; then
        dhcpcd -n "${WIFI_INTERFACE}" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Escalation dispatcher
# ---------------------------------------------------------------------------

escalate_wifi() {
    CONSECUTIVE_WIFI_FAILURES=$((CONSECUTIVE_WIFI_FAILURES + 1))
    mark_failure "wifi_check_failed"
    log_warn "WiFi check failed (consecutive: ${CONSECUTIVE_WIFI_FAILURES}, mode: ${MODE})"
    persist_state_if_due

    # Pick escalation level, cycling back after full_reset
    local level=$(( (CONSECUTIVE_WIFI_FAILURES - 1) % FULL_RESET_AFTER + 1 ))

    if [ "$level" -ge "${FULL_RESET_AFTER}" ]; then
        do_full_reset
    elif [ "$level" -ge "${RESTART_SERVICES_AFTER}" ]; then
        do_restart_services
    elif [ "$level" -ge "${RFKILL_AFTER}" ]; then
        do_rfkill_cycle
    elif [ "$level" -ge "${IFUPDOWN_AFTER}" ]; then
        do_ifupdown
    elif [ "$level" -ge "${REASSOCIATE_AFTER}" ]; then
        do_reassociate
    fi
}

handle_wifi_success() {
    if [ "${CONSECUTIVE_WIFI_FAILURES}" -gt 0 ]; then
        TOTAL_RECONNECTS=$((TOTAL_RECONNECTS + 1))
        local downtime=$(( $(date +%s) - LAST_CONNECTED_TIME ))
        log_info "WiFi recovered after ${CONSECUTIVE_WIFI_FAILURES} failures (downtime: ~${downtime}s, total reconnects: ${TOTAL_RECONNECTS})"
        mqtt_report "recovered" "WiFi recovered after ${CONSECUTIVE_WIFI_FAILURES} failures, downtime ~${downtime}s"
        CONSECUTIVE_WIFI_FAILURES=0
        LAST_RECOVERY_TIME=$(date +%s)
        persist_state || true
    fi
    LAST_CONNECTED_TIME=$(date +%s)
    persist_state_if_due
}

# ---------------------------------------------------------------------------
# Ensure WiFi is at least up (even if wired is primary)
# Called when wired drops to make sure WiFi is ready to take over
# ---------------------------------------------------------------------------

ensure_wifi_up() {
    # If WiFi interface does not exist, nothing we can do.
    if ! interface_exists "${WIFI_INTERFACE}"; then
        mark_failure "wifi_interface_missing"
        persist_state || true
        log_error "WiFi interface ${WIFI_INTERFACE} does not exist - cannot failover"
        return 1
    fi

    # If WiFi is already connected, great.
    if check_wifi_connectivity; then
        return 0
    fi

    log_info "WiFi not connected - bringing it up for failover"
    mqtt_report "failover_start" "Wired down, activating WiFi"

    # Make sure the interface is up.
    ip link set "${WIFI_INTERFACE}" up 2>/dev/null || true

    # Make sure rfkill is not blocking it.
    if command_exists rfkill; then
        rfkill unblock wifi 2>/dev/null || true
    fi

    # Ask wpa_supplicant (or NetworkManager) to connect.
    if ! try_nmcli_reconnect; then
        wpa_cli -i "${WIFI_INTERFACE}" reconfigure &>/dev/null || true
        wpa_cli -i "${WIFI_INTERFACE}" reassociate &>/dev/null || true
    fi

    # Wait for association and request DHCP.
    sleep 10
    request_dhcp
    sleep 5

    # Check if it worked.
    if check_wifi_connectivity; then
        log_info "WiFi failover successful"
        mqtt_report "failover_ok" "WiFi is now active as primary connection"
        LAST_RECOVERY_TIME=$(date +%s)
        persist_state || true
        return 0
    fi

    mark_failure "wifi_failover_not_ready"
    persist_state_if_due
    log_warn "WiFi failover - not connected yet, entering escalation"
    return 1
}

# ---------------------------------------------------------------------------
# Determine sleep interval based on current state
# ---------------------------------------------------------------------------

get_check_interval() {
    if [ "$WIRED_JUST_DROPPED" = true ]; then
        # Wired JUST dropped — check very fast to get WiFi up ASAP
        echo "${CHECK_INTERVAL_WIRED_JUST_DROPPED}"
    elif [ "$MODE" = "wired_ok" ]; then
        # Wired is healthy — relax
        echo "${CHECK_INTERVAL_WIRED_OK}"
    else
        # WiFi is primary — stay aggressive
        echo "${CHECK_INTERVAL_WIFI_PRIMARY}"
    fi
}

handle_cli_command "${1:-run}"
acquire_singleton_lock
run_preflight_checks

if ! ensure_state_dir; then
    log_warn "Unable to create state directory: ${WATCHDOG_STATE_DIR}"
fi
load_persistent_state
trap 'persist_state || true' EXIT

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

log_info "========================================="
log_info "WiFi Watchdog (Wired-Aware) starting"
log_info "WiFi interface: ${WIFI_INTERFACE}"
log_info "Wired interface: ${WIRED_INTERFACE}"
log_info "========================================="
log_info "Check intervals: wifi_primary=${CHECK_INTERVAL_WIFI_PRIMARY}s, wired_ok=${CHECK_INTERVAL_WIRED_OK}s, wired_dropped=${CHECK_INTERVAL_WIRED_JUST_DROPPED}s"
log_info "Escalation: reassociate@${REASSOCIATE_AFTER}, ifupdown@${IFUPDOWN_AFTER}, rfkill@${RFKILL_AFTER}, restart@${RESTART_SERVICES_AFTER}, full_reset@${FULL_RESET_AFTER} (cycles)"
log_info "State file: ${WATCHDOG_STATE_FILE} (total reconnects: ${TOTAL_RECONNECTS}, consecutive failures: ${CONSECUTIVE_WIFI_FAILURES})"
mqtt_report "started" "WiFi watchdog started (wired-aware mode)"

# Give the system a moment to bring up networking on boot
sleep 10

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

while true; do
    # -----------------------------------------------------------------------
    # Step 1: Check wired state and detect transitions
    # -----------------------------------------------------------------------
    update_wired_state

    # -----------------------------------------------------------------------
    # Step 2: Act based on mode
    # -----------------------------------------------------------------------
    case "$MODE" in

        wired_ok)
            # Wired is healthy. WiFi is optional.
            # We still do a light check — if WiFi happens to be connected, great.
            # If not, we don't care unless wired drops.
            # Nothing to escalate.
            WIRED_JUST_DROPPED=false
            ;;

        wifi_primary)
            # No wired connectivity. WiFi is our lifeline.

            # If wired just dropped, try to bring WiFi up immediately
            if [ "$WIRED_JUST_DROPPED" = true ]; then
                ensure_wifi_up
                WIRED_JUST_DROPPED=false
            fi

            # Check WiFi connectivity
            if check_wifi_connectivity; then
                handle_wifi_success
            else
                escalate_wifi
            fi
            ;;

        *)
            # First loop — determine initial state
            if check_wired_connectivity; then
                MODE="wired_ok"
                WIRED_WAS_UP=true
                log_info "Initial state: wired is UP, relaxed mode"
            else
                MODE="wifi_primary"
                log_info "Initial state: no wired connection, WiFi is primary"
                # Immediately check/ensure WiFi
                if ! check_wifi_connectivity; then
                    ensure_wifi_up
                fi
            fi
            ;;
    esac

    # -----------------------------------------------------------------------
    # Step 3: Watchdog ping and sleep
    # -----------------------------------------------------------------------
    notify_watchdog
    persist_state_if_due
    local_interval=$(get_check_interval)
    sleep "${local_interval}"
done
