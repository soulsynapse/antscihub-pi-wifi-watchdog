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
#   1. wpa_cli reassociate
#   2. ifdown/ifup wlan0
#   3. rfkill power-cycle
#   4. Restart networking services
#   5. Full interface reset
#   6. Reboot (nuclear)
# ============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
WIFI_INTERFACE="${WIFI_INTERFACE:-wlan0}"
WIRED_INTERFACE="${WIRED_INTERFACE:-eth0}"

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
REBOOT_AFTER=20

# Cooldowns after escalation actions
COOLDOWN_SHORT=10
COOLDOWN_MEDIUM=20
COOLDOWN_LONG=30

# Logging
LOG_TAG="wifi-watchdog"
DEVICE_ID="${DEVICE_ID:-$(hostname -s 2>/dev/null || echo unknown-device)}"
MQTT_TOPIC_META="${MQTT_TOPIC_META:-fleet/services/${DEVICE_ID}/meta}"

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
CONSECUTIVE_WIFI_FAILURES=0
TOTAL_RECONNECTS=0
LAST_CONNECTED_TIME=$(date +%s)
STARTUP_TIME=$(date +%s)
LAST_STATUS_REPORT=0
STATUS_REPORT_INTERVAL=300  # every 5 minutes

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
        fleet-publish --json "{\"event\":\"${event}\",\"service\":\"wifi-watchdog\",\"device_id\":\"${DEVICE_ID}\",\"timestamp\":$(date +%s),\"message\":\"${message}\",\"mode\":\"${MODE}\",\"consecutive_failures\":${CONSECUTIVE_WIFI_FAILURES},\"total_reconnects\":${TOTAL_RECONNECTS},\"wifi_interface\":\"${WIFI_INTERFACE}\",\"wired_interface\":\"${WIRED_INTERFACE}\"}" \
            --topic "${MQTT_TOPIC_META}" --no-encrypt 2>/dev/null || true
    fi
}

