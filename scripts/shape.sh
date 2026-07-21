#!/bin/bash
# shape.sh - hand the ONE shared ADXL345 to a printer, and (with "run"/"smart")
# auto-drive the input-shaping calibration on it. The pad has one accelerometer
# on SPI (spidev2.0) behind the linux host MCU; only one Klipper instance can own
# it at a time. This writes the accelerometer config into the target's
# [include adxl.cfg], blanks it for the others, releases whoever held it, and
# spawns a DETACHED narrated job (shape-run.sh) that restarts the target and
# drives the two-phase X/Y calibration.
#   shape.sh OMEGA smart      one-button mode (used by RUN_INPUT_SHAPER)
#   shape.sh OMEGA run        force a fresh run
#   shape.sh OMEGA            assign only (no calibration)
#   shape.sh off              release from all printers
#
# SAFETY: releasing the previous holder firmware-restarts it - NEVER allowed
# while that printer is printing (it would destroy the print).
declare -A PORT=( [OMEGA]=7128 [UNICORN]=7125 [DIMETER]=7126 [TRIDENT]=7127 [TESSERACT]=7129 [PENTAGRAM]=7130 [SESTINA]=7131 [HYDRA]=7132 )
SRC="$HOME/adxl-shape.cfg"
STATE="$HOME/.shaper_active"
orig="${1:-off}"

# "go"/"continue": manual Y-resume backdoor (the smart button covers this).
if [ "$orig" = "go" ] || [ "$orig" = "continue" ]; then
    touch "$HOME/.shaper_continue"
    echo "continue signal sent"
    exit 0
fi

target=$(echo "$orig" | tr '[:lower:]' '[:upper:]')
namesay="${orig,,}"; namesay="${namesay^}"        # proper case for narration (Omega)
mode="${2:-}"

kstate() {   # klippy state on port $1 (empty if unreachable)
    curl -s -m3 "http://127.0.0.1:$1/printer/info" 2>/dev/null \
      | python3 -c "import sys,json;print((json.load(sys.stdin).get('result') or {}).get('state',''))" 2>/dev/null
}
pstate() {   # print state on port $1 (empty if unreachable)
    curl -s -m3 "http://127.0.0.1:$1/printer/objects/query?print_stats=state" 2>/dev/null \
      | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['status']['print_stats']['state'])" 2>/dev/null
}

# "smart" one-button mode (RUN_INPUT_SHAPER): decide what this press means.
#   - THIS printer is PAUSED waiting for the Y sensor move -> resume it (Y axis)
#   - ANOTHER printer is paused                            -> refuse, say who
#   - a run is already in progress                         -> ignore the press
#   - otherwise                                            -> start a fresh run,
#     CLAIMING ~/.shaping immediately so a second press on another printer a
#     moment later can't start a concurrent run (the flags are farm-global).
if [ "$mode" = "smart" ]; then
    if [ -f "$HOME/.shaper_waiting" ] && \
       [ $(( $(date +%s) - $(stat -c %Y "$HOME/.shaper_waiting" 2>/dev/null || echo 0) )) -lt 90 ]; then
        waiting=$(tr -d '[:space:]' < "$HOME/.shaper_waiting")
        wupper=$(echo "$waiting" | tr '[:lower:]' '[:upper:]')
        if [ -z "$waiting" ] || [ "$wupper" = "$target" ]; then
            touch "$HOME/.shaper_continue"
            echo "resuming Y axis"
        else
            echo "$waiting is paused for its sensor move - press RUN_INPUT_SHAPER on $waiting (or wait for its timeout)"
            "$HOME/say.sh" "$waiting is waiting for its accelerometer move" >/dev/null 2>&1
        fi
        exit 0
    fi
    if [ -f "$HOME/.shaping" ] && \
       [ $(( $(date +%s) - $(stat -c %Y "$HOME/.shaping" 2>/dev/null || echo 0) )) -lt 600 ]; then
        owner=$(tr -d '[:space:]' < "$HOME/.shaping")
        echo "shaping already running${owner:+ on $owner} - ignoring"
        exit 0
    fi
    mode="run"
    printf '%s\n' "$namesay" > "$HOME/.shaping"   # claim NOW (cross-printer mutex)
