#!/bin/bash
# filament-change.sh <NAME> [TEMP]
# Guided, voice-narrated STANDALONE filament swap. Uses the X-endstop microswitch
# on the print-head bar as a hand-pressed button (polled via QUERY_ENDSTOPS - the
# same technique as runout-feed.sh). For a swap DURING a print, use M600/PAUSE.
#
# Flow (each [press] = tap the X-stop switch on the print-head bar):
#   say  "<name> change filament process started"
#   home if needed (COLD, before heating)
#   say  "<name> heating nozzle"                                       + heat to temp
#   (at temp) say "<name> nozzle temperature reached, make sure bed is clear,
#             then press the x stop button on the printer head bar to continue"
#   [press] -> head to FAR-RIGHT, OFF the bed (bed BACK)
#   say  "<name> cut filament at base, insert new filament then quick press x stop
#         ... for same color. long hold for color change purge and wipe"
#   [quick press] -> "same color selected"   -> 30 mm extrude,  then wipe automatically
#   [long hold]   -> "color change selected"  -> 110 mm purge,   then wipe automatically
#   say  "<name> filament change complete. cooling"   + heater off
#   (when cool) say "<name> cooled temperature safe"

declare -A PORT=( [OMEGA]=7128 [UNICORN]=7125 [DIMETER]=7126 [TRIDENT]=7127 [TESSERACT]=7129 [PENTAGRAM]=7130 [SESTINA]=7131 [HYDRA]=7132 )
NAME="$1"
T=$(echo "$NAME" | tr '[:lower:]' '[:upper:]'); P="${PORT[$T]}"
[ -z "$P" ] && exit 1
REQ_TEMP="${2:-0}"

# ================== TUNE THESE for your bed ==========================
# Defaults are for an Elegoo Neptune 3 Pro (225 x 225, magnetic flex plate, no
# corner clips). VERIFY on your machine before trusting the first run.
#
# !!! Y CONVENTION !!!  "bed back / nozzle at the front edge" is PARK_Y below.
# On the Neptune 3 Pro, Y0 racks the bed back so the nozzle sits at the FRONT
# edge (purge falls off the front). If on YOUR printer Y0 is the REAR, set
# PARK_Y to your bed's MAX Y instead so the nozzle ends up at the front.
PARK_X=235          # hard against the X max (235) - fully off the right edge of the bed
PARK_Y=0            # bed racked back -> nozzle over the FRONT edge (see note above)
PURGE_Z=6           # nozzle height above the front edge while purging (mm)
PURGE_TOTAL=110     # mm of filament for a COLOR CHANGE (long hold)
SHORT_EXTRUDE=30    # mm for a QUICK press (same-color reload)
LONG_HOLD_MS=800    # hold the X-stop at least this long (ms) to count as a long hold
PURGE_CHUNK=15      # mm per extrude move (MUST stay under Klipper max_extrude_only_distance, default 50)
PURGE_FEED=300      # extrude speed, mm/min (5 mm/s)
WIPE_Z=0.2          # skim height for the wipe (mm)
WIPE_Y=4            # wipe just onto the front of the bed
WIPE_X1=220         # wipe start X (just onto the plate's right edge)
WIPE_X2=150         # wipe end X (drags the ooze inward across the bed)
DEFAULT_TEMP=200    # nozzle temp if none passed and printer is cold (PLA)
COOL_TEMP=40        # nozzle is "cooled / safe" at or below this (C)
PRESS_TIMEOUT_S=150 # seconds to wait for a press before timing out (~2.5 min)
# ====================================================================

# re-exec detached so the Fluidd / KlipperScreen button returns instantly
if [ -z "$FC_DETACHED" ]; then
    FC_DETACHED=1 setsid "$0" "$@" </dev/null >/dev/null 2>&1 &
    exit 0
fi

say() { "$HOME/say.sh" "$*" >/dev/null 2>&1; }
gc()  { curl -s -m"${2:-120}" -G -X POST "http://127.0.0.1:$P/printer/gcode/script" --data-urlencode "script=$1" >/dev/null 2>&1; }
q()   { curl -s -m4 "http://127.0.0.1:$P/printer/objects/query?$1"; }

homed() {   # echo the homed_axes string, e.g. "xyz"
    q "toolhead=homed_axes" | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['status']['toolhead']['homed_axes'])" 2>/dev/null
}

xstate() {   # echo TRIGGERED or open. No python spawn, no settle (Moonraker's POST already blocks
             # until QUERY_ENDSTOPS lands in the store) -> ~4-5x faster sampling, so a quick TAP registers.
    curl -s -m3 -X POST "http://127.0.0.1:$P/printer/gcode/script?script=QUERY_ENDSTOPS" >/dev/null 2>&1
    case "$(curl -s -m3 "http://127.0.0.1:$P/server/gcode_store?count=6" | grep -o 'stepper_x:TRIGGERED\|stepper_x:open' | tail -1)" in
        *TRIGGERED) echo TRIGGERED ;;
        *) echo open ;;
    esac
}

