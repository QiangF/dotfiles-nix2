#!/usr/bin/env bash
# Waybar custom/monitor module - manage external display on Hyprland.
#   no args : emit JSON state for waybar (hidden when no external monitor).
#   `toggle`: flip mirror <-> extend on the first detected external monitor.

set -u

PRIMARY="eDP-1"
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

if [[ "${1:-}" == "toggle" ]]; then
    if [[ -z $EXTERNAL ]]; then
        if command -v notify-send >/dev/null 2>&1; then
            notify-send -t 2500 "Monitor" "No external display connected"
        fi
        exit 0
    fi
    if is_mirroring "$EXTERNAL"; then
        # Mirror -> Extend: drop the trailing `mirror,<src>` suffix.
        hyprctl keyword monitor "${EXTERNAL},preferred,auto,1" >/dev/null
    else
        # Extend -> Mirror: re-attach the mirror clause.
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
