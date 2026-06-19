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
#   4. Full interface reset
# ============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
WIFI_INTERFACE="${WIFI_INTERFACE:-wlan0}"
WIRED_INTERFACE="${WIRED_INTERFACE:-eth0}"
WIFI_CONNECTION_NAME="${WIFI_CONNECTION_NAME:-}"
ALWAYS_RECORDING_MODE="true"

# Optional non-ICMP probes (disabled unless configured)
CONNECTIVITY_HTTP_URL="${CONNECTIVITY_HTTP_URL:-}"
CONNECTIVITY_TCP_HOST="${CONNECTIVITY_TCP_HOST:-}"
CONNECTIVITY_TCP_PORT="${CONNECTIVITY_TCP_PORT:-443}"
HTTP_PROBE_TIMEOUT="${HTTP_PROBE_TIMEOUT:-6}"
TCP_PROBE_TIMEOUT="${TCP_PROBE_TIMEOUT:-5}"

# Stationary Pi WiFi stability controls
DISABLE_WIFI_STEERING="${DISABLE_WIFI_STEERING:-true}"
DISABLE_WIFI_BGSCAN="${DISABLE_WIFI_BGSCAN:-true}"
WIFI_BSSID="${WIFI_BSSID:-}"
WIFI_BAND="${WIFI_BAND:-}"
WIFI_CHANNEL="${WIFI_CHANNEL:-}"
# Recovery pacing / anti-thrash controls
RECOVERY_ACTION_MIN_INTERVAL="${RECOVERY_ACTION_MIN_INTERVAL:-45}"
FULL_RESET_MIN_INTERVAL="${FULL_RESET_MIN_INTERVAL:-180}"
MAX_DISRUPTIVE_ACTIONS_PER_HOUR="${MAX_DISRUPTIVE_ACTIONS_PER_HOUR:-12}"
THRASH_PAUSE_SECONDS="${THRASH_PAUSE_SECONDS:-300}"

# Watchdog-safe pacing / command bounding
WATCHDOG_HEARTBEAT_SLICE="${WATCHDOG_HEARTBEAT_SLICE:-10}"
COMMAND_TIMEOUT_DEFAULT="${COMMAND_TIMEOUT_DEFAULT:-25}"
COMMAND_TIMEOUT_PING="${COMMAND_TIMEOUT_PING:-15}"
COMMAND_TIMEOUT_DHCP="${COMMAND_TIMEOUT_DHCP:-30}"
COMMAND_TIMEOUT_NMCLI="${COMMAND_TIMEOUT_NMCLI:-20}"
COMMAND_TIMEOUT_WPA_CLI="${COMMAND_TIMEOUT_WPA_CLI:-15}"

# Check intervals
CHECK_INTERVAL_WIFI_PRIMARY=15    # WiFi is our only link — check aggressively
CHECK_INTERVAL_WIRED_OK=60        # Wired is healthy — just keep an eye on things
CHECK_INTERVAL_WIRED_JUST_DROPPED=5  # Wired JUST dropped — check fast

# Ping targets
PING_TARGETS=("8.8.8.8" "1.1.1.1" "9.9.9.9")
PING_TIMEOUT=5
PING_COUNT=2

# Escalation thresholds (consecutive WiFi failures)
REASSOCIATE_AFTER="${REASSOCIATE_AFTER:-3}"
IFUPDOWN_AFTER="${IFUPDOWN_AFTER:-5}"
RFKILL_AFTER="${RFKILL_AFTER:-8}"
FULL_RESET_AFTER="${FULL_RESET_AFTER:-12}"

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
LAST_DISRUPTIVE_ACTION_TIME=0
LAST_FULL_RESET_TIME=0
DISRUPTIVE_WINDOW_START=0
DISRUPTIVE_ACTION_COUNT=0
THRASH_PAUSE_UNTIL=0

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

