#!/bin/bash
# cradle.sh - SILLY_CRADLE: the fleet does a Newton's cradle.
#
# DESK ORDER, left to right - append new printers by their PHYSICAL position
# on the desk when they join the farm (any 2-8 beads works):
#   TRIDENT  DIMETER  UNICORN  OMEGA
#
#   1. SETUP  - the room fades to black; Zen start plays; every bead homes
#               (silent), rises to hang height and aligns left
#   2. CLACK  - TWO full round trips: the left bead strikes, the impulse
#               hops through the middles carrying the GLOW with it, the far
#               bead swings way out, hangs... and comes back; the impulse
#               runs back left and the first bead swings out. Every contact
#               rings the Zen boot gong - the overlapping decays are the
#               whole point.
#   3. DONE   - stillness, the Zen done sound while the lights breathe in
#               and out, lights restored, then a SILENT all-home (G28.1).
#
# ALL reachable beads must be idle - a cradle with missing beads is just
# sad. Every move goes through _CRADLE_POSE/_CRADLE_MOVE, which re-check
# busy state on the printer itself. Shares the silly-show lock. Self-
# daemonizes.

if [ -z "$CRADLE_BG" ]; then
    CRADLE_BG=1 setsid "$0" "$@" >/tmp/cradle.log 2>&1 < /dev/null &
    exit 0
fi
exec 8>/tmp/.rangers_lock
flock -n 8 || exit 0
sleep 2   # let the launching macro drain (see rangers.sh)

Z="$HOME/sounds/Zen"
PLAY="$HOME/play_chime.sh"
HIT="$Z/boot.wav"
declare -A PORT=( [OMEGA]=7128 [UNICORN]=7125 [DIMETER]=7126 [TRIDENT]=7127 [TESSERACT]=7129 [PENTAGRAM]=7130 [SESTINA]=7131 [HYDRA]=7132 )
LTOR="TRIDENT DIMETER UNICORN OMEGA"   # physical desk order, left -> right; extend when the farm grows

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

# the beads = every REACHABLE printer in desk order; any busy one cancels
BEADS=()
for P in $LTOR; do
    curl -s -m2 "http://127.0.0.1:${PORT[$P]}/printer/info" >/dev/null 2>&1 || continue
    busy "${PORT[$P]}" && { "$PLAY" "$Z/pause.wav"; exit 0; }
    BEADS+=("$P")
done
N=${#BEADS[@]}
[ "$N" -lt 2 ] && { "$PLAY" "$Z/pause.wav"; exit 0; }   # one bead can't clack
BSTR="${BEADS[*]}"
FIRST=${BEADS[0]}
LAST=${BEADS[$((N-1))]}

# lights: remember the user's setting, then the room goes dark for the piece
capture_lights "$BSTR"
for s in 0.6 0.35 0.15 0; do
    for P in "${BEADS[@]}"; do lset "${PORT[$P]}" "$s"; done
    sleep 0.25
done

# 1) SETUP - hang the beads (full home if needed, rise to hang height, align left)
"$PLAY" "$Z/start.wav" &
for P in "${BEADS[@]}"; do gsend "${PORT[$P]}" "_CRADLE_POSE" & done
wait

sleep 0.8   # stillness before the first clack

# 2) THE CRADLE - the glow travels WITH the impulse, back and forth TWICE
for CYCLE in 1 2; do
    lset "${PORT[$FIRST]}" 1                # the first bead lights up...
    sleep 0.6
    # forward pass: strike, then the impulse hops through the middles
    i=0
    while [ $i -lt $((N-1)) ]; do
        B=${BEADS[$i]}; NXT=${BEADS[$((i+1))]}
        gsend "${PORT[$B]}" "_CRADLE_MOVE X=70"        # strike / hop right...
        "$PLAY" "$HIT" &                                # ...CLACK
        lset "${PORT[$B]}" 0.05                         # ...hand the glow on
        lset "${PORT[$NXT]}" 1
        gsend "${PORT[$B]}" "_CRADLE_MOVE X=40 F=2400" &   # settle back slowly
        i=$((i+1))
    done
    # the far bead: big swing out glowing, hang at the top...
    gsend "${PORT[$LAST]}" "_CRADLE_MOVE X=150 F=10000"
    sleep 0.9
    # ...and back down for the return contact
    gsend "${PORT[$LAST]}" "_CRADLE_MOVE X=40 F=10000"
    "$PLAY" "$HIT" &
    lset "${PORT[$LAST]}" 0.05
    # return pass: impulse runs back left through the middles
    i=$((N-2))
    while [ $i -ge 1 ]; do
        B=${BEADS[$i]}; PRV=${BEADS[$((i-1))]}
        lset "${PORT[$B]}" 1
        gsend "${PORT[$B]}" "_CRADLE_MOVE X=10"
        "$PLAY" "$HIT" &
        lset "${PORT[$B]}" 0.05
        gsend "${PORT[$B]}" "_CRADLE_MOVE X=40 F=2400" &
        i=$((i-1))
    done
    # the first bead: the finish - big swing out left, hang, settle to rest
    lset "${PORT[$FIRST]}" 1
    gsend "${PORT[$FIRST]}" "_CRADLE_MOVE X=5 F=10000"
    sleep 0.9
    gsend "${PORT[$FIRST]}" "_CRADLE_MOVE X=40 F=2400"
    lset "${PORT[$FIRST]}" 0.05
    sleep 0.8   # the beads hang still a moment before the next round
done

# 3) DONE - the Zen done sound while the lights breathe in... and out
sleep 0.7
"$PLAY" "$Z/done.wav" &
for s in 0.15 0.35 0.6 0.85 1; do
    for P in "${BEADS[@]}"; do lset "${PORT[$P]}" "$s"; done
    sleep 0.28
done
for s in 0.8 0.55 0.3 0.1 0; do
    for P in "${BEADS[@]}"; do lset "${PORT[$P]}" "$s"; done
    sleep 0.28
done
wait
# lights back exactly as found - BEFORE the pack-up
restore_lights "$BSTR"
# then pack it up (all-home in SILENCE - G28.1, no narration)
for P in "${BEADS[@]}"; do gsend "${PORT[$P]}" "_SILLY_HOME" & done
wait
