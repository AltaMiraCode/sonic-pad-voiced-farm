#!/bin/bash
# shape-run.sh - detached, NARRATED, TWO-PHASE input shaping for ONE printer.
# Launched by shape.sh (run mode) via setsid so it survives the printer's restart.
#
# BEDSLINGER REALITY (Neptune 3 Pro): the toolhead moves X and Z, but the BED
# moves in Y. A toolhead-mounted ADXL345 measures X fine, but it's stationary in Y
# (the bed shakes), so it can't read Y from the toolhead. With ONE sensor we do X
# on the toolhead, PAUSE for the user to move the sensor onto the bed, then do Y.
#
# Flow / narration (shape.sh already said "starting... / claiming / claimed"):
#   restarting -> home (G28 macro says "homing all axis") -> "starting x axis..."
#   -> X freq ticks -> SHAPER_CALIBRATE AXIS=X -> "x axis test complete, move to bed"
#   -> wait for a second RUN_INPUT_SHAPER press (re-prompt every 45s; CANCELS after
#      15 min instead of sweeping Y with the sensor in the wrong place)
#   -> "resuming, starting y axis..." -> Y ticks + "y axis test complete" +
#      "calculating" -> SHAPER_CALIBRATE AXIS=Y -> "model created" -> "complete"
#   -> auto SAVE_CONFIG (verified! a failed save is announced, never silent)
#   -> flags cleaned up (only if still OURS - never another run's).
#
# SAFETY: gc() treats an EMPTY Moonraker reply as failure too (timeouts and
# refused connections must not read as success). A keepalive ticker re-marks
# ~/.shaping every 60s so neither the daemon suppression (600s) nor the smart
# button's in-progress gate can expire during a long sweep or calc.
declare -A PORT=( [OMEGA]=7128 [UNICORN]=7125 [DIMETER]=7126 [TRIDENT]=7127 [TESSERACT]=7129 [PENTAGRAM]=7130 [SESTINA]=7131 [HYDRA]=7132 )
NAME="$1"                                   # proper-case name for narration (e.g. Omega)
T=$(echo "$NAME" | tr '[:lower:]' '[:upper:]')
P="${PORT[$T]}"
[ -z "$P" ] && exit 1
SAY="$HOME/say.sh"
say() { "$SAY" "$@" >/dev/null 2>&1; }

mark()    { printf '%s\n' "$NAME" > "$1"; }   # flags carry the printer's name
mine()    { [ -f "$1" ] && [ "$(tr -d '[:space:]' < "$1")" = "$NAME" ]; }
cleanup() {
    kill "$TICK" 2>/dev/null
    mine "$HOME/.shaping"        && rm -f "$HOME/.shaping"
    mine "$HOME/.shaper_waiting" && rm -f "$HOME/.shaper_waiting"
    rm -f "$HOME/.shaper_continue"
}
fail()    { kill "$NARR" 2>/dev/null; say "$NAME input shaping failed"; cleanup; exit 1; }

ready() { curl -s -m3 "http://127.0.0.1:$P/printer/info" 2>/dev/null \
    | python3 -c "import sys,json;print((json.load(sys.stdin).get('result') or {}).get('state',''))" 2>/dev/null; }
wait_ready() { for i in $(seq 1 "${1:-45}"); do [ "$(ready)" = "ready" ] && return 0; sleep 1; done; return 1; }
# -G + --data-urlencode so spaces in gcode are encoded; FAILS on a Moonraker
# error OR an empty reply (curl timeout / connection refused != success).
gc() {
    local out
    out=$(curl -s -m"${2:-900}" -G -X POST "http://127.0.0.1:$P/printer/gcode/script" \
          --data-urlencode "script=$1" 2>/dev/null)
    [ -z "$out" ] && return 1
    case "$out" in *'"error"'*) return 1 ;; esac
    return 0
}

# keepalive: re-mark ~/.shaping every 60s for the whole run (killed by cleanup)
( while :; do printf '%s\n' "$NAME" > "$HOME/.shaping"; sleep 60; done ) &
TICK=$!

# frequency ticks for ONE axis sweep, paced to the real ~140s sweep. Spoken
# name-first so say.sh picks THIS printer's voice; the wav is the frequency only.
freq_ticks() {
    sleep 0;   say "$NAME testing frequencies. 5 hertz"
    sleep 20;  say "$NAME 25 hertz"
    sleep 25;  say "$NAME 50 hertz"
    sleep 17;  say "$NAME test halfway"
    sleep 33;  say "$NAME 100 hertz"
    sleep 26;  say "$NAME 125 hertz"
}

HANDOFF="$NAME x axis test complete. move accelerometer to bed. then press x stop on the print head bar for y axis"

