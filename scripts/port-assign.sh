#!/bin/bash
# port-assign.sh - map a plugged-in printer board to a printer identity, the
# ten-second fix for "I plugged it into a different port" and the join step
# for a brand-new printer. (The boards are byte-identical CH340s with no
# serial numbers, so identity IS the physical port - this tool rewrites a
# printer's [mcu] serial path to whatever port its board is actually on.)
#
#   port-assign.sh                    show the port <-> printer map + unclaimed ports
#   port-assign.sh auto               assign the unclaimed port to the FIRST printer
#                                     (in fleet number order) whose board is missing
#   port-assign.sh TRIDENT            assign to a specific printer (refused if that
#                                     printer's board is still connected elsewhere)
#   port-assign.sh TRIDENT <by-path>  fully explicit - overrides the guards
#
# After assigning it backs up the config, rewrites the serial line, announces,
# and firmware-restarts that printer so it reconnects immediately.
declare -A PORT=( [OMEGA]=7128 [UNICORN]=7125 [DIMETER]=7126 [TRIDENT]=7127 [TESSERACT]=7129 [PENTAGRAM]=7130 [SESTINA]=7131 [HYDRA]=7132 )
ORDER="OMEGA UNICORN DIMETER TRIDENT TESSERACT PENTAGRAM SESTINA HYDRA"
BYPATH=/dev/serial/by-path

conf_serial() {   # the /dev serial path configured for printer $1 ("" if none)
    grep -m1 '^serial: /dev/' "$HOME/printer_$1_data/config/printer.cfg" 2>/dev/null \
        | sed 's/^serial:[[:space:]]*//'
}

declare -A CLAIMED
for P in $ORDER; do
    [ -d "$HOME/printer_${P}_data/config" ] || continue
    s=$(conf_serial "$P")
    [ -n "$s" ] && CLAIMED["$s"]="$P"
done

unclaimed_ports() {   # ports present but assigned to nobody
    for f in "$BYPATH"/*; do
        [ -e "$f" ] || continue
        [ -z "${CLAIMED[$f]}" ] && echo "$f"
    done
}
missing_printers() {  # printers (fleet order) whose configured board is ABSENT
    for P in $ORDER; do
        [ -d "$HOME/printer_${P}_data/config" ] || continue
        s=$(conf_serial "$P")
        [ -n "$s" ] && [ ! -e "$s" ] && echo "$P"
    done
}

assign() {   # $1 = PRINTER  $2 = by-path
    local T="$1" path="$2"
    local namesay; namesay=$(echo "$T" | tr '[:upper:]' '[:lower:]'); namesay="${namesay^}"
    local CFG="$HOME/printer_${T}_data/config/printer.cfg"
    cp "$CFG" "$CFG.bak"
    python3 - "$CFG" "$path" <<'PY'
import sys
cfg, path = sys.argv[1], sys.argv[2]
lines = open(cfg).read().split("\n")
done = False
for i, ln in enumerate(lines):
    if not done and ln.strip().startswith("serial:") and "/dev/" in ln:
        lines[i] = f"serial: {path}"
        done = True
open(cfg, "w").write("\n".join(lines))
sys.exit(0 if done else 1)
PY
    if [ $? -ne 0 ]; then echo "no 'serial: /dev/...' line found in $CFG - edit it manually"; exit 1; fi
    echo "$T -> $path (backup: printer.cfg.bak)"
    "$HOME/say.sh" "$namesay port assigned. restarting" >/dev/null 2>&1
    curl -s -m5 -X POST "http://127.0.0.1:${PORT[$T]}/printer/firmware_restart" >/dev/null 2>&1
    echo "restarted - listen for '$namesay back online'"
}

# ---------- list (default) ----------
if [ -z "$1" ]; then
    echo "== printer -> port map =="
    for P in $ORDER; do
        [ -d "$HOME/printer_${P}_data/config" ] || continue
        s=$(conf_serial "$P")
        if [ -z "$s" ]; then st="(no serial configured)"
        elif [ -e "$s" ]; then st="CONNECTED"
        else st="MISSING - board not on this port"
        fi
        printf "  %-10s %s  %s\n" "$P" "${s:-.}" "$st"
    done
    echo "== unclaimed ports (plugged in, no printer assigned) =="
    u=$(unclaimed_ports)
    if [ -n "$u" ]; then echo "$u" | sed 's/^/  /'; else echo "  none"; fi
    echo ""
    echo "auto-fix:  port-assign.sh auto     (first missing printer, in fleet order, gets the port)"
    exit 0
fi

# ---------- auto: first missing printer in fleet order gets the port ----------
if [ "$1" = "auto" ]; then
    u=$(unclaimed_ports); nu=$(echo "$u" | grep -c . )
    m=$(missing_printers); first=$(echo "$m" | head -1)
    if [ -z "$u" ]; then echo "no unclaimed port - is the board plugged in and powered?"; exit 1; fi
    if [ "$nu" -gt 1 ]; then
        echo "several unclaimed ports - assign one at a time, explicitly:"
        echo "$u" | sed 's/^/  /'
        echo "usage: port-assign.sh <PRINTER> <path>"
        exit 1
    fi
    if [ -z "$first" ]; then
        # nobody's board is missing -> this is a brand-new printer
        for P in $ORDER; do
            [ -d "$HOME/printer_${P}_data/config" ] || { nxt="$P"; break; }
        done
        echo "no printer is missing its board - this looks like a NEW printer."
        echo "create the ${nxt:-next} instance first (ADD-A-PRINTER.md), then re-run: port-assign.sh auto"
        exit 1
    fi
    echo "assigning unclaimed port to $first (first missing, fleet order)"
    assign "$first" "$u"
    exit 0
fi

# ---------- explicit printer ----------
T=$(echo "$1" | tr '[:lower:]' '[:upper:]')
[ -z "${PORT[$T]}" ] && { echo "unknown printer '$1'"; exit 1; }
CFG="$HOME/printer_${T}_data/config/printer.cfg"
[ -f "$CFG" ] || { echo "no config for $T yet - create the instance first (ADD-A-PRINTER.md)"; exit 1; }

path="$2"
cur=$(conf_serial "$T")
if [ -z "$path" ]; then
    # GUARD: never reassign a printer whose board is still connected - the
    # unknown port can't be it. Point at who's actually missing instead.
    if [ -n "$cur" ] && [ -e "$cur" ]; then
        first=$(missing_printers | head -1)
        echo "REFUSED: $T's board is still CONNECTED at $cur."
        [ -n "$first" ] && echo "the missing printer is: $first  ->  port-assign.sh auto   (or: port-assign.sh $first)"
        echo "to override anyway: port-assign.sh $T <path>"
        exit 1
    fi
    u=$(unclaimed_ports); nu=$(echo "$u" | grep -c .)
    [ -z "$u" ] && { echo "no unclaimed port found - is the board plugged in and powered?"; exit 1; }
    if [ "$nu" -gt 1 ]; then
        echo "$nu unclaimed ports - specify one:  port-assign.sh $T <path>"
        echo "$u" | sed 's/^/  /'
        exit 1
    fi
    path="$u"
fi
[ -e "$path" ] || { echo "$path does not exist"; exit 1; }
own="${CLAIMED[$path]}"
if [ -n "$own" ] && [ "$own" != "$T" ]; then
    echo "REFUSED: $path is already assigned to $own (reassign that printer first)"
    exit 1
fi
assign "$T" "$path"