fi

if [ ! -f "$SRC" ]; then echo "missing $SRC"; exit 1; fi
prev=$(cat "$STATE" 2>/dev/null | tr -d '[:space:]')

# HANDSHAKE narration, part 1: the claimant speaks first, THEN the print
# check runs, THEN (if another printer holds it) the holder relinquishes.
if [ "$mode" = "run" ]; then
    "$HOME/say.sh" "$namesay starting resonance input shaping process" >/dev/null 2>&1
    "$HOME/say.sh" "$namesay claiming accelerometer" >/dev/null 2>&1
fi

# PRINT PROTECTION: refuse the whole operation if the previous holder is
# printing - releasing it would firmware-restart it mid-print.
if [ -n "$prev" ] && [ "$prev" != "$target" ] && [ -n "${PORT[$prev]}" ]; then
    ps=$(pstate "${PORT[$prev]}")
    if [ "$ps" = "printing" ] || [ "$ps" = "paused" ]; then
        prevsay=$(echo "$prev" | tr '[:upper:]' '[:lower:]'); prevsay="${prevsay^}"
        echo "REFUSED: $prev holds the accelerometer and is $ps - releasing it would kill that print. Try again after it finishes."
        "$HOME/say.sh" "$prevsay is printing. input shaping unavailable" >/dev/null 2>&1
        [ "$mode" = "run" ] && rm -f "$HOME/.shaping"    # release our claim
        exit 1
    fi
fi

# write the includes: real config for the target, empty for everyone else
# (prewired names whose instances don't exist yet are skipped)
for PN in "${!PORT[@]}"; do
    d="$HOME/printer_${PN}_data/config"
    [ -d "$d" ] || continue
    if [ "$PN" = "$target" ]; then cp "$SRC" "$d/adxl.cfg"; else : > "$d/adxl.cfg"; fi
done

# release the previous holder and wait for it to free the SPI bus. Write PREV's
# name into ~/.shaping around the restart so the daemon doesn't announce
# "offline / back online" for a printer the user didn't touch.
if [ -n "$prev" ] && [ "$prev" != "$target" ] && [ -n "${PORT[$prev]}" ]; then
    prevsay=$(echo "$prev" | tr '[:upper:]' '[:lower:]'); prevsay="${prevsay^}"
    # HANDSHAKE part 2: the HOLDER answers in its own voice, then restarts
    if [ "$mode" = "run" ]; then
        "$HOME/say.sh" "$prevsay relinquishing accelerometer" >/dev/null 2>&1
        "$HOME/say.sh" "$prevsay restarting" >/dev/null 2>&1
    fi
    printf '%s\n' "$prevsay" > "$HOME/.shaping"
    curl -s -m5 -X POST "http://127.0.0.1:${PORT[$prev]}/printer/firmware_restart" >/dev/null 2>&1
    for i in $(seq 1 25); do
        [ "$(kstate ${PORT[$prev]})" = "ready" ] && break
        sleep 1
    done
    rm -f "$HOME/.shaping"                        # re-claimed below in run mode
fi

if [ -z "${PORT[$target]}" ]; then          # "off"/unknown -> released from all
    : > "$STATE"
    rm -f "$HOME/.shaping"
    echo "accelerometer released from all printers"
    exit 0
fi
echo "$target" > "$STATE"

if [ "$mode" = "run" ]; then
    printf '%s\n' "$namesay" > "$HOME/.shaping"  # tell the daemon to stay quiet about
                                                 # this printer's shaping restart
    # HANDSHAKE part 3: the hand-off is complete - claimant confirms
    "$HOME/say.sh" "$namesay accelerometer claimed" >/dev/null 2>&1
    setsid "$HOME/shape-run.sh" "$namesay" </dev/null >/dev/null 2>&1 &
    echo "assigned to $target - restarting and auto-calibrating (narrated)"
else
    echo "accelerometer assigned to $target"
fi