wait_press() {   # 0=fresh press  1=timeout. Samples CONTINUOUSLY (~0.08s) so a brief TAP registers -
                 # no holding the switch. Debounce (see 'open' first), then wall-clock timeout.
    local t0=$SECONDS
    while [ "$(xstate)" != "open" ]; do [ $((SECONDS - t0)) -ge 20 ] && break; sleep 0.02; done
    t0=$SECONDS
    while [ $((SECONDS - t0)) -lt "$PRESS_TIMEOUT_S" ]; do
        [ "$(xstate)" = "TRIGGERED" ] && return 0
        sleep 0.02
    done
    return 1
}

press_kind() {   # echo short | long | timeout. Times how long the X-stop is held.
                 # A quick tap = short; holding >= LONG_HOLD_MS = long (reported as soon as the
                 # threshold is crossed, while still held, so the announcement is immediate).
    local t0 ps now
    t0=$SECONDS
    while [ "$(xstate)" != "open" ]; do [ $((SECONDS - t0)) -ge 20 ] && break; sleep 0.02; done   # debounce
    t0=$SECONDS
    while [ $((SECONDS - t0)) -lt "$PRESS_TIMEOUT_S" ]; do
        if [ "$(xstate)" = "TRIGGERED" ]; then
            ps=$(date +%s%3N)
            while [ "$(xstate)" = "TRIGGERED" ]; do
                now=$(date +%s%3N)
                [ $((now - ps)) -ge "$LONG_HOLD_MS" ] && { echo long; return 0; }
                sleep 0.03
            done
            echo short; return 0
        fi
        sleep 0.02
    done
    echo timeout; return 1
}

# ---- 0) announce start, then home FIRST (while still cold, before any heating)
say "$NAME change filament process started"
H=$(homed)
if [[ "$H" != *x* || "$H" != *y* || "$H" != *z* ]]; then gc "G28" 180; fi

# ---- 1) choose target temp: passed arg > current target (if already hot) > default
CUR=$(q "extruder=target" | python3 -c "import sys,json;print(int(float(json.load(sys.stdin)['result']['status']['extruder']['target'])))" 2>/dev/null)
TEMP="$REQ_TEMP"
if [ "${TEMP:-0}" -le 0 ]; then
    if [ "${CUR:-0}" -gt 170 ]; then TEMP="$CUR"; else TEMP="$DEFAULT_TEMP"; fi
fi

# ---- 2) announce heating + heat, block until at temp
say "$NAME heating nozzle"
gc "M104 S${TEMP}" 15
gc "M109 S${TEMP}" 900          # wait for nozzle temperature

# ---- 3) at temp: clear the bed, wait for the go-ahead press
say "$NAME nozzle temperature reached, make sure bed is clear, then press the x stop button on the printer head bar to continue"
wait_press || { say "$NAME filament change timed out"; exit 1; }

# ---- 4) move to the purge position: head FAR-RIGHT (off the bed), bed BACK (already homed in step 0)
gc "M400" 30
gc "G90" 5
gc "G1 Z${PURGE_Z} F600" 30
gc "G1 X${PARK_X} Y${PARK_Y} F6000" 40
gc "M400" 60

# ---- 5) prompt swap; QUICK press = same-color (short extrude), LONG hold = color change (full purge)
say "$NAME cut filament at base, insert new filament then quick press x stop on printer head bar for same color. long hold for color change purge and wipe"
KIND=$(press_kind)
[ "$KIND" = "timeout" ] && { say "$NAME filament change timed out"; exit 1; }
if [ "$KIND" = "long" ]; then
    say "$NAME color change selected"; TOTAL="$PURGE_TOTAL"
else
    say "$NAME same color selected";  TOTAL="$SHORT_EXTRUDE"
fi
gc "M83" 5
fed=0
while [ "$fed" -lt "$TOTAL" ]; do
    step="$PURGE_CHUNK"; rem=$((TOTAL - fed)); [ "$rem" -lt "$step" ] && step="$rem"
    gc "G1 E${step} F${PURGE_FEED}" 120
    fed=$((fed + step))
done
gc "M400" 120

# ---- 6) wipe automatically (no extra press), straight after the purge
gc "G1 Z${WIPE_Z} F600" 20
gc "G1 X${WIPE_X1} Y${WIPE_Y} F3000" 30
gc "G1 X${WIPE_X2} F1500" 40           # drag to wipe the ooze onto the bed
gc "G1 Z${PURGE_Z} F600" 20            # lift clear
gc "M400" 60

# ---- 7) announce complete, cut the heater, wait for cooldown, then confirm safe
say "$NAME filament change complete. cooling"
gc "M104 S0" 10                        # heater off
for i in $(seq 1 180); do              # poll until cool (cap ~15 min)
    ct=$(q "extruder=temperature" | python3 -c "import sys,json;print(int(float(json.load(sys.stdin)['result']['status']['extruder']['temperature'])))" 2>/dev/null)
    [ "${ct:-999}" -le "$COOL_TEMP" ] && break
    sleep 5
done
say "$NAME cooled temperature safe"
exit 0
