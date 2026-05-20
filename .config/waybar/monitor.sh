#!/usr/bin/env bash
# Waybar custom/monitor module - manage external display on Hyprland.
#   no args          : emit JSON state for waybar (hidden when no external).
#   `toggle`         : flip mirror <-> extend on the first external monitor.
#   `reapply-mirror` : re-issue the mirror config (used to clear stale
#                      framebuffer borders that appear on initial hot-plug)
#                      AND set the primary panel to MIRROR_MODE so the
#                      mirror is 1:1 (no letterboxing on the external).
#   `restore-native` : reset the primary panel to its panel-native (preferred)
#                      mode. Used on monitor unplug or extend-mode entry.
#   `daemon`         : long-running listener on Hyprland's socket2 that
#                      runs `reapply-mirror` on every monitor hot-plug and
#                      `restore-native` on every monitor removal. Started
#                      from hyprland.conf via `exec-once`.

set -u

PRIMARY="eDP-1"
# Everything after the mode field of the eDP-1 monitor line: position, scale,
# bitdepth. Must match hyprland.conf for `restore-native` to fully match the
# config-defined state.
PRIMARY_TAIL="0x0,1.2,bitdepth,8"
# Mode forced on the primary while mirroring so the external display sees a
# 1:1 frame (matches the Dell P2719H's preferred resolution).
MIRROR_MODE="1920x1080@60"
ICON="󰍺"

# Parse `hyprctl monitors all` text output.
# `all` is required because mirrored monitors are hidden from plain
# `hyprctl monitors`. Each block starts with: "Monitor <name> (ID N):"
# Inside it we look for a line like: "    mirrorOf: <value>" — value is "none"
# when not mirroring, otherwise the source monitor's ID or name.
mapfile -t MON_LINES < <(hyprctl monitors all 2>/dev/null)

current=""
declare -A MIRROR_OF=()
ORDER=()
for line in "${MON_LINES[@]}"; do
    if [[ $line =~ ^Monitor[[:space:]]+([^[:space:]]+)[[:space:]]+\(ID ]]; then
        current="${BASH_REMATCH[1]}"
        ORDER+=("$current")
        MIRROR_OF["$current"]="none"
    elif [[ -n $current ]]; then
        if [[ $line =~ ^[[:space:]]*mirrorOf:[[:space:]]*(.+)$ ]]; then
            MIRROR_OF["$current"]="${BASH_REMATCH[1]}"
        elif [[ $line =~ ^[[:space:]]*mirror[[:space:]]+of:[[:space:]]*(.+)$ ]]; then
            MIRROR_OF["$current"]="${BASH_REMATCH[1]}"
        fi
    fi
done

# Pick the first monitor whose name differs from the primary panel.
EXTERNAL=""
for m in "${ORDER[@]}"; do
    if [[ $m != "$PRIMARY" ]]; then
        EXTERNAL="$m"
        break
    fi
done

is_mirroring() {
    local v="${MIRROR_OF[$1]:-none}"
    [[ -n $v && $v != "none" ]]
}

# Force the primary panel into the mirror-friendly mode so mirroring an
# external display whose preferred resolution is MIRROR_MODE is 1:1.
set_primary_mirror_mode() {
    hyprctl keyword monitor "${PRIMARY},${MIRROR_MODE},${PRIMARY_TAIL}" >/dev/null
}

# Restore the primary panel to its panel-native (preferred) mode.
set_primary_native_mode() {
    hyprctl keyword monitor "${PRIMARY},preferred,${PRIMARY_TAIL}" >/dev/null
}

if [[ "${1:-}" == "daemon" ]]; then
    # Listen for Hyprland monitor hot-plug events and re-apply mirror
    # afterwards. This works around a Hyprland glitch where the initial
    # mirror set up by the catch-all `monitor=` rule leaves stale framebuffer
    # content in the border regions of the larger display; re-issuing the
    # same `hyprctl keyword monitor` (what `toggle` already does) clears it.
    SIGNATURE="${HYPRLAND_INSTANCE_SIGNATURE:-}"
    SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/${SIGNATURE}/.socket2.sock"
    if [[ -z $SIGNATURE || ! -S $SOCKET ]]; then
        echo "monitor.sh daemon: hyprland socket2 not available ($SOCKET)" >&2
        exit 1
    fi

    # Cover the case where Hyprland was started with a monitor already
    # attached: the catch-all rule fires before we exist, so no
    # `monitoradded` event reaches us for that initial output.
    ( sleep 1 && "$0" reapply-mirror ) &

    # Event loop. nc dies if the socket goes away (e.g. Hyprland restart);
    # retry while the socket still exists. We deliberately only react to
    # add / remove events and NOT `monitorlayoutchanged` — our own actions
    # fire that and would create a loop.
    while [[ -S $SOCKET ]]; do
        while IFS= read -r line; do
            case $line in
                monitoraddedv2\>\>*|monitoradded\>\>*)
                    ( sleep 0.5 && "$0" reapply-mirror ) &
                    ;;
                monitorremovedv2\>\>*|monitorremoved\>\>*)
                    ( sleep 0.5 && "$0" restore-native ) &
                    ;;
            esac
        done < <(nc -U "$SOCKET" 2>/dev/null)
        sleep 1
    done
    exit 0
fi

if [[ "${1:-}" == "reapply-mirror" ]]; then
    # No-op when no external is connected, or when it is currently extended
    # (we don't want to undo the user's manual `toggle` to extend).
    if [[ -n $EXTERNAL ]] && is_mirroring "$EXTERNAL"; then
        # Match modes first so the mirror is 1:1, then re-issue the mirror.
        set_primary_mirror_mode
        hyprctl keyword monitor "${EXTERNAL},preferred,auto,1,mirror,${PRIMARY}" >/dev/null
    fi
    exit 0
fi

if [[ "${1:-}" == "restore-native" ]]; then
    set_primary_native_mode
    exit 0
fi

if [[ "${1:-}" == "toggle" ]]; then
    if [[ -z $EXTERNAL ]]; then
        if command -v notify-send >/dev/null 2>&1; then
            notify-send -t 2500 "Monitor" "No external display connected"
        fi
        exit 0
    fi
    if is_mirroring "$EXTERNAL"; then
        # Mirror -> Extend: break the mirror first, then restore the primary
        # to its native mode (no need to keep it down at MIRROR_MODE).
        hyprctl keyword monitor "${EXTERNAL},preferred,auto,1" >/dev/null
        set_primary_native_mode
    else
        # Extend -> Mirror: drop the primary to MIRROR_MODE first so the
        # subsequent mirror is 1:1, then re-attach the mirror clause.
        set_primary_mirror_mode
        hyprctl keyword monitor "${EXTERNAL},preferred,auto,1,mirror,${PRIMARY}" >/dev/null
    fi
    exit 0
fi

# Default branch: emit JSON state for waybar.
if [[ -z $EXTERNAL ]]; then
    echo '{"text": "", "class": "hidden"}'
    exit 0
fi

if is_mirroring "$EXTERNAL"; then
    printf '{"text": "%s", "class": "mirror", "tooltip": "%s: mirroring %s"}\n' \
        "$ICON" "$EXTERNAL" "$PRIMARY"
else
    printf '{"text": "%s", "class": "extend", "tooltip": "%s: extending %s"}\n' \
        "$ICON" "$EXTERNAL" "$PRIMARY"
fi
