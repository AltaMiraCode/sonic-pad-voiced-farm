#!/bin/bash
# overload-watch.sh - farm resource guardian.
#
# One pad drives every printer, the camera, voice synthesis and renders. If too
# many devices are plugged in, the real failure mode is a printing klippy starved
# of CPU or RAM throwing "Timer too close" and shutting its MCU down. This watches
# for GENUINE, SUSTAINED overload (RAM near-exhausted or CPU saturated) and, in the
# System (Omega) voice, tells you to offload a device before that happens.
#
# Deliberately hard to false-trip: nice-19 renders and a single input-shaping
# numpy calc raise load only slightly and never reach the threshold; it needs
# real contention held for ~30s. Rate-limited to warn, not nag.
SAY="$HOME/say.sh"
WARN="warning. system at overload. offload devices to reduce system strain. warning"
CORES=$(nproc 2>/dev/null || echo 4)
MEM_MIN_KB=$(( 110 * 1024 ))                      # < ~110 MB available = RAM danger
LOAD_MAX=$(awk "BEGIN{print $CORES*2.5}")         # 1-min load > 2.5x cores = CPU saturation
NEED=3                                            # consecutive bad samples (~30s) before warning
COOLDOWN=300                                      # >= 5 min between warnings
say(){ "$SAY" "$@" >/dev/null 2>&1; }

bad=0; last=0
while :; do
    memav=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
    load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
    over=0
    [ -n "$memav" ] && [ "$memav" -lt "$MEM_MIN_KB" ] && over=1
    [ -n "$load1" ] && awk "BEGIN{exit !($load1 > $LOAD_MAX)}" && over=1
    if [ "$over" = "1" ]; then bad=$((bad+1)); else bad=0; fi
    if [ "$bad" -ge "$NEED" ]; then
        t=$(date +%s)
        if [ $((t - last)) -ge "$COOLDOWN" ]; then say "$WARN"; last=$t; fi
    fi
    sleep 10
done
