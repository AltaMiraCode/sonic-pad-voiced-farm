#!/bin/bash
# register-webcam.sh - add/update a webcam on every Moonraker instance so it
# shows in each printer's Fluidd. All instances point at the ONE pad, each cam on
# its own stream port. Idempotent. (Also clears any leftover "Argus" entry.)
#
#   register-webcam.sh                 -> "Camera" on :8080 (the shared farm view)
#   register-webcam.sh Trident 8081    -> a named cam on :8081
#
# NOTE: uses the pad LAN IP (set PAD_IP env var) so browsers on other devices can load the stream.
IP="${PAD_IP:-192.168.1.100}"
NAME="${1:-Camera}"
PORT="${2:-8080}"
STREAM="http://$IP:$PORT/stream"
SNAP="http://$IP:$PORT/snapshot"
# all 8 instances (prewired ports refuse instantly until they exist)
for mp in 7128 7125 7126 7127 7129 7130 7131 7132; do
    curl -s -m4 -X DELETE "http://127.0.0.1:$mp/server/webcams/item?name=Argus" >/dev/null 2>&1
    out=$(curl -s -m6 -X POST "http://127.0.0.1:$mp/server/webcams/item" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$NAME\",\"location\":\"farm\",\"service\":\"mjpegstreamer-adaptive\",\"stream_url\":\"$STREAM\",\"snapshot_url\":\"$SNAP\",\"target_fps\":10,\"enabled\":true}" 2>/dev/null)
    case "$out" in
        *'"webcam"'*|*"$NAME"*) echo "$mp: '$NAME' -> :$PORT registered" ;;
        *) : ;;   # nonexistent instance: silently skip
    esac
done