run_with_timeout() {
    local timeout_seconds="$1"
    local started_at
    local cmd_pid
    shift || return 1

    if [ "$#" -eq 0 ]; then
        return 1
    fi

    if ! [[ "${timeout_seconds}" =~ ^[0-9]+$ ]] || [ "${timeout_seconds}" -le 0 ]; then
        "$@"
        return $?
    fi

    if command_exists timeout; then
        timeout "${timeout_seconds}" "$@"
        return $?
    fi

    "$@" &
    cmd_pid=$!
    started_at=$(date +%s)

    while kill -0 "${cmd_pid}" 2>/dev/null; do
        if [ $(( $(date +%s) - started_at )) -ge "${timeout_seconds}" ]; then
            kill "${cmd_pid}" 2>/dev/null || true
            sleep 1
            kill -9 "${cmd_pid}" 2>/dev/null || true
            wait "${cmd_pid}" 2>/dev/null || true
            logger -t "${LOG_TAG}" -p daemon.warning "Timed out command after ${timeout_seconds}s: $*" 2>/dev/null || true
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: Timed out command after ${timeout_seconds}s: $*" >&2
            return 124
        fi
        notify_watchdog
        sleep 1
    done

    wait "${cmd_pid}"
    return $?
}

sleep_with_watchdog() {
    local total_seconds="${1:-0}"
    local heartbeat_slice="${WATCHDOG_HEARTBEAT_SLICE}"
    local remaining
    local step

    if ! [[ "${total_seconds}" =~ ^[0-9]+$ ]] || [ "${total_seconds}" -lt 0 ]; then
        notify_watchdog
        sleep "${total_seconds}"
        notify_watchdog
        return 0
    fi

    if ! [[ "${heartbeat_slice}" =~ ^[0-9]+$ ]] || [ "${heartbeat_slice}" -lt 1 ]; then
        heartbeat_slice=10
    fi

    remaining="${total_seconds}"
    if [ "${remaining}" -eq 0 ]; then
        notify_watchdog
        return 0
    fi

    while [ "${remaining}" -gt 0 ]; do
        notify_watchdog
        if [ "${remaining}" -lt "${heartbeat_slice}" ]; then
            step="${remaining}"
        else
            step="${heartbeat_slice}"
        fi
        sleep "${step}"
        remaining=$((remaining - step))
    done

    notify_watchdog
}

command_exists() {
    command -v "$1" &>/dev/null
}

is_truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on|y)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

wpa_cli_ok() {
    local output

    command_exists wpa_cli || return 1
    output=$(run_with_timeout "${COMMAND_TIMEOUT_WPA_CLI}" wpa_cli -i "${WIFI_INTERFACE}" "$@" 2>/dev/null || true)
    printf '%s\n' "${output}" | grep -qx 'OK'
}

get_current_wpa_network_id() {
    command_exists wpa_cli || return 1
    run_with_timeout "${COMMAND_TIMEOUT_WPA_CLI}" wpa_cli -i "${WIFI_INTERFACE}" list_networks 2>/dev/null \
        | awk -F '\t' '$0 ~ /\[CURRENT\]/ {print $1; exit}'
}

apply_wpa_stationary_policy() {
    local network_id
    local applied=0

    if ! is_truthy "${DISABLE_WIFI_STEERING}" && ! is_truthy "${DISABLE_WIFI_BGSCAN}"; then
        return 0
    fi
    command_exists wpa_cli || return 0

    network_id=$(get_current_wpa_network_id || true)

    if is_truthy "${DISABLE_WIFI_STEERING}"; then
        # Builds vary: try both common BSS transition knob names and ignore unsupported ones.
        if wpa_cli_ok set bss_transition 0; then
            applied=1
        fi
        if wpa_cli_ok set bss_tm_disabled 1; then
            applied=1
        fi
    fi

    if [ -n "${network_id}" ]; then
        if is_truthy "${DISABLE_WIFI_STEERING}"; then
            if wpa_cli_ok set_network "${network_id}" bss_transition 0; then
                applied=1
            fi
            if wpa_cli_ok set_network "${network_id}" bss_tm_disabled 1; then
                applied=1
            fi
        fi

        if is_truthy "${DISABLE_WIFI_BGSCAN}"; then
            if wpa_cli_ok set_network "${network_id}" bgscan '""'; then
                applied=1
            fi
        fi
    fi

    if [ "${applied}" -eq 1 ]; then
        log_info "Applied wpa_supplicant stationary WiFi policy${network_id:+ to network ${network_id}}"
    else
        log_warn "Could not apply wpa_supplicant stationary WiFi policy; options may be unsupported or no current network is exposed"
    fi
}

