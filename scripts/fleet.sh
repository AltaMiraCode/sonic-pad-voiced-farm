#!/bin/bash
# fleet.sh - run one thing on ALL FOUR printers via their local Moonraker APIs.
# This is how a macro on any single printer becomes a farm-wide button.
#
# Usage:
#   fleet.sh gcode <GCODE OR MACRO...>          send the same command to all four
#   fleet.sh gcode_except <NAME> <GCODE...>     all EXCEPT the named printer - used
#                                               by the fleet macros: the caller runs
#                                               the command locally (instant), since
#                                               a curl back to its own busy gcode
#                                               queue deadlocks until the timeout
#                                               (the "lags on current printer" bug)
#   fleet.sh lights_toggle                      lights all OFF if any on, else all ON
#
# Ports: Omega 7128, Unicorn 7125, Dimeter 7126, Trident 7127.
PORTS="7128 7125 7126 7127 7129 7130 7131 7132"   # 7129-7132 prewired (Tesseract/Pentagram/Sestina/Hydra) - refused instantly until they exist
declare -A PORT=( [OMEGA]=7128 [UNICORN]=7125 [DIMETER]=7126 [TRIDENT]=7127 [TESSERACT]=7129 [PENTAGRAM]=7130 [SESTINA]=7131 [HYDRA]=7132 )

enc_args() { python3 -c "import urllib.parse,sys;print(urllib.parse.quote(' '.join(sys.argv[1:])))" "$@"; }

send_all() {   # $* = gcode/macro to run on every printer (fired in parallel)
    local enc
    enc=$(enc_args "$@")
    for p in $PORTS; do
        curl -s -m 5 -X POST "http://127.0.0.1:$p/printer/gcode/script?script=$enc" >/dev/null &
    done
    wait
}

case "$1" in
  gcode)
    shift
    [ -z "$1" ] && { echo "fleet.sh gcode: nothing to send"; exit 1; }
    send_all "$@"
    ;;
  gcode_except)
    shift
    skip=$(echo "${1:-}" | tr '[:lower:]' '[:upper:]'); shift
    [ -z "$1" ] && { echo "fleet.sh gcode_except: nothing to send"; exit 1; }
    enc=$(enc_args "$@")
    for P in "${!PORT[@]}"; do
        [ "$P" = "$skip" ] && continue
        curl -s -m 5 -X POST "http://127.0.0.1:${PORT[$P]}/printer/gcode/script?script=$enc" >/dev/null &
    done
    wait
    ;;
  lights_toggle)
    # decide once for the whole farm: if ANY printer's light is on -> all off;
    # if none are on -> all on. (an unreachable printer just doesn't vote.)
    any_on=0
    for p in $PORTS; do
        if curl -s -m 3 "http://127.0.0.1:$p/printer/objects/query?led%20LED_Light" \
           | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if d['result']['status']['led LED_Light']['color_data'][0][3] > 0 else 1)" 2>/dev/null; then
            any_on=1
        fi
    done
    if [ "$any_on" = "1" ]; then
        send_all LIGHTS_OFF
        "$HOME/say.sh" "all lights off"
    else
        send_all LIGHTS_ON
        "$HOME/say.sh" "all lights on"
    fi
    ;;
  *)
    echo "usage: fleet.sh gcode <cmds...> | fleet.sh gcode_except <name> <cmds...> | fleet.sh lights_toggle"
    ;;
esac
