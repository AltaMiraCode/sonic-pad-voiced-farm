#!/bin/bash
# runout_alert.sh — filament runout announcement, called from Klipper via
# the RUNOUT_ALERT macro. ORDER MATTERS: the sensor fires this instantly, but
# the auto-PAUSE lands (and is announced by the daemon) a few seconds later -
# so wait for the pause to happen and be SPOKEN first, then sound the alarm.
# Plays the active theme's runout sound (falls back to the pause sound), then
# speaks which printer ran out.
# Usage: runout_alert.sh Omega
#
# SELF-DETACHES: the wait-for-pause can run ~30s, longer than any sane
# gcode_shell_command timeout - so the macro call returns instantly and the
# watch continues in the background (same pattern as the shows).

if [ -z "$RA_BG" ]; then
    RA_BG=1 setsid "$0" "$@" >/dev/null 2>&1 < /dev/null &
    exit 0
fi

NAME="${1:-Printer}"
declare -A PORT=( [OMEGA]=7128 [UNICORN]=7125 [DIMETER]=7126 [TRIDENT]=7127 [TESSERACT]=7129 [PENTAGRAM]=7130 [SESTINA]=7131 [HYDRA]=7132 )
T=$(echo "$NAME" | tr '[:lower:]' '[:upper:]'); P="${PORT[$T]}"

# wait (up to 20s) for the runout-pause to land...
if [ -n "$P" ]; then
    for i in $(seq 1 20); do
        st=$(curl -s -m2 "http://127.0.0.1:$P/printer/objects/query?print_stats=state" \
             | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['status']['print_stats']['state'])" 2>/dev/null)
        [ "$st" = "paused" ] && break
        sleep 1
    done
    sleep 4        # ...and give the daemon's "{name} paused" voice its turn first
fi

F="$HOME/chimes/runout.wav"
[ -f "$F" ] || F="$HOME/chimes/pause.wav"
[ -f "$F" ] && "$HOME/play_chime.sh" "$F"

# say.sh plays the pre-rendered voicebank wav; the voice lock keeps this from
# ever talking over a still-playing announcement
"$HOME/say.sh" "$NAME filament runout"