apply_nm_stationary_policy() {
    local connection_name

    networkmanager_running || return 0

    if [ -d "/etc/NetworkManager/conf.d" ]; then
        cat > /etc/NetworkManager/conf.d/10-wifi-powersave-off.conf <<EOF
[connection]
wifi.powersave=2
EOF
    fi

    run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli radio wifi on &>/dev/null || true
    run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli device set "${WIFI_INTERFACE}" managed yes &>/dev/null || true
    run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli device set "${WIFI_INTERFACE}" autoconnect yes &>/dev/null || true

    connection_name=$(get_nm_wifi_connection_name || true)
    if [ -z "${connection_name}" ]; then
        log_warn "Could not determine WiFi connection profile for NetworkManager stability policy"
        return 0
    fi

    run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli connection modify "${connection_name}" 802-11-wireless.powersave 2 &>/dev/null || true
    run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli connection modify "${connection_name}" connection.autoconnect yes &>/dev/null || true

    if [ -n "${WIFI_BSSID}" ]; then
        run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli connection modify "${connection_name}" 802-11-wireless.bssid "${WIFI_BSSID}" &>/dev/null || true
    fi
    if [ -n "${WIFI_BAND}" ]; then
        run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli connection modify "${connection_name}" 802-11-wireless.band "${WIFI_BAND}" &>/dev/null || true
    fi
    if [ -n "${WIFI_CHANNEL}" ]; then
        run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli connection modify "${connection_name}" 802-11-wireless.channel "${WIFI_CHANNEL}" &>/dev/null || true
    fi

    log_info "Ensured NetworkManager WiFi stability policy for profile: ${connection_name}"
}

apply_wifi_stationary_policy() {
    if command_exists iw; then
        run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" iw dev "${WIFI_INTERFACE}" set power_save off &>/dev/null || true
    fi

    apply_nm_stationary_policy
    apply_wpa_stationary_policy
}
ensure_state_dir() {
    mkdir -p "${WATCHDOG_STATE_DIR}" 2>/dev/null
}

mark_failure() {
    LAST_FAILURE_REASON="$1"
    LAST_FAILURE_TIME=$(date +%s)
}

enforce_wifi_powersave_off() {
    apply_wifi_stationary_policy
}

apply_recording_safe_recovery_policy() {
    local now
    now=$(date +%s)

    if [ "${THRASH_PAUSE_UNTIL}" -gt "${now}" ]; then
        log_warn "Recovery pacing pause active for $((THRASH_PAUSE_UNTIL - now))s"
        return 1
    fi

    if [ "${DISRUPTIVE_WINDOW_START}" -eq 0 ] || [ $((now - DISRUPTIVE_WINDOW_START)) -ge 3600 ]; then
        DISRUPTIVE_WINDOW_START="${now}"
        DISRUPTIVE_ACTION_COUNT=0
    fi

    if [ "${LAST_DISRUPTIVE_ACTION_TIME}" -gt 0 ] && [ $((now - LAST_DISRUPTIVE_ACTION_TIME)) -lt "${RECOVERY_ACTION_MIN_INTERVAL}" ]; then
        return 1
    fi

    if [ "${DISRUPTIVE_ACTION_COUNT}" -ge "${MAX_DISRUPTIVE_ACTIONS_PER_HOUR}" ]; then
        THRASH_PAUSE_UNTIL=$((now + THRASH_PAUSE_SECONDS))
        log_warn "Disruptive action budget reached (${MAX_DISRUPTIVE_ACTIONS_PER_HOUR}/hr); pausing recovery actions for ${THRASH_PAUSE_SECONDS}s"
        persist_state_if_due
        return 1
    fi

    return 0
}