notify_watchdog() {
    if [ -n "${WATCHDOG_USEC:-}" ]; then
        systemd-notify WATCHDOG=1 2>/dev/null || true
    fi
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

ping_via_interface() {
    local iface="$1"
    local host="$2"
    ping -c "${PING_COUNT}" -W "${PING_TIMEOUT}" -I "${iface}" "$host" &>/dev/null
}

get_gateway_for_interface() {
    local iface="$1"
    ip route show default dev "${iface}" 2>/dev/null | awk '/default/ {print $3}' | head -1
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

    return 1
}

# WiFi-specific checks
wifi_is_associated() {
    local ssid
    ssid=$(iwgetid "${WIFI_INTERFACE}" -r 2>/dev/null || true)
    [ -n "$ssid" ]
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
        fi
        MODE="wired_ok"
        WIRED_WAS_UP=true
        WIRED_JUST_DROPPED=false

        # Reset WiFi failure counter — we have connectivity via wired
        if [ "${CONSECUTIVE_WIFI_FAILURES}" -gt 0 ]; then
            log_info "Clearing WiFi failure counter (wired is healthy)"
            CONSECUTIVE_WIFI_FAILURES=0
        fi
    else
        # Wired is down
        if [ "$WIRED_WAS_UP" = true ]; then
            # Transition: wired just dropped
            log_warn "Wired connection (${WIRED_INTERFACE}) DROPPED — switching to aggressive WiFi mode"
            mqtt_report "wired_down" "Wired connection lost, ensuring WiFi is active"
            WIRED_JUST_DROPPED=true
            WIRED_WAS_UP=false
        fi
        MODE="wifi_primary"
    fi
}

# ---------------------------------------------------------------------------
# WiFi recovery actions (escalation ladder)
# ---------------------------------------------------------------------------

do_reassociate() {
    log_info "Escalation 1/${REBOOT_AFTER}: wpa_cli reassociate"
    mqtt_report "reassociate" "Attempting wpa_cli reassociate"

    wpa_cli -i "${WIFI_INTERFACE}" reassociate &>/dev/null || true
    wpa_cli -i "${WIFI_INTERFACE}" reconfigure &>/dev/null || true

    sleep "${COOLDOWN_SHORT}"
}

do_ifupdown() {
    log_info "Escalation 2/${REBOOT_AFTER}: Bouncing interface ${WIFI_INTERFACE}"
    mqtt_report "ifupdown" "Bouncing WiFi interface"

    if command -v ifdown &>/dev/null; then
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
    log_info "Escalation 3/${REBOOT_AFTER}: rfkill power-cycle"
    mqtt_report "rfkill" "Power-cycling WiFi radio"

    if command -v rfkill &>/dev/null; then
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
    log_info "Escalation 4/${REBOOT_AFTER}: Restarting networking services"
    mqtt_report "restart_services" "Restarting wpa_supplicant, dhcpcd, networking"

    systemctl restart wpa_supplicant 2>/dev/null || true
    sleep 3

    if systemctl list-units --type=service --all 2>/dev/null | grep -q dhcpcd; then
        systemctl restart dhcpcd 2>/dev/null || true
        sleep 5
    fi

    if systemctl list-units --type=service --all 2>/dev/null | grep -q NetworkManager; then
        systemctl restart NetworkManager 2>/dev/null || true
        sleep 5
    fi

    systemctl restart networking 2>/dev/null || true
    sleep "${COOLDOWN_LONG}"
}

do_full_reset() {
    log_info "Escalation 5/${REBOOT_AFTER}: Full interface reset"
    mqtt_report "full_reset" "Full WiFi interface teardown and rebuild"

    ip addr flush dev "${WIFI_INTERFACE}" 2>/dev/null || true
    ip route flush dev "${WIFI_INTERFACE}" 2>/dev/null || true
    ip link set "${WIFI_INTERFACE}" down 2>/dev/null || true
    sleep 3
    ip link set "${WIFI_INTERFACE}" up 2>/dev/null || true
    sleep 5
    wpa_cli -i "${WIFI_INTERFACE}" reconfigure &>/dev/null || true
    sleep 5
    request_dhcp
    sleep "${COOLDOWN_LONG}"
}

do_reboot() {
    log_error "Escalation 6/${REBOOT_AFTER}: REBOOTING after ${CONSECUTIVE_WIFI_FAILURES} consecutive WiFi failures (no wired fallback)"
    mqtt_report "reboot" "Rebooting Pi — no connectivity for too long"
    sleep 3
    sync
    reboot
}

request_dhcp() {
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
    log_warn "WiFi check failed (consecutive: ${CONSECUTIVE_WIFI_FAILURES}, mode: ${MODE})"

    if [ "${CONSECUTIVE_WIFI_FAILURES}" -ge "${REBOOT_AFTER}" ]; then
        do_reboot
    elif [ "${CONSECUTIVE_WIFI_FAILURES}" -ge "${FULL_RESET_AFTER}" ]; then
        do_full_reset
    elif [ "${CONSECUTIVE_WIFI_FAILURES}" -ge "${RESTART_SERVICES_AFTER}" ]; then
        do_restart_services
    elif [ "${CONSECUTIVE_WIFI_FAILURES}" -ge "${RFKILL_AFTER}" ]; then
        do_rfkill_cycle
    elif [ "${CONSECUTIVE_WIFI_FAILURES}" -ge "${IFUPDOWN_AFTER}" ]; then
        do_ifupdown
    elif [ "${CONSECUTIVE_WIFI_FAILURES}" -ge "${REASSOCIATE_AFTER}" ];     then
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
    fi
    LAST_CONNECTED_TIME=$(date +%s)
}

# ---------------------------------------------------------------------------
# Ensure WiFi is at least up (even if wired is primary)
# Called when wired drops to make sure WiFi is ready to take over
# ---------------------------------------------------------------------------

ensure_wifi_up() {
    # If WiFi interface doesn't exist, nothing we can do
    if ! interface_exists "${WIFI_INTERFACE}"; then
        log_error "WiFi interface ${WIFI_INTERFACE} does not exist — cannot failover"
        return 1
    fi

    # If WiFi is already connected, great
    if check_wifi_connectivity; then
        return 0
    fi

    log_info "WiFi not connected — bringing it up for failover"
    mqtt_report "failover_start" "Wired down, activating WiFi"

    # Make sure the interface is up
    ip link set "${WIFI_INTERFACE}" up 2>/dev/null || true

    # Make sure rfkill isn't blocking it
    if command -v rfkill &>/dev/null; then
        rfkill unblock wifi 2>/dev/null || true
    fi

    # Ask wpa_supplicant to connect
    wpa_cli -i "${WIFI_INTERFACE}" reconfigure &>/dev/null || true
    wpa_cli -i "${WIFI_INTERFACE}" reassociate &>/dev/null || true

    # Wait for association
    sleep 10

    # Request DHCP
    request_dhcp

    sleep 5

    # Check if it worked
    if check_wifi_connectivity; then
        log_info "WiFi failover successful"
        mqtt_report "failover_ok" "WiFi is now active as primary connection"
        return 0
    else
        log_warn "WiFi failover — not connected yet, entering escalation"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Status reporting
# ---------------------------------------------------------------------------

maybe_report_status() {
    local now
    now=$(date +%s)
    if (( now - LAST_STATUS_REPORT >= STATUS_REPORT_INTERVAL )); then
        LAST_STATUS_REPORT=$now

        local wifi_ssid wifi_ip wifi_signal wired_ip wired_carrier uptime_sec
        wifi_ssid=$(iwgetid "${WIFI_INTERFACE}" -r 2>/dev/null || echo "none")
        wifi_ip=$(ip -4 addr show "${WIFI_INTERFACE}" 2>/dev/null | awk '/inet / {print $2}' | head -1 || echo "none")
        wifi_signal=$(iwconfig "${WIFI_INTERFACE}" 2>/dev/null | grep -o 'Signal level=[^ ]*' | cut -d= -f2 || echo "unknown")
        wired_ip=$(ip -4 addr show "${WIRED_INTERFACE}" 2>/dev/null | awk '/inet / {print $2}' | head -1 || echo "none")
        wired_carrier=$(cat "/sys/class/net/${WIRED_INTERFACE}/carrier" 2>/dev/null || echo "0")
        uptime_sec=$(( now - STARTUP_TIME ))

        log_info "Status: mode=${MODE} wifi_ssid=${wifi_ssid} wifi_ip=${wifi_ip} wifi_signal=${wifi_signal} wired_ip=${wired_ip} wired_carrier=${wired_carrier} uptime=${uptime_sec}s reconnects=${TOTAL_RECONNECTS} failures=${CONSECUTIVE_WIFI_FAILURES}"

        if command -v fleet-publish &>/dev/null; then
            local healthy_json unhealthy_json
            if [ "${MODE}" = "wired_ok" ] || check_wifi_connectivity; then
                healthy_json='["wifi-watchdog","connectivity"]'
                unhealthy_json='[]'
            else
                healthy_json='["wifi-watchdog"]'
                unhealthy_json='["connectivity"]'
            fi

            fleet-publish --json "{
                \"event\": \"status\",
                \"service\": \"wifi-watchdog\",
                \"device_id\": \"${DEVICE_ID}\",
                \"timestamp\": $(date +%s),
                \"managed\": [\"wifi-watchdog\", \"connectivity\"],
                \"healthy\": ${healthy_json},
                \"unhealthy\": ${unhealthy_json},
                \"mode\": \"${MODE}\",
                \"wifi\": {
                    \"interface\": \"${WIFI_INTERFACE}\",
                    \"ssid\": \"${wifi_ssid}\",
                    \"ip\": \"${wifi_ip}\",
                    \"signal\": \"${wifi_signal}\"
                },
                \"wired\": {
                    \"interface\": \"${WIRED_INTERFACE}\",
                    \"ip\": \"${wired_ip}\",
                    \"carrier\": \"${wired_carrier}\"
                },
                \"uptime_sec\": ${uptime_sec},
                \"total_reconnects\": ${TOTAL_RECONNECTS},
                \"consecutive_failures\": ${CONSECUTIVE_WIFI_FAILURES}
            }" --topic "${MQTT_TOPIC_META}" --no-encrypt 2>/dev/null || true
        fi
    fi
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

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

