#!/usr/bin/env bash

set -e

filename=~/Videos/recording-$(date -u +"%Y-%m-%d.%H.%M.%S")

wl-screenrec -g "$(slurp)" -f "$filename".mp4
gifski -o "$filename".gif "$filename".mp4
notify-send "Saved as $filename.gif"