record_disruptive_action() {
    local action="$1"
    local now
    now=$(date +%s)
    LAST_DISRUPTIVE_ACTION_TIME="${now}"
    DISRUPTIVE_ACTION_COUNT=$((DISRUPTIVE_ACTION_COUNT + 1))
    if [ "${action}" = "full_reset" ]; then
        LAST_FULL_RESET_TIME="${now}"
    fi
    log_warn "Recovery action executed: ${action} (window count: ${DISRUPTIVE_ACTION_COUNT}/${MAX_DISRUPTIVE_ACTIONS_PER_HOUR})"
    persist_state_if_due
}

load_persistent_state() {
    if [ ! -f "${WATCHDOG_STATE_FILE}" ]; then
        return 0
    fi

    while IFS='=' read -r key value; do
        key="${key%$'\r'}"
        value="${value%$'\r'}"
        case "${key}" in
            CONSECUTIVE_WIFI_FAILURES|TOTAL_RECONNECTS|LAST_CONNECTED_TIME|LAST_FAILURE_TIME|LAST_RECOVERY_TIME|LAST_DISRUPTIVE_ACTION_TIME|LAST_FULL_RESET_TIME|DISRUPTIVE_WINDOW_START|DISRUPTIVE_ACTION_COUNT|THRASH_PAUSE_UNTIL)
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
        printf 'LAST_DISRUPTIVE_ACTION_TIME=%s\n' "${LAST_DISRUPTIVE_ACTION_TIME}"
        printf 'LAST_FULL_RESET_TIME=%s\n' "${LAST_FULL_RESET_TIME}"
        printf 'DISRUPTIVE_WINDOW_START=%s\n' "${DISRUPTIVE_WINDOW_START}"
        printf 'DISRUPTIVE_ACTION_COUNT=%s\n' "${DISRUPTIVE_ACTION_COUNT}"
        printf 'THRASH_PAUSE_UNTIL=%s\n' "${THRASH_PAUSE_UNTIL}"
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
    run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli -t -f RUNNING general 2>/dev/null | grep -qx "running"
}

get_nm_wifi_connection_name() {
    if [ -n "${WIFI_CONNECTION_NAME}" ]; then
        echo "${WIFI_CONNECTION_NAME}"
        return 0
    fi

    local active_connection
    active_connection=$(run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli -g GENERAL.CONNECTION device show "${WIFI_INTERFACE}" 2>/dev/null | head -1 || true)
    if [ -n "${active_connection}" ] && [ "${active_connection}" != "--" ]; then
        echo "${active_connection}"
        return 0
    fi

    return 1
}

try_nmcli_reconnect() {
    networkmanager_running || return 1

    if command_exists iw; then
        run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" iw dev "${WIFI_INTERFACE}" set power_save off &>/dev/null || true
    fi

    run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli radio wifi on &>/dev/null || true
    run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli device set "${WIFI_INTERFACE}" managed yes &>/dev/null || true
    run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli device set "${WIFI_INTERFACE}" autoconnect yes &>/dev/null || true

    local connection_name
    connection_name=$(get_nm_wifi_connection_name || true)
    if [ -n "${connection_name}" ]; then
        run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli connection modify "${connection_name}" 802-11-wireless.powersave 2 &>/dev/null || true
        run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli connection modify "${connection_name}" connection.autoconnect yes &>/dev/null || true
        if run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli connection up id "${connection_name}" ifname "${WIFI_INTERFACE}" &>/dev/null; then
            apply_wifi_stationary_policy
            return 0
        fi
    fi

    if run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli device connect "${WIFI_INTERFACE}" &>/dev/null; then
        apply_wifi_stationary_policy
        return 0
    fi

    return 1
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
    run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" ip addr show "${iface}" 2>/dev/null | grep -q "inet "
}