log_info "========================================="
log_info "WiFi Watchdog (Wired-Aware) starting"
log_info "WiFi interface: ${WIFI_INTERFACE}"
log_info "Wired interface: ${WIRED_INTERFACE}"
log_info "========================================="
log_info "Check intervals: wifi_primary=${CHECK_INTERVAL_WIFI_PRIMARY}s, wired_ok=${CHECK_INTERVAL_WIRED_OK}s, wired_dropped=${CHECK_INTERVAL_WIRED_JUST_DROPPED}s"
log_info "Escalation: reassociate@${REASSOCIATE_AFTER}, ifupdown@${IFUPDOWN_AFTER}, rfkill@${RFKILL_AFTER}, restart@${RESTART_SERVICES_AFTER}, full_reset@${FULL_RESET_AFTER}, reboot@${REBOOT_AFTER}"
mqtt_report "started" "WiFi watchdog started (wired-aware mode)"

# Give the system a moment to bring up networking on boot
sleep 10

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

while true; do
    notify_watchdog

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
    # Step 3: Periodic status report
    # -----------------------------------------------------------------------
    maybe_report_status
    notify_watchdog

    # -----------------------------------------------------------------------
    # Step 4: Sleep based on current state
    # -----------------------------------------------------------------------
    local_interval=$(get_check_interval)
    sleep "${local_interval}"
done