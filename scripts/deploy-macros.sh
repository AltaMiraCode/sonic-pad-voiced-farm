#!/bin/bash
# deploy-macros.sh [check] - roll ~/macros_new.cfg out to all printers, restarting
# ONLY the idle ones. A printer that is printing/paused gets the new config staged
# on disk (loads on its next restart) but is NEVER interrupted.
#   deploy-macros.sh check   -> just report each printer's print state, do nothing
declare -A PORT=( [OMEGA]=7128 [UNICORN]=7125 [DIMETER]=7126 [TRIDENT]=7127 )

pstate(){   # echo the print_stats state for a port (printing|paused|standby|complete|...)
    curl -s -m5 "http://127.0.0.1:$1/printer/objects/query?print_stats=state" \
      | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['status']['print_stats']['state'])" 2>/dev/null
}

if [ "$1" = "check" ]; then
    for d in OMEGA UNICORN DIMETER TRIDENT; do echo "$d: $(pstate ${PORT[$d]})"; done
    exit 0
fi

NEW=~/macros_new.cfg
[ -s "$NEW" ] || { echo "MISSING $NEW - abort"; exit 1; }
restarted=""; deferred=""
for d in OMEGA UNICORN DIMETER TRIDENT; do
    cfg=~/printer_${d}_data/config/macros.cfg
    [ -f "$cfg" ] || { echo "$d MISSING $cfg"; continue; }
    cp "$cfg" "$cfg.bak"
    cp "$NEW" "$cfg"                       # staging the file is safe even mid-print
    s=$(pstate "${PORT[$d]}")
    if [ "$s" = "printing" ] || [ "$s" = "paused" ]; then
        echo "$d: $s -> config STAGED, restart DEFERRED (print NOT interrupted; new macros load on its next restart)"
        deferred="$deferred $d"
    else
        echo "$d: $s -> restarting to load config"
        curl -s -m5 -X POST "http://127.0.0.1:${PORT[$d]}/printer/firmware_restart" >/dev/null 2>&1
        restarted="$restarted $d"
    fi
done
echo "waiting 12s for restarts..."
sleep 12
for d in OMEGA UNICORN DIMETER TRIDENT; do
    st=$(curl -s -m5 "http://127.0.0.1:${PORT[$d]}/printer/info" | grep -o '"state": *"[a-z]*"' | head -1)
    echo "$d klippy $st"
done
echo "RESTARTED:${restarted:- none}"
echo "DEFERRED (was printing/paused):${deferred:- none}"
