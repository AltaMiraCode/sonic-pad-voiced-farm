#!/bin/bash
# usb-watch.sh - the farm USB fabric watcher. ONE poll loop, TWO jobs.
#
# CAMERAS (device identity): a UVC cam carries a real serial, so it can be known
#   wherever it's plugged. Default = one camera on /dev/video0 -> shared farm
#   stream on :8080 (byte-identical to the old cam-watch). ~/cameras.conf can map
#   additional cameras to their own ustreamer ports + Fluidd entries.
#
# PRINTERS (position identity): the CH340 boards are indistinguishable except by
#   which port they're on, so this side ONLY flags a board that appears on an
#   UNCLAIMED port ("unknown printer connected") and - only if armed via the
#   ~/.usb_autobind flag - runs port-assign.sh auto to bind it. Claimed-port
#   connect/disconnect is left SILENT here: the chime daemon already narrates
#   those from Moonraker, so announcing them again would double up.
#
# Replaces cam-watch.sh. Poll-based (no udev dependency, same as cam-watch was),
# and boot-guarded so it never announces the fleet already present at startup.
#
# Usage:
#   usb-watch.sh            run the watch loop (systemd does this)
#   usb-watch.sh --once     one scan: report what's present + what it WOULD do,
#                           take NO actions (safe validation on a live fleet)

PLAY="$HOME/play_chime.sh"
SAY="$HOME/say.sh"
CAMSND="$HOME/cam-chimes"
BYPATH=/dev/serial/by-path
CAMCONF="$HOME/cameras.conf"
AUTOBIND_FLAG="$HOME/.usb_autobind"
CAM_RES="${CAM_RES:-1280x720}"; CAM_FPS="${CAM_FPS:-10}"
declare -A PORT=( [OMEGA]=7128 [UNICORN]=7125 [DIMETER]=7126 [TRIDENT]=7127 [TESSERACT]=7129 [PENTAGRAM]=7130 [SESTINA]=7131 [HYDRA]=7132 )
ORDER="OMEGA UNICORN DIMETER TRIDENT TESSERACT PENTAGRAM SESTINA HYDRA"

ONCE=0; [ "$1" = "--once" ] && ONCE=1
say(){  [ "$ONCE" = 1 ] && { echo "  WOULD SAY: $*"; return; }; "$SAY" "$@" >/dev/null 2>&1; }
chime(){ [ "$ONCE" = 1 ] && { echo "  WOULD CHIME: $1"; return; }; "$PLAY" "$CAMSND/$1" >/dev/null 2>&1; }

# ------------------------------- CAMERA SIDE -------------------------------
cam_running(){ pgrep -f "ustreamer .*--port=$1" >/dev/null 2>&1; }
cam_start(){   # $1=/dev/videoN  $2=port
    [ "$ONCE" = 1 ] && { echo "  WOULD START ustreamer $1 -> :$2"; return; }
    cam_running "$2" && return 0
    setsid nice -n 10 ustreamer --device="$1" --host=0.0.0.0 --port="$2" \
        --resolution="$CAM_RES" --desired-fps="$CAM_FPS" --format=MJPEG \
        --drop-same-frames=30 --slowdown --device-timeout=2 --device-error-delay=3 \
        >/tmp/ustreamer-$2.log 2>&1 < /dev/null &
}
cam_stop(){ [ "$ONCE" = 1 ] && { echo "  WOULD STOP ustreamer :$1"; return; }; pkill -f "ustreamer .*--port=$1" 2>/dev/null; }

# resolve a /dev/videoN -> "name port". by-id serial first (true device identity),
# then by-path, matched against ~/cameras.conf; default = farm on :8080.
cam_lookup(){   # $1 = /dev/videoN  -> echoes "role port"
    local dev="$1" key role port line
    # find this dev's by-id and by-path keys
    local idkey="" pathkey=""
    for l in /dev/v4l/by-id/*; do [ -e "$l" ] && [ "$(readlink -f "$l")" = "$(readlink -f "$dev")" ] && idkey="$(basename "$l")"; done
    for l in /dev/v4l/by-path/*; do [ -e "$l" ] && [ "$(readlink -f "$l")" = "$(readlink -f "$dev")" ] && pathkey="$(basename "$l")"; done
    if [ -f "$CAMCONF" ]; then
        while read -r key role port; do
            [ -z "$key" ] && continue; case "$key" in \#*) continue;; esac
            if [ "$key" = "$idkey" ] || [ "$key" = "$pathkey" ]; then echo "$role $port"; return; fi
        done < "$CAMCONF"
    fi
    echo "farm 8080"   # default: first/only camera is the shared farm view
}

# --------------------------------- STATE ----------------------------------
declare -A CAM_ON     # port -> dev currently streaming
declare -A SER_SEEN   # by-path -> 1 present last scan

claimed_name(){   # $1 = by-path  -> printer owning it (via its config), else ""
    local P s
    for P in $ORDER; do
        [ -d "$HOME/printer_${P}_data/config" ] || continue
        s=$(grep -m1 '^serial: /dev/' "$HOME/printer_${P}_data/config/printer.cfg" 2>/dev/null | sed 's/serial:[[:space:]]*//')
        [ "$s" = "$1" ] && { echo "$P"; return; }
    done
}
missing_count(){  # printers whose configured board is absent
    local P s n=0
    for P in $ORDER; do
        [ -d "$HOME/printer_${P}_data/config" ] || continue
        s=$(grep -m1 '^serial: /dev/' "$HOME/printer_${P}_data/config/printer.cfg" 2>/dev/null | sed 's/serial:[[:space:]]*//')
        [ -n "$s" ] && [ ! -e "$s" ] && n=$((n+1))
    done
    echo "$n"
}

