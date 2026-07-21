#!/bin/bash
# cal-watch.sh - detached calibration narrator. Watches a calibration from
# OUTSIDE the gcode queue (Moonraker status queries work even while a blocking
# calibration command holds the queue - a delayed_gcode watcher does not).
#
#   cal-watch.sh probe <Name>                 TUNE_PROBE: complete/aborted + auto-save
#   cal-watch.sh twist <Name>                 TUNE_TWIST: per-point lines, complete/
#                                             aborted + auto-save after final ACCEPT
#   cal-watch.sh pid <Name> <heater> <temp>   TUNE_PID_*: first-temperature-reached line
#
# Self-detaches (setsid) so the RUN_SHELL_COMMAND that launches it returns
# instantly. ONE watcher per printer: a new launch supersedes any stale watcher
# (a watcher left over from an errored run must never latch onto a later session).
#
# Accept detection is SECTION-SPECIFIC: it reads save_config_pending_items and
# looks for THIS calibration's config section ("probe" / "axis_twist_compensation"),
# so an unrelated unsaved change (e.g. a panel-run bed mesh) can never fake a
# completion or trigger a save the user didn't ask for.
MODE="$1"; NAME="$2"
declare -A PORT=( [OMEGA]=7128 [UNICORN]=7125 [DIMETER]=7126 [TRIDENT]=7127 [TESSERACT]=7129 [PENTAGRAM]=7130 [SESTINA]=7131 [HYDRA]=7132 )
T=$(echo "$NAME" | tr '[:lower:]' '[:upper:]'); P="${PORT[$T]}"
[ -z "$P" ] && exit 1

if [ -z "$CAL_DETACHED" ]; then
    CAL_DETACHED=1 setsid "$0" "$@" </dev/null >/dev/null 2>&1 &
    exit 0
fi

# supersede any previous watcher for this printer
LOCK="/tmp/calwatch.$T.pid"
old=$(cat "$LOCK" 2>/dev/null)
if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    kill "$old" 2>/dev/null
    sleep 1
fi
echo $$ > "$LOCK"
trap '[ "$(cat "$LOCK" 2>/dev/null)" = "$$" ] && rm -f "$LOCK"' EXIT

say() { "$HOME/narrate.sh" "$@" >/dev/null 2>&1; }   # honors the narration toggle
gc()  { curl -s -m30 -X POST "http://127.0.0.1:$P/printer/gcode/script?script=$1" >/dev/null 2>&1; }

case "$MODE" in probe) KEY="probe" ;; twist) KEY="axis_twist_compensation" ;; *) KEY="" ;; esac

ACT=""; PEND=""
read_state() {   # ACT = manual session open; PEND = OUR section has an unsaved change
    local s
    s=$(curl -s -m2 "http://127.0.0.1:$P/printer/objects/query?manual_probe=is_active&configfile=save_config_pending_items" \
        | python3 -c "
import sys, json
st = json.load(sys.stdin)['result']['status']
items = st['configfile'].get('save_config_pending_items') or {}
print(st['manual_probe']['is_active'], 'True' if '$KEY' in items else 'False')" 2>/dev/null)
    [ -z "$s" ] && return 1
    ACT=${s%% *}; PEND=${s##* }
}
# hold while the session is open; tolerate up to 10 consecutive failed reads
# (a Moonraker blip must not read as a session transition)
hold_session() {
    local fails=0
    while :; do
        if read_state; then
            fails=0
            [ "$ACT" != "True" ] && return 0
        else
            fails=$((fails+1)); [ "$fails" -ge 10 ] && return 1
        fi
        sleep 1
    done
}
# after a close, give the pending flag a few seconds to appear (accept race)
settle_pend() { for i in 1 2 3 4 5; do read_state; [ "$PEND" = "True" ] && return 0; sleep 1; done; return 1; }

NUM=(zero one two three four five)

case "$MODE" in
  pid)
    H="$3"; TGT="$4"
    WHAT="hot end"; [ "$H" = "heater_bed" ] && WHAT="bed"
    for i in $(seq 1 1200); do
        t=$(curl -s -m2 "http://127.0.0.1:$P/printer/objects/query?$H=temperature" \
            | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['status']['$H']['temperature'])" 2>/dev/null)
        if [ -n "$t" ] && python3 -c "import sys;sys.exit(0 if float('$t') >= float('$TGT') - 2 else 1)" 2>/dev/null; then
            say "$NAME $WHAT temperature reached. holding temperature"
            exit 0
        fi
        sleep 1
    done
    ;;

  probe)
    read_state
    [ "$PEND" = "True" ] && exit 0               # our section ALREADY pending: no
                                                 # clean signal - stand down silent
    for i in $(seq 1 180); do read_state && [ "$ACT" = "True" ] && break; sleep 1; done
    [ "$ACT" != "True" ] && exit 0               # never started - stay quiet
    hold_session || exit 0
    if settle_pend; then
        say "$NAME probe calibration complete"
        gc "SAVE_CONFIG"                          # wrapper announces save + restart
    else
        say "$NAME probe calibration aborted"
    fi
    ;;

  twist)
    read_state
    [ "$PEND" = "True" ] && exit 0               # pre-existing twist pending: stand down
    point=1                                       # macro already said "probing point one"
    while :; do
        # wait for this point's paper-test session to open (probing between
        # points can be slow with tolerance retries - allow 120s)
        opened=0
        for i in $(seq 1 120); do
            read_state || { sleep 1; continue; }
            [ "$ACT" = "True" ] && { opened=1; break; }
            [ "$PEND" = "True" ] && break         # completed while we waited
            sleep 1
        done
        if [ "$opened" != "1" ]; then
            read_state
            [ "$PEND" = "True" ] && break         # final accept landed - finish up
            say "$NAME twist tuning aborted"
            exit 0
        fi
        say "$NAME please paper test this point"
        hold_session || exit 0
        settle_pend && break                      # final point ACCEPTed - done
        # ACCEPTed but not final: the machine is heading to the next point NOW
        point=$((point+1))
        say "$NAME probing point ${NUM[$point]:-$point}"
    done
    say "$NAME twist tuning complete"
    gc "SAVE_CONFIG"
    ;;
esac
exit 0
