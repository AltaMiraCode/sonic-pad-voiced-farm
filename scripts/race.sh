#!/bin/bash
# race.sh - SILLY_RACE - the Z-axis drag race (one lap, up and back).
#
# Existing sounds only: Arcade countdown blips, Arcade boot as race music,
# the rangers roll-call clip + say.sh (live voice, no files) for the winner.
#
#   1. GRID   - silent homes to Arcade boot, lights low
#   2. COUNT  - three blips, lights stepping brighter, GO on the fourth
#   3. RACE   - one lap Z15->Z180->Z15; each racer secretly draws a speed
#               (the fastest draw wins), lights toggling with altitude
#   4. REVEAL - each racer's light dies as it crosses the line; after a
#               beat of darkness the lights return RANKED (winner brightest,
#               last dimmest), the winner says its own name, Omega announces
#               the result, then flashing lights under the end sound;
#               lights restored; silent home
#
if [ -z "$SHOW_BG" ]; then
    SHOW_BG=1 setsid "$0" "$@" >/tmp/race.log 2>&1 < /dev/null &
    exit 0
fi
exec 8>/tmp/.rangers_lock
flock -n 8 || exit 0
sleep 2   # let the launching macro drain (see rangers.sh)

PLAY="$HOME/play_chime.sh"
SAY="$HOME/say.sh"
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
    curl -s -m 240 -X POST "http://127.0.0.1:$p/printer/gcode/script?script=$enc" >/dev/null
}

CAST=""
for P in $ORDER; do
    curl -s -m2 "http://127.0.0.1:${PORT[$P]}/printer/info" >/dev/null 2>&1 || continue
    busy "${PORT[$P]}" || CAST="$CAST $P"
done
CAST=$(echo $CAST)
NCAST=$(echo "$CAST" | wc -w)

A="$HOME/sounds/Arcade"
[ "$NCAST" -lt 2 ] && { "$PLAY" "$A/error.wav"; exit 0; }   # a race needs rivals

# 1) GRID - silent homes + grid-level while the attract music plays.
#    Music is a FLAG-gated loop (not setsid): stop it with a file-remove + a
#    TARGETED wait. A bare `wait` here used to also block on the never-ending
#    music loop, which hung the show "chiming before the race".
MUSF=/tmp/.race_music
: > "$MUSF"
( while [ -f "$MUSF" ]; do "$PLAY" "$A/boot.wav"; sleep 0.4; done ) &
MUS=$!
pids=""
for P in $CAST; do gsend "${PORT[$P]}" "_INVADER_POSE" & pids="$pids $!"; done
for pid in $pids; do wait "$pid"; done
pids=""
for P in $CAST; do gsend "${PORT[$P]}" "_RACE_STAGE" & pids="$pids $!"; done   # level grid: all laps start at Z15
for pid in $pids; do wait "$pid"; done
rm -f "$MUSF"; wait "$MUS" 2>/dev/null   # music stops after its current chime; no hang

# Omega calls it (the espeak fallback IS Omega's voice)
"$SAY" "start your engines"
sleep 0.4

# 2) COUNTDOWN - lights step up with each blip
for P in $CAST; do lset "${PORT[$P]}" 0.1; done
for s in 0.3 0.6 1; do
    "$PLAY" "$A/pause.wav" &
    for P in $CAST; do lset "${PORT[$P]}" "$s"; done
    sleep 0.7
done
"$PLAY" "$A/online.wav" &      # GO!

# 3) THE RACE - shuffle the speeds; fastest card wins
SPEEDS="900 800 740 690 650 615 585 560"   # 8 cards - fastest draw wins
WINNER=""
declare -A LANE
i=0
for P in $(echo "$CAST" | tr ' ' '\n' | shuf); do
    i=$((i+1))
    F=$(echo $SPEEDS | cut -d' ' -f$i)
    LANE[$P]=$F
    [ "$F" = "900" ] && WINNER=$P
done
declare -A RPID
for P in $CAST; do
    gsend "${PORT[$P]}" "_RACE_LAP F=${LANE[$P]}" &
    RPID[$P]=$!
done
: > "$MUSF"
( while [ -f "$MUSF" ]; do "$PLAY" "$A/boot.wav"; sleep 0.2; done ) &
MUS=$!
wait "${RPID[$WINNER]}"                      # the moment the winner crosses...
rm -f "$MUSF"                                 # ...music stops; its light is already out
for P in $CAST; do wait "${RPID[$P]}" 2>/dev/null; done   # stragglers roll in, lights dying one by one
wait "$MUS" 2>/dev/null

# 4) THE REVEAL - dark beat, then the podium lights ARE the reveal: they come
#    back RANKED (winner blazing -> last place dimmest) AT THE SAME beat as the
#    winner says its own name. Then Omega makes it official. THEN the end chime
#    + flashing finale (congruent - the chime rings while the lights flash),
#    kept AFTER the announcement. Finally the podium is re-lit and LEFT lit, so
#    placement is the lasting image.
sleep 0.9

# wide spread so placement reads at a glance (the eye is logarithmic - close
# values blur)
RANKS="1 0.4 0.2 0.12 0.07 0.045 0.03 0.02"
rank_lights() {   # light every racer to its finishing-place brightness
    local i=0 F P W
    for F in 900 800 740 690 650 615 585 560; do
        for P in $CAST; do
            [ "${LANE[$P]}" = "$F" ] || continue
            i=$((i+1)); W=$(echo $RANKS | cut -d' ' -f$i)
            lset "${PORT[$P]}" "$W"
        done
    done
}

rank_lights                                  # the reveal: the podium lights rise...
"$SAY" "$WINNER"                             # ...as the winner says its own name (same beat)
sleep 0.3
"$SAY" "the winner is $WINNER"               # ...and Omega makes the call
sleep 0.4

# the end chime + flashing finale - kept AFTER the announcement, the chime
# ringing congruent with the flashing lights
"$PLAY" "$A/done.wav" &
for k in 1 2 3 4; do
    for P in $CAST; do lset "${PORT[$P]}" 1; done; sleep 0.13
    for P in $CAST; do lset "${PORT[$P]}" 0; done; sleep 0.13
done
wait

rank_lights                                  # settle back onto the ranked podium...
sleep 2                                       # ...and LEAVE it lit - the lasting image
wait

restore_lights "$CAST"
for P in $CAST; do gsend "${PORT[$P]}" "_SILLY_HOME" & done
wait