scan_cameras(){
    local dev roleport role port
    # start streams for present cameras
    for dev in /dev/video0 /dev/video1 /dev/video2 /dev/video3; do
        [ -e "$dev" ] || continue
        # skip metadata-only nodes: only devices that can capture (heuristic: video0-style even nodes on cheap cams).
        roleport=$(cam_lookup "$dev"); role=${roleport%% *}; port=${roleport##* }
        if ! cam_running "$port"; then
            cam_start "$dev" "$port"
            [ "$BASELINE" = 1 ] || { chime cam_online.wav; [ "$ONCE" = 1 ] && echo "  camera $dev -> $role :$port"; }
            [ "$ONCE" = 1 ] || sleep 1
            "$HOME/register-webcam.sh" "${role^}" "$port" >/dev/null 2>&1 &
        fi
        CAM_ON[$port]="$dev"
    done
    # stop streams whose camera vanished
    for port in "${!CAM_ON[@]}"; do
        dev="${CAM_ON[$port]}"
        if [ ! -e "$dev" ]; then
            cam_stop "$port"; unset "CAM_ON[$port]"
            [ "$BASELINE" = 1 ] || chime cam_offline.wav
        fi
    done
}

scan_serial(){
    local f name
    declare -A now=()
    for f in "$BYPATH"/*; do
        [ -e "$f" ] || continue
        now["$f"]=1
        if [ -z "${SER_SEEN[$f]}" ]; then
            # newly appeared
            name=$(claimed_name "$f")
            if [ -n "$name" ]; then
                # a known printer's board reconnected - the chime daemon narrates
                # this from Moonraker, so stay silent here to avoid doubling up.
                [ "$ONCE" = 1 ] && echo "  serial $f -> $name (claimed; silent, chime daemon owns it)"
            else
                # a board on an unclaimed port
                [ "$BASELINE" = 1 ] || say "unknown printer connected"
                [ "$ONCE" = 1 ] && echo "  serial $f -> UNCLAIMED"
                if [ -f "$AUTOBIND_FLAG" ] && [ "$(missing_count)" = "1" ]; then
                    if [ "$ONCE" = 1 ]; then echo "    WOULD auto-bind (one printer missing, ~/.usb_autobind armed)"
                    else "$HOME/port-assign.sh" auto >/dev/null 2>&1; fi
                elif [ "$ONCE" = 1 ]; then
                    echo "    (no auto-bind: flag $( [ -f "$AUTOBIND_FLAG" ] && echo armed || echo absent ), $(missing_count) printers missing)"
                fi
            fi
        fi
    done
    # removals: claimed-port loss stays silent (chime daemon handles); just forget it
    for f in "${!SER_SEEN[@]}"; do [ -z "${now[$f]}" ] && [ "$ONCE" = 1 ] && echo "  serial $f removed"; done
    # commit
    SER_SEEN=(); for f in "${!now[@]}"; do SER_SEEN["$f"]=1; done
}

# --------------------------------- RUN ------------------------------------
if [ "$ONCE" = 1 ]; then
    echo "=== usb-watch --once (report only, no actions) ==="
    echo "-- cameras --"; BASELINE=0; scan_cameras
    [ -e /dev/video0 ] || echo "  (no /dev/video* present)"
    echo "-- serial (printers) --"; BASELINE=0; SER_SEEN=(); scan_serial
    echo "-- summary --"; echo "  printers missing their board: $(missing_count)"
    echo "  autobind flag: $( [ -f "$AUTOBIND_FLAG" ] && echo ARMED || echo absent )"
    exit 0
fi

# live loop: first pass is a silent baseline (don't announce what's already here)
BASELINE=1; scan_cameras; scan_serial; BASELINE=0
while :; do
    scan_cameras
    scan_serial
    sleep 2
done
