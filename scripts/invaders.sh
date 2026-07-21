#!/bin/bash
# invaders.sh - SILLY_INVADERS: the fleet plays Space Invaders.
# Soundtrack is 100% the existing Arcade theme - no extra sound files.
#
#   1. GAME ON  - Arcade boot over the silent homes, and again as the
#                 wave ASCENDS into formation
#   2. THE DESCENT - all printers IN SYNC, like the invader wave on screen:
#                 step-step-step-step across in X, then DROP DOWN a row in Z
#                 (runout = the descend alarm), back across, drop, across
#                 again - each row faster. Identical choreography fired
#                 simultaneously = they move and FINISH together.
#   3. GAME OVER - Arcade done rings out...
#   4. RESET    - ...and everyone homes all axes IN SILENCE (G28.1, no
#                 narration), all at once.
#
# BUSY-SAFE like rangers.sh: printing/paused/tuning printers sit it out
# (checked here AND inside the _INVADER_* macros). Shares the silly-show
# lock. Self-daemonizes.

if [ -z "$INVADERS_BG" ]; then
    INVADERS_BG=1 setsid "$0" "$@" >/tmp/invaders.log 2>&1 < /dev/null &
    exit 0
fi
exec 8>/tmp/.rangers_lock
flock -n 8 || exit 0

# let the launching macro finish draining (see rangers.sh)
sleep 2

A="$HOME/sounds/Arcade"
PLAY="$HOME/play_chime.sh"
declare -A PORT=( [OMEGA]=7128 [UNICORN]=7125 [DIMETER]=7126 [TRIDENT]=7127 [TESSERACT]=7129 [PENTAGRAM]=7130 [SESTINA]=7131 [HYDRA]=7132 )
ORDER="OMEGA UNICORN DIMETER TRIDENT TESSERACT PENTAGRAM SESTINA HYDRA"   # fleet order; prewired ports refuse instantly until those printers exist

# ---- show lighting rig: capture -> play -> restore --------------------------
lset() {   # $1=port $2=white 0-1 (fire-and-forget; instant on an idle printer)
    curl -s -m2 -X POST "http://127.0.0.1:$1/printer/gcode/script?script=_LEDW%20W=$2" >/dev/null 2>&1 &
}
getw() {   # $1=port -> current white level (defaults to 1 if unreadable)
    curl -s -m3 "http://127.0.0.1:$1/printer/objects/query?led%20LED_Light" \
    | python3 -c "
import sys, json
try: print(json.load(sys.stdin)['result']['status']['led LED_Light']['color_data'][0][3])
except Exception: print(1)" 2>/dev/null || echo 1
}
declare -A OW
capture_lights() { for P in $1; do OW[$P]=$(getw "${PORT[$P]}"); done; }
restore_lights() { for P in $1; do lset "${PORT[$P]}" "${OW[$P]:-1}"; done; sleep 0.5; }

busy() {
    curl -s -m3 "http://127.0.0.1:$1/printer/objects/query?print_stats=state&idle_timeout=state" \
    | python3 -c "
import sys, json
st = json.load(sys.stdin)['result']['status']
s = st.get('print_stats', {}).get('state', '')
i = st.get('idle_timeout', {}).get('state', '')
sys.exit(0 if s in ('printing', 'paused') or i == 'Printing' else 1)" 2>/dev/null
}

gsend() {  # $1 = port, rest = gcode. BLOCKS until done.
    local p=$1; shift
    local enc
    enc=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(' '.join(sys.argv[1:])))" "$@")
    curl -s -m 180 -X POST "http://127.0.0.1:$p/printer/gcode/script?script=$enc" >/dev/null
}

CAST=""
for P in $ORDER; do
    curl -s -m2 "http://127.0.0.1:${PORT[$P]}/printer/info" >/dev/null 2>&1 || continue
    busy "${PORT[$P]}" || CAST="$CAST $P"
done
[ -z "$CAST" ] && { "$PLAY" "$A/error.wav"; exit 0; }   # no players: game over, man

# lights: remember the user's setting; the cabinet lights up for the game
capture_lights "$CAST"
for P in $CAST; do lset "${PORT[$P]}" 1; done

# 1) GAME ON - boot over the silent homes, and the start sound AGAIN as the
#    whole wave ascends into formation
"$PLAY" "$A/boot.wav" &
for P in $CAST; do gsend "${PORT[$P]}" "_INVADER_POSE" & done
wait
"$PLAY" "$A/boot.wav" &
for P in $CAST; do gsend "${PORT[$P]}" "_INVADER_RISE" & done
wait

sleep 0.6

# 2) THE DESCENT - identical choreography fired at once = perfect sync.
#    The march audio below tracks the same row/step/drop timing the
#    _INVADER_MARCH macro executes (drops are slow Z moves, ~2.5s).
for P in $CAST; do gsend "${PORT[$P]}" "_INVADER_MARCH" & done
step=0
for row in 0.83 0.63 0.42; do            # full-width strides; each row faster
    for i in 1 2 3 4; do
        if [ $((step % 2)) -eq 0 ]; then "$PLAY" "$A/pause.wav" &
        else "$PLAY" "$A/resume.wav" & fi
        step=$((step + 1))
        sleep "$row"
    done
    "$PLAY" "$A/runout.wav" &            # the DROP alarm...
    sleep 2.5                            # ...while the whole wave sinks a row
done
wait   # every printer's march complete - they finish together

# 3) GAME OVER - triple flash with the victory sound
sleep 0.4
"$PLAY" "$A/done.wav" &
for i in 1 2 3; do
    for P in $CAST; do lset "${PORT[$P]}" 1; done; sleep 0.15
    for P in $CAST; do lset "${PORT[$P]}" 0; done; sleep 0.15
done
for P in $CAST; do lset "${PORT[$P]}" 1; done
wait

# 4) RESET - all home all axes in silence, simultaneously; lights back as found
for P in $CAST; do gsend "${PORT[$P]}" "_SILLY_HOME" & done
wait
restore_lights "$CAST"