get_interface_ipv4() {
    local iface="$1"
    run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" ip -o -4 addr show dev "${iface}" scope global 2>/dev/null | awk 'NR==1 {split($4, ip, "/"); print ip[1]}'
}

ping_via_interface() {
    local iface="$1"
    local host="$2"
    run_with_timeout "${COMMAND_TIMEOUT_PING}" ping -c "${PING_COUNT}" -W "${PING_TIMEOUT}" -I "${iface}" "$host" &>/dev/null
}

get_gateway_for_interface() {
    local iface="$1"
    run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" ip route show default dev "${iface}" 2>/dev/null | awk '/default/ {print $3}' | head -1
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
        run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" nc -z -w "${TCP_PROBE_TIMEOUT}" -s "${source_ip}" "${CONNECTIVITY_TCP_HOST}" "${CONNECTIVITY_TCP_PORT}" &>/dev/null
        return $?
    fi

    if command_exists timeout; then
        # /dev/tcp fallback is less strict because it cannot bind to a specific source IP.
        run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" timeout "${TCP_PROBE_TIMEOUT}" bash -c "exec 3<>/dev/tcp/${CONNECTIVITY_TCP_HOST}/${CONNECTIVITY_TCP_PORT}" &>/dev/null
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
        run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" curl --silent --show-error --fail \
            --connect-timeout "${HTTP_PROBE_TIMEOUT}" \
            --max-time "${HTTP_PROBE_TIMEOUT}" \
            --interface "${iface}" \
            --output /dev/null \
            "${CONNECTIVITY_HTTP_URL}" &>/dev/null
        return $?
    fi

    source_ip=$(get_interface_ipv4 "${iface}")
    if [ -n "${source_ip}" ] && command_exists wget; then
        run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" wget --quiet --spider \
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
        notify_watchdog
        if ping_via_interface "$iface" "$gw"; then
            return 0
        fi
    fi

    # Prefer configured application-level probes before public ICMP targets.
    # This avoids forcing reconnects on networks where ping is flaky or deprioritized.
    notify_watchdog
    if probe_non_icmp_connectivity "${iface}"; then
        return 0
    fi

    # Try fallback targets
    for target in "${PING_TARGETS[@]}"; do
        notify_watchdog
        if ping_via_interface "$iface" "$target"; then
            return 0
        fi
    done

    return 1
}

