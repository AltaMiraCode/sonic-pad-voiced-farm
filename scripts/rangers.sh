#!/bin/bash
# rangers.sh - SILLY_RANGERS: the fleet morph sequence.
#
#   1. MORPH   - every idle printer powers up with a FULL silent home (X, Y
#                and the long Z probe) while the hero fanfare LOOPS; the
#                music cuts the instant the last printer is ready
#   2. ROLL CALL - fleet order (Omega, Unicorn, Dimeter, Trident): each
#                printer calls its name AS it dances; the next printer only
#                speaks once the previous one has stopped moving
#   3. THE BEAT - a breath of silence...
#   4. THE CRY - Omega alone shouts "GO GO POWER PRINTERS!" while every
#                head in the cast shakes left-right with it
#   5. THE STING - the boot sound
#   6. POWER DOWN - everyone re-homes all axes in SILENCE (G28.1, so the
#                homing narration never plays inside this show)
#
# NO NARRATION anywhere in this macro: every home is the raw G28.1.
#
# BUSY-SAFE: printers that are printing/paused/tuning sit the dancing out
# (their voice still joins the cry - shouting never moved an axis). The
# _RANGER_DANCE macro double-checks busy state on the printer itself.
# One show at a time (flock). Self-daemonizes so the button returns instantly.

if [ -z "$RANGERS_BG" ]; then
    RANGERS_BG=1 setsid "$0" "$@" >/tmp/rangers.log 2>&1 < /dev/null &
    exit 0
fi
exec 8>/tmp/.rangers_lock
flock -n 8 || exit 0

# let the SILLY_RANGERS macro that launched us finish draining - while it runs,
# its printer reads idle_timeout=Printing and would be cast out of its own show
sleep 2

R="$HOME/rangers"                  # roll-call + cry voice clips only
SND="$HOME/sounds/Rangers"         # the show's music IS the Rangers theme:
MORPH="$SND/done.wav"              #   done  = the full morph fanfare
STING="$SND/boot.wav"              #   boot  = the victory sting
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

busy() {   # $1 = port; exit 0 if that printer must not move
    curl -s -m3 "http://127.0.0.1:$1/printer/objects/query?print_stats=state&idle_timeout=state" \
    | python3 -c "
import sys, json
st = json.load(sys.stdin)['result']['status']
s = st.get('print_stats', {}).get('state', '')
i = st.get('idle_timeout', {}).get('state', '')
sys.exit(0 if s in ('printing', 'paused') or i == 'Printing' else 1)" 2>/dev/null
}

gsend() {  # $1 = port, rest = gcode. BLOCKS until the printer finishes it.
    local p=$1; shift
    local enc
    enc=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(' '.join(sys.argv[1:])))" "$@")
    curl -s -m 120 -X POST "http://127.0.0.1:$p/printer/gcode/script?script=$enc" >/dev/null
}

# who's in the show? (unreachable/prewired printers simply aren't cast)
CAST=""
for P in $ORDER; do
    curl -s -m2 "http://127.0.0.1:${PORT[$P]}/printer/info" >/dev/null 2>&1 || continue
    busy "${PORT[$P]}" || CAST="$CAST $P"
done
[ -z "$CAST" ] && { "$PLAY" "$STING"; exit 0; }   # all busy: sting and bow out

# lights: remember how the user had them, then bring the house up
capture_lights "$CAST"
for P in $CAST; do lset "${PORT[$P]}" 1; done

# 1) MORPH - full silent power-up home for the whole cast, fanfare on LOOP.
#    The loop runs in its own process group so we can cut music AND the
#    in-flight aplay dead the moment the last printer reports ready.
pids=""
for P in $CAST; do gsend "${PORT[$P]}" "_SILLY_HOME" & pids="$pids $!"; done
setsid bash -c "while :; do '$PLAY' '$MORPH'; done" &
MUS=$!
for pid in $pids; do wait "$pid"; done
kill -- -"$MUS" 2>/dev/null       # music stops ON finishing, mid-note if need be

# 2) ROLL CALL - fleet order: the name plays AS the printer dances; the next
#    printer doesn't speak until the previous one has finished moving
#    (gsend blocks on the dance's M400 - that IS the serialization)
for P in $CAST; do
    # the supporting cast fast-flashes while the star holds its spotlight
    OTHERS=$(echo "$CAST" | tr ' ' '\n' | grep -v "^$P$" | tr '\n' ' ')
    ( while :; do
        for Q in $OTHERS; do lset "${PORT[$Q]}" 1; done; sleep 0.15
        for Q in $OTHERS; do lset "${PORT[$Q]}" 0; done; sleep 0.15
      done ) & PULSE=$!
    "$SAY" "$P" &            # each printer names itself: say.sh finds the
    NAMEPID=$!               # voicebank name clip, or synths it live (Omega)
    gsend "${PORT[$P]}" "_RANGER_DANCE"
    kill "$PULSE" 2>/dev/null; wait "$PULSE" 2>/dev/null
    wait "$NAMEPID" 2>/dev/null   # never let a long name spill onto the next printer
    sleep 0.3
done
for P in $CAST; do lset "${PORT[$P]}" 0.6; done   # house half-light for the beat

# 3) the beat...
sleep 1.2

# 4) ...GO GO POWER PRINTERS! - Omega's battle cry while EVERY head in the
#    cast shakes left-right with it
for P in $CAST; do gsend "${PORT[$P]}" "_RANGER_SHOUT" & done
"$PLAY" "$R/cry_omega.wav" &
wait   # cry done AND every head still

# light show finale: three fast chases down the row, then triple all-flash
for r in 1 2 3; do
    for P in $CAST; do lset "${PORT[$P]}" 1; sleep 0.07; lset "${PORT[$P]}" 0.1; done
done
for i in 1 2 3; do
    for P in $CAST; do lset "${PORT[$P]}" 1; done; sleep 0.12
    for P in $CAST; do lset "${PORT[$P]}" 0; done; sleep 0.12
done
for P in $CAST; do lset "${PORT[$P]}" 1; done

# 5) the boot sting...
sleep 0.3
"$PLAY" "$STING"

# 6) ...then POWER DOWN - all home all axes in silence (G28.1 = no narration)
for P in $CAST; do gsend "${PORT[$P]}" "_SILLY_HOME" & sleep 0.5; done
wait
restore_lights "$CAST"   # the lights go back exactly how you had them
