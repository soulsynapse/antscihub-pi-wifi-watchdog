# WiFi Watchdog Module

This repository contains the `wifi-watchdog` module for AntSciHub Raspberry Pi deployments.

Canonical repository:

- https://github.com/soulsynapse/antscihub-pi-wifi-watchdog

## What It Does

`wifi-watchdog.sh` keeps the Pi online by continuously checking connectivity and recovering WiFi when needed.

- If wired (`eth0`) is healthy, watchdog stays relaxed.
- If wired drops, watchdog immediately treats WiFi (`wlan0`) as critical and starts aggressive recovery.
- If wired is never present, watchdog always runs in WiFi-primary mode.

## Reconnect Logic

The recovery ladder is now NetworkManager-aware.

1. `nmcli` reconnect (fallback to `wpa_cli` reassociate/reconfigure)
2. Interface bounce (tries `nmcli` first, then `ifdown/ifup` or `ip link`)
3. Radio power cycle (`nmcli radio wifi off/on` or `rfkill`)
4. Full interface reset and reconnect

When `NetworkManager` is running, watchdog prefers `nmcli` operations and avoids forcing legacy DHCP renewals.

## Configuration

The script supports these key environment variables:

- `WIFI_INTERFACE` (default: `wlan0`)
- `WIRED_INTERFACE` (default: `eth0`)
- `WIFI_CONNECTION_NAME` (default: empty)
- `CONNECTIVITY_HTTP_URL` (default: empty, optional non-ICMP probe)
- `CONNECTIVITY_TCP_HOST` (default: empty, optional non-ICMP probe)
- `CONNECTIVITY_TCP_PORT` (default: `443`)
- `DISABLE_WIFI_STEERING` (default: `true`)
- `DISABLE_WIFI_BGSCAN` (default: `true`)
- `WIFI_BSSID` (default: empty, optional fixed AP BSSID)
- `WIFI_BAND` (default: empty, optional NetworkManager band)
- `WIFI_CHANNEL` (default: empty, optional NetworkManager channel)
- `REASSOCIATE_AFTER` (default: `3`)
- `IFUPDOWN_AFTER` (default: `5`)
- `RFKILL_AFTER` (default: `8`)
- `FULL_RESET_AFTER` (default: `12`)
- `RECOVERY_ACTION_MIN_INTERVAL` (default: `45`)
- `FULL_RESET_MIN_INTERVAL` (default: `180`)
- `MAX_DISRUPTIVE_ACTIONS_PER_HOUR` (default: `12`)
- `THRASH_PAUSE_SECONDS` (default: `300`)
- `WATCHDOG_HEARTBEAT_SLICE` (default: `10`)
- `COMMAND_TIMEOUT_DEFAULT` (default: `25`)
- `COMMAND_TIMEOUT_PING` (default: `15`)
- `COMMAND_TIMEOUT_DHCP` (default: `30`)
- `COMMAND_TIMEOUT_NMCLI` (default: `20`)
- `COMMAND_TIMEOUT_WPA_CLI` (default: `15`)
- `WATCHDOG_STATE_FILE` (default: `/var/lib/wifi-watchdog/state.env`)
- `SINGLETON_LOCK_FILE` (default: `/run/wifi-watchdog.lock`)

Set `WIFI_CONNECTION_NAME` when you want reconnect attempts to target a specific saved NM profile (for example enterprise WiFi like `asu`).

If your network blocks, delays, or deprioritizes ICMP, set at least one of `CONNECTIVITY_HTTP_URL` or `CONNECTIVITY_TCP_HOST` to reduce false recovery escalations. Configured HTTP/TCP probes are tried before public ping targets.

By default, watchdog treats Pis as stationary WiFi clients: it disables WiFi power save, asks `wpa_supplicant` to suppress BSS transition steering when supported (`bss_transition=0` / `bss_tm_disabled=1`), disables background scanning (`bgscan ""`), and avoids `nmcli device reapply` because it can churn DHCP on active links.

Optional `WIFI_BSSID`, `WIFI_BAND`, and `WIFI_CHANNEL` values can pin a deployment to a known AP or band, but they are empty by default so a normal push/install applies the safer steering policy without requiring systemd drop-ins.

## Runtime Safeguards

- Startup preflight validates required commands (`ip`, `ping`) and logs optional capability availability.
- A singleton lock prevents concurrent watchdog processes.
- Recovery counters and timestamps persist across restarts in the state file.
- Anti-thrash pacing limits disruptive recovery actions and adds a temporary pause if the action budget is exceeded.
- Watchdog always assumes recordings are active, so it skips network service restarts and only performs WiFi-scoped recovery actions.
- Long waits are chunked with periodic `systemd` watchdog heartbeats to avoid watchdog timeouts during recovery cooldowns.
- Recovery commands are timeout-bounded to reduce hangs from stuck WiFi/SDIO stack operations (`timeout` is used when available, with a watchdog-aware fallback timer otherwise).

## Diagnostics Report

After install, use this command on the Pi:

```bash
watchdog report
```

It writes a concise summary report to:

- `~/Desktop/5-UPLOAD/diagnostics`

Filename format:

- `watchdog_report_YYYY-MM-DD_T-HH-MM-SS__(hostname).txt`

The report includes:

- Service state and restart counters
- Recent down/failure events
- Recent reconnect/recovery events
- Recent watchdog recovery actions
- Compact network snapshot for `eth0` and `wlan0`
- Recent watchdog log tail (bounded)

## Enterprise WiFi (NetworkManager) Notes

If your connection profile was created with `nmcli`, make sure autoconnect is enabled:

```bash
sudo nmcli connection modify "asu" connection.autoconnect yes
sudo nmcli device set wlan0 autoconnect yes
```

## Module Location

This module is intended to live at:

- `~/Desktop/3-SYSTEM/wifi-watchdog`

## Managed Services Module Listing

This module is listed as part of:

- https://github.com/soulsynapse/antscihub-pi-service-manager
