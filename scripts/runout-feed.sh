#!/bin/bash
# runout-feed.sh - GUIDED manual filament feed after a runout. An auto-resume
# can't push new filament through the hotend, so this walks the user through it,
# using the X endstop microswitch ON THE PRINTER HEAD BAR as a hand-pressed
# "button" (polled via QUERY_ENDSTOPS - the pin is already the X homing endstop,
# so a [gcode_button] can't share it). Launched detached by the runout poller
# once the filament sensor sees filament again.
#
# Flow:
#   "filament detected. moving print head for feeding"
#   -> park head front-left, raised for access
#   "feed filament into print head. press x stop on the print head bar to feed"
#   -> [press 1] "feeding filament" -> load fresh filament to the nozzle
#   "press x stop on the print head bar to purge and continue print"
#   -> [press 2] purge -> RESUME the print
declare -A PORT=( [OMEGA]=7128 [UNICORN]=7125 [DIMETER]=7126 [TRIDENT]=7127 [TESSERACT]=7129 [PENTAGRAM]=7130 [SESTINA]=7131 [HYDRA]=7132 )
NAME="$1"
T=$(echo "$NAME" | tr '[:lower:]' '[:upper:]'); P="${PORT[$T]}"
[ -z "$P" ] && exit 1

if [ -z "$FEED_DETACHED" ]; then
    FEED_DETACHED=1 setsid "$0" "$@" </dev/null >/dev/null 2>&1 &
    exit 0
fi

# say.sh, NOT narrate.sh: these are interactive PROMPTS (press the switch...)
# - muting print-progress narration must never silence the instructions
say() { "$HOME/say.sh" "$@" >/dev/null 2>&1; }
gc()  { curl -s -m"${2:-120}" -G -X POST "http://127.0.0.1:$P/printer/gcode/script" --data-urlencode "script=$1" >/dev/null 2>&1; }
paused() { curl -s -m4 "http://127.0.0.1:$P/printer/objects/query?pause_resume=is_paused" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['status']['pause_resume']['is_paused'])" 2>/dev/null; }

xstate() {   # echo TRIGGERED or open (freshest QUERY_ENDSTOPS result)
    curl -s -m4 -X POST "http://127.0.0.1:$P/printer/gcode/script?script=QUERY_ENDSTOPS" >/dev/null 2>&1
    sleep 0.4
    curl -s -m4 "http://127.0.0.1:$P/server/gcode_store?count=12" | python3 -c "
import sys,json
st='open'
for m in json.load(sys.stdin)['result']['gcode_store']:
    if 'stepper_x:' in m.get('message',''):
        st='TRIGGERED' if 'stepper_x:TRIGGERED' in m['message'] else 'open'
print(st)" 2>/dev/null
}
wait_press() {   # wait for a FRESH press: released first (debounce), then triggered
    local i
    for i in $(seq 1 400); do [ "$(xstate)" = "open" ] && break; [ "$(paused)" = "False" ] && return 2; sleep 0.5; done
    for i in $(seq 1 2400); do
        [ "$(paused)" = "False" ] && return 2          # user resumed manually - bail
        [ "$(xstate)" = "TRIGGERED" ] && return 0
        sleep 0.5
    done
    return 1                                            # ~20 min timeout
}

# abort if no longer paused (user handled it manually)
[ "$(paused)" = "True" ] || exit 0

# 1. announce + park head front-left, raised for finger access to the switch
say "$NAME filament detected. moving print head for feeding"
gc "M400" 60
gc "G91" 10
gc "G1 Z15 F600" 30          # raise for access (relative)
gc "G90" 10
gc "G1 X10 Y10 F6000" 30     # front-left, near the X switch on the head bar
gc "M400" 60

# 2. wait for the first press = start feeding
say "$NAME feed filament into print head. press x stop on the print head bar to feed"
wait_press; r=$?
[ "$r" = "2" ] && exit 0                       # resumed manually
[ "$r" = "1" ] && { say "$NAME feed timed out"; exit 1; }

# 3. ensure hot, then load fresh filament to the nozzle
say "$NAME feeding filament"
ce=$(curl -s -m4 "http://127.0.0.1:$P/printer/objects/query?extruder=can_extrude,target" \
     | python3 -c "import sys,json;e=json.load(sys.stdin)['result']['status']['extruder'];print(e['can_extrude'], e['target'])" 2>/dev/null)
set -- $ce
if [ "$1" != "True" ]; then
    tgt=$(python3 -c "print(int(float('${2:-0}')) if float('${2:-0}')>170 else 210)" 2>/dev/null)
    gc "M109 S${tgt:-210}" 300
fi
gc "M83" 10
gc "G1 E70 F300" 90          # load: fresh filament through to the nozzle

# 4. wait for the second press = purge + resume
say "$NAME press x stop on the print head bar to purge and continue print"
wait_press; r=$?
[ "$r" = "2" ] && exit 0
[ "$r" = "1" ] && { say "$NAME feed timed out"; exit 1; }

gc "M83" 10
gc "G1 E15 F200" 60          # purge the transition
gc "RESUME" 60               # normal resume - restores position and continues
