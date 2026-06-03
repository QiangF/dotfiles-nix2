#!/usr/bin/env bash
# Waybar custom/vpn module — Zscaler ZTNA indicator + click-to-toggle.
#
# Status is intentionally LIGHTWEIGHT (no `docker exec`, safe to poll every few
# seconds): the synthetic route 100.64.0.0/16 via docker0 exists exactly when
# `zscaler` has integrated the host, i.e. the VPN is actually carrying traffic.
#   * on         — host integrated (connected)
#   * connecting — container up but not integrated yet (finish the Okta login)
#   * off        — not running
# Click toggles: down if the container is running, otherwise up (which opens
# the Okta login in your browser).
NAME=zscaler
SYN_NET=100.64.0.0/16
BR=docker0

_container_up() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; }
_integrated()   { ip route show "$SYN_NET" 2>/dev/null | grep -q "$BR"; }

# on-click: a single arg ("toggle") flips the connection.
if [ $# -eq 1 ]; then
  if _container_up; then
    zscaler down >/tmp/zsc-waybar.log 2>&1 &
  else
    zscaler up >/tmp/zsc-waybar.log 2>&1 &
  fi
  disown
  exit 0
fi

# polled status
if _integrated; then
  echo '{"class": "on", "tooltip": "Zscaler: connected (host integrated) — click to disconnect"}'
elif _container_up; then
  echo '{"class": "connecting", "tooltip": "Zscaler: connecting — finish the Okta login in your browser"}'
else
  echo '{"class": "off", "tooltip": "Zscaler: disconnected — click to connect"}'
fi
