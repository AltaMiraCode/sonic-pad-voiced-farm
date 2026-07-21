#!/bin/bash
# restart-all.sh - restart the Klipper instances. The chime daemon stays
# up and narrates each printer offline -> back online, in fleet order.
#
# BUSY-SAFE: a printer that is PRINTING, PAUSED, mid paper-test, or running an
# input-shaping calibration is SKIPPED (it keeps the old config until you
# restart it later). --force overrides and restarts everyone regardless.
#
# Fleet-order onlines: restarts are STAGGERED in fleet order (3s apart) so the
# ready events come back in order too, and the ~/.fleet_restart flag tells the
# daemon to rank-sort any that land together (one beep per wave).
#
#   ./restart-all.sh            restart all idle printers (usual case)
#   ./restart-all.sh --full     also restart the chime daemon first
#   ./restart-all.sh --force    restart even busy printers (KILLS their work!)
declare -A PORT=( [OMEGA]=7128 [UNICORN]=7125 [DIMETER]=7126 [TRIDENT]=7127 [TESSERACT]=7129 [PENTAGRAM]=7130 [SESTINA]=7131 [HYDRA]=7132 )

FULL=0; FORCE=0
for a in "$@"; do
    [ "$a" = "--full" ] && FULL=1
    [ "$a" = "--force" ] && FORCE=1
done

busy_reason() {   # $1 = port; prints a reason and returns 0 if busy, else 1
    # three signals: an actual print (print_stats), a paper-test session
    # (manual_probe), and - the important one for TUNING - idle_timeout=Printing,
    # which is true whenever klippy is executing ANYTHING (PID tune, bed mesh,
    # screws, twist probing, homing, a dwell). A PID tune sits at print_stats
    # "standby", so without the idle_timeout check a restart would abort it.
    local s
    s=$(curl -s -m3 "http://127.0.0.1:$1/printer/objects/query?print_stats=state&manual_probe=is_active&idle_timeout=state" 2>/dev/null \
        | python3 -c "import sys,json;st=json.load(sys.stdin)['result']['status'];print(st.get('print_stats',{}).get('state','?'), st.get('manual_probe',{}).get('is_active','?'), st.get('idle_timeout',{}).get('state','?'))" 2>/dev/null)
    set -- $s
    case "$1" in printing) echo "printing"; return 0 ;; paused) echo "paused"; return 0 ;; esac
    [ "$2" = "True" ]     && { echo "calibrating (paper test)"; return 0; }
    [ "$3" = "Printing" ] && { echo "busy (tuning / executing)"; return 0; }
    return 1
}

if [ "$FULL" = "1" ]; then
    echo "restarting chime daemon..."
    sudo systemctl restart sonicpad-chimes
    echo "waiting for the daemon to reconnect (12s)..."
    sleep 12
fi

# input shaping in progress? (flag fresh <10 min) - skip that printer too
shaping_owner=""
if [ -f "$HOME/.shaping" ] && \
   [ $(( $(date +%s) - $(stat -c %Y "$HOME/.shaping" 2>/dev/null || echo 0) )) -lt 600 ]; then
    shaping_owner=$(tr -d '[:space:]' < "$HOME/.shaping" | tr '[:lower:]' '[:upper:]')
fi

touch "$HOME/.fleet_restart"     # daemon: treat the coming onlines as a fleet wave
echo "restarting printers (staggered, fleet order)..."
skipped=""
for S in OMEGA UNICORN DIMETER TRIDENT TESSERACT PENTAGRAM SESTINA HYDRA; do
    [ -f "/etc/systemd/system/klipper-$S.service" ] || continue   # prewired names skip cleanly
    if [ "$FORCE" != "1" ]; then
        if [ "$S" = "$shaping_owner" ]; then
            echo "  SKIP $S - input shaping in progress"
            skipped="$skipped $S"
            continue
        fi
        r=$(busy_reason "${PORT[$S]}")
        if [ -n "$r" ]; then
            echo "  SKIP $S - $r"
            skipped="$skipped $S"
            continue
        fi
    fi
    sudo systemctl restart "klipper-$S" &
    sleep 3
done
wait
if [ -n "$skipped" ]; then
    echo "done. SKIPPED (busy):$skipped"
    echo "  -> they keep the OLD config until restarted. When they're idle, just"
    echo "     run ./restart-all.sh again (it restarts whoever is idle then)."
else
    echo "done - listen for offline then back online, in fleet order"
fi