# X endstop microswitch on the head bar, polled as a hand-pressed "continue"
# button (same trick as runout-feed.sh, polled every loop) - a brief press
# resumes the Y phase without the tablet.
xstop_triggered() {
    curl -s -m4 -X POST "http://127.0.0.1:$P/printer/gcode/script?script=QUERY_ENDSTOPS" >/dev/null 2>&1
    sleep 0.25
    curl -s -m4 "http://127.0.0.1:$P/server/gcode_store?count=12" | python3 -c "
import sys,json
st=''
for m in json.load(sys.stdin)['result']['gcode_store']:
    if 'stepper_x:' in m.get('message',''): st=m['message']
sys.exit(0 if 'stepper_x:TRIGGERED' in st else 1)" 2>/dev/null
}

# 1. restart to load the accelerometer config and grab the sensor
say "$NAME restarting"
curl -s -m5 -X POST "http://127.0.0.1:$P/printer/firmware_restart" >/dev/null 2>&1
sleep 2
wait_ready 45 || fail

# 2. home (the G28 macro announces "homing all axis" itself)
gc "G28" 120 || fail

# 3. X AXIS - sensor on the toolhead, as installed
say "$NAME starting x axis resonance input shaping"
freq_ticks & NARR=$!
gc "SHAPER_CALIBRATE AXIS=X" 900 || fail
kill "$NARR" 2>/dev/null; wait "$NARR" 2>/dev/null

# 4. HANDOFF - the single sensor must physically move to the bed for Y.
#    .shaper_waiting (with our name) tells the one-button macro "paused for Y".
#    If nobody resumes within 15 min, CANCEL - never sweep Y with the sensor
#    still on the toolhead, and never save a half-baked result. (No re-prompt
#    near the timeout: inviting a press that lands after cancellation would
#    start a fresh X run with the sensor on the bed.)
rm -f "$HOME/.shaper_continue"
mark "$HOME/.shaping"; mark "$HOME/.shaper_waiting"
say "$HANDOFF"
# Poll the X-stop CONTINUOUSLY (~0.6s cadence) so a brief press catches - the
# old "check every 3rd second" gate meant a normal tap fell between samples and
# you had to hold the switch ~4s. Timeout (15 min) and re-prompt (45s) are now
# wall-clock, since we no longer sleep exactly 1s per loop.
START=$(date +%s); LAST_PROMPT=$START; resumed=0
while :; do
    NOW=$(date +%s)
    [ $((NOW - START)) -ge 900 ] && break                       # 15-min cancel
    [ -f "$HOME/.shaper_continue" ] && { resumed=1; break; }     # SHAPER_CONTINUE / 2nd press
    xstop_triggered && { resumed=1; break; }                    # X-stop press (polled every loop)
    # re-prompt every 45s, but never in the last 45s before the cancel
    if [ $((NOW - LAST_PROMPT)) -ge 45 ] && [ $((NOW - START)) -lt 855 ]; then
        mark "$HOME/.shaping"; mark "$HOME/.shaper_waiting"
        say "$HANDOFF"
        LAST_PROMPT=$NOW
    fi
    sleep 0.3
done
rm -f "$HOME/.shaper_waiting" "$HOME/.shaper_continue"
if [ "$resumed" != "1" ]; then
    say "$NAME input shaping timed out and was canceled"
    cleanup
    exit 1
fi
mark "$HOME/.shaping"                        # refresh the quiet-window before Y

# 5. Y AXIS - sensor now on the bed. The tail lines ("y axis test complete" then
#    "calculating") fire on the timer during the numpy calc that ends this call.
say "$NAME resuming. starting y axis resonance input shaping"
(
    freq_ticks
    sleep 3; say "$NAME y axis test complete"
    sleep 1; say "$NAME calculating input shaping model. please wait"
) & NARR=$!
gc "SHAPER_CALIBRATE AXIS=Y" 900 || fail
kill "$NARR" 2>/dev/null; wait "$NARR" 2>/dev/null

# 6. done - wrap up, auto-save both axes (VERIFIED), then clean up the flags so
#    the next printer's button works immediately. SAVE_CONFIG restarts this
#    printer; the daemon stays quiet through it via .shaping. An empty reply
#    here is EXPECTED (klippy drops the connection as it restarts) - only an
#    explicit Moonraker error means the save failed.
say "$NAME input shaping model created"
say "$NAME resonance input shaping complete"
gc "_SHAPER_DONE" 10
mark "$HOME/.shaping"
out=$(curl -s -m30 -G -X POST "http://127.0.0.1:$P/printer/gcode/script" \
      --data-urlencode "script=SAVE_CONFIG" 2>/dev/null)
case "$out" in
  *'"error"'*)
    say "$NAME configuration save failed"
    cleanup
    exit 1
    ;;
esac
sleep 2
wait_ready 90
sleep 3                                      # let the daemon digest the ready event
cleanup