# WiFi-specific checks
wifi_is_associated() {
    local ssid

    if command_exists iwgetid; then
        ssid=$(run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" iwgetid "${WIFI_INTERFACE}" -r 2>/dev/null || true)
        if [ -n "${ssid}" ]; then
            return 0
        fi
    fi

    if command_exists iw && run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" iw dev "${WIFI_INTERFACE}" link 2>/dev/null | grep -q '^Connected to '; then
        return 0
    fi

    if networkmanager_running; then
        if run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep -q "^${WIFI_INTERFACE}:connected$"; then
            return 0
        fi
    fi

    if command_exists wpa_cli; then
        if run_with_timeout "${COMMAND_TIMEOUT_WPA_CLI}" wpa_cli -i "${WIFI_INTERFACE}" status 2>/dev/null | grep -q '^wpa_state=COMPLETED$'; then
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
    apply_recording_safe_recovery_policy || return 0

    if try_nmcli_reconnect; then
        log_info "Escalation 1/${FULL_RESET_AFTER}: nmcli reconnect"
        mqtt_report "reassociate" "Attempting NetworkManager reconnect"
    else
        log_info "Escalation 1/${FULL_RESET_AFTER}: wpa_cli reassociate"
        mqtt_report "reassociate" "Attempting wpa_cli reassociate"

        run_with_timeout "${COMMAND_TIMEOUT_WPA_CLI}" wpa_cli -i "${WIFI_INTERFACE}" reassociate &>/dev/null || true
        run_with_timeout "${COMMAND_TIMEOUT_WPA_CLI}" wpa_cli -i "${WIFI_INTERFACE}" reconfigure &>/dev/null || true
    fi

    record_disruptive_action "reassociate"
    sleep_with_watchdog "${COOLDOWN_SHORT}"
}

do_ifupdown() {
    apply_recording_safe_recovery_policy || return 0

    log_info "Escalation 2/${FULL_RESET_AFTER}: Bouncing interface ${WIFI_INTERFACE}"
    mqtt_report "ifupdown" "Bouncing WiFi interface"

    if try_nmcli_reconnect; then
        :
    elif command -v ifdown &>/dev/null; then
        run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" ifdown "${WIFI_INTERFACE}" 2>/dev/null || true
        sleep_with_watchdog 2
        run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" ifup "${WIFI_INTERFACE}" 2>/dev/null || true
    else
        run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" ip link set "${WIFI_INTERFACE}" down 2>/dev/null || true
        sleep_with_watchdog 2
        run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" ip link set "${WIFI_INTERFACE}" up 2>/dev/null || true
    fi

    record_disruptive_action "ifupdown"
    sleep_with_watchdog "${COOLDOWN_MEDIUM}"
    request_dhcp
}

do_rfkill_cycle() {
    apply_recording_safe_recovery_policy || return 0

    log_info "Escalation 3/${FULL_RESET_AFTER}: rfkill power-cycle"
    mqtt_report "rfkill" "Power-cycling WiFi radio"

    if networkmanager_running; then
        run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli radio wifi off &>/dev/null || true
        sleep_with_watchdog 3
        run_with_timeout "${COMMAND_TIMEOUT_NMCLI}" nmcli radio wifi on &>/dev/null || true
        sleep_with_watchdog 5
        try_nmcli_reconnect || true
    elif command -v rfkill &>/dev/null; then
        run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" rfkill block wifi 2>/dev/null || true
        sleep_with_watchdog 3
        run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" rfkill unblock wifi 2>/dev/null || true
        sleep_with_watchdog 5
        run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" ip link set "${WIFI_INTERFACE}" up 2>/dev/null || true
    else
        log_warn "rfkill not available, skipping"
    fi

    record_disruptive_action "rfkill"
    sleep_with_watchdog "${COOLDOWN_MEDIUM}"
    request_dhcp
}

do_full_reset() {
    local now
    now=$(date +%s)

    apply_recording_safe_recovery_policy || return 0

    if [ "${LAST_FULL_RESET_TIME}" -gt 0 ] && [ $((now - LAST_FULL_RESET_TIME)) -lt "${FULL_RESET_MIN_INTERVAL}" ]; then
        log_warn "Escalation 5/${FULL_RESET_AFTER}: full reset deferred (min interval ${FULL_RESET_MIN_INTERVAL}s)"
        return 0
    fi

    log_info "Escalation 5/${FULL_RESET_AFTER}: Full interface reset"
    mqtt_report "full_reset" "Full WiFi interface teardown and rebuild"

    run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" ip addr flush dev "${WIFI_INTERFACE}" 2>/dev/null || true
    run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" ip route flush dev "${WIFI_INTERFACE}" 2>/dev/null || true
    run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" ip link set "${WIFI_INTERFACE}" down 2>/dev/null || true
    sleep_with_watchdog 3
    run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" ip link set "${WIFI_INTERFACE}" up 2>/dev/null || true
    sleep_with_watchdog 5
    if ! try_nmcli_reconnect; then
        run_with_timeout "${COMMAND_TIMEOUT_WPA_CLI}" wpa_cli -i "${WIFI_INTERFACE}" reconfigure &>/dev/null || true
    fi
    sleep_with_watchdog 5
    request_dhcp
    record_disruptive_action "full_reset"
    sleep_with_watchdog "${COOLDOWN_LONG}"
}

request_dhcp() {
    if networkmanager_running; then
        return 0
    fi

    if command -v dhclient &>/dev/null; then
        run_with_timeout "${COMMAND_TIMEOUT_DHCP}" dhclient -r "${WIFI_INTERFACE}" 2>/dev/null || true
        run_with_timeout "${COMMAND_TIMEOUT_DHCP}" dhclient "${WIFI_INTERFACE}" 2>/dev/null || true
    elif command -v dhcpcd &>/dev/null; then
        run_with_timeout "${COMMAND_TIMEOUT_DHCP}" dhcpcd -n "${WIFI_INTERFACE}" 2>/dev/null || true
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

    # Pick escalation level without cycling to avoid recovery thrash.
    local level="${CONSECUTIVE_WIFI_FAILURES}"

    if [ "$level" -ge "${FULL_RESET_AFTER}" ]; then
        do_full_reset
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
    run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" ip link set "${WIFI_INTERFACE}" up 2>/dev/null || true

    # Make sure rfkill is not blocking it.
    if command_exists rfkill; then
        run_with_timeout "${COMMAND_TIMEOUT_DEFAULT}" rfkill unblock wifi 2>/dev/null || true
    fi

    # Ask wpa_supplicant (or NetworkManager) to connect.
    if ! try_nmcli_reconnect; then
        run_with_timeout "${COMMAND_TIMEOUT_WPA_CLI}" wpa_cli -i "${WIFI_INTERFACE}" reconfigure &>/dev/null || true
        run_with_timeout "${COMMAND_TIMEOUT_WPA_CLI}" wpa_cli -i "${WIFI_INTERFACE}" reassociate &>/dev/null || true
        apply_wifi_stationary_policy
    fi

    # Wait for association and request DHCP.
    sleep_with_watchdog 10
    request_dhcp
    sleep_with_watchdog 5

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
enforce_wifi_powersave_off

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

log_info "========================================="
log_info "WiFi Watchdog (Wired-Aware) starting"
log_info "WiFi interface: ${WIFI_INTERFACE}"
log_info "Wired interface: ${WIRED_INTERFACE}"
log_info "========================================="
log_info "Check intervals: wifi_primary=${CHECK_INTERVAL_WIFI_PRIMARY}s, wired_ok=${CHECK_INTERVAL_WIRED_OK}s, wired_dropped=${CHECK_INTERVAL_WIRED_JUST_DROPPED}s"
log_info "Escalation: reassociate@${REASSOCIATE_AFTER}, ifupdown@${IFUPDOWN_AFTER}, rfkill@${RFKILL_AFTER}, full_reset@${FULL_RESET_AFTER}"
log_info "Always-recording mode: ${ALWAYS_RECORDING_MODE} (network service restarts disabled: yes)"
log_info "Recovery pacing: min_interval=${RECOVERY_ACTION_MIN_INTERVAL}s, full_reset_min_interval=${FULL_RESET_MIN_INTERVAL}s, max_disruptive_per_hour=${MAX_DISRUPTIVE_ACTIONS_PER_HOUR}, pause=${THRASH_PAUSE_SECONDS}s"
log_info "State file: ${WATCHDOG_STATE_FILE} (total reconnects: ${TOTAL_RECONNECTS}, consecutive failures: ${CONSECUTIVE_WIFI_FAILURES})"
if [ -n "${WATCHDOG_USEC:-}" ]; then
    log_info "systemd watchdog interval: $((WATCHDOG_USEC / 1000000))s"
else
    log_warn "systemd watchdog interval not provided (WATCHDOG_USEC unset)"
fi
mqtt_report "started" "WiFi watchdog started (wired-aware mode)"

# Give the system a moment to bring up networking on boot
sleep_with_watchdog 10

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
    sleep_with_watchdog "${local_interval}"
done
