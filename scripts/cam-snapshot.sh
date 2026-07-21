#!/bin/bash
# cam-snapshot.sh - grab a still off the farm camera stream, save a
# timestamped JPG, with a shutter chime at the moment of capture.
# Called by the SNAPSHOT macro from any printer's panel (the camera is
# farm-wide, so it doesn't matter which one).
PORT="${CAM_PORT:-8080}"
DIR="$HOME/snapshots"; mkdir -p "$DIR"
OUT="$DIR/cam_$(date +%Y%m%d_%H%M%S).jpg"
"$HOME/play_chime.sh" "$HOME/cam-chimes/cam_snapshot.wav" >/dev/null 2>&1 &
curl -s -m5 "http://127.0.0.1:$PORT/snapshot" -o "$OUT" 2>/dev/null
if [ -s "$OUT" ]; then echo "saved $OUT"; else rm -f "$OUT"; echo "no stream - is the camera connected?"; fi
