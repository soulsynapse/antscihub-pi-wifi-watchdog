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
4. Restart network services (prefers `NetworkManager` when active)
5. Full interface reset and reconnect

When `NetworkManager` is running, watchdog prefers `nmcli` operations and avoids forcing legacy DHCP renewals.

## Configuration

The script supports these key environment variables:

- `WIFI_INTERFACE` (default: `wlan0`)
- `WIRED_INTERFACE` (default: `eth0`)
- `WIFI_CONNECTION_NAME` (default: empty)

Set `WIFI_CONNECTION_NAME` when you want reconnect attempts to target a specific saved NM profile (for example enterprise WiFi like `asu`).

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
