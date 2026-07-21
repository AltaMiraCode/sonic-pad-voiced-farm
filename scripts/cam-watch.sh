#!/bin/bash
# cam-watch.sh - farm camera hotplug watcher (successor to argus-watch.sh;
# the Argus persona is retired - camera events play CHIMES, not voice).
#
# Polls for the USB camera. When it appears: starts ustreamer (one shared
# stream for all four printers) and plays the cam-online chime. When it's
# unplugged: stops the stream and plays the cam-offline chime. Chimes bypass
# the farm voice lock by design (they may overlap speech, like all chimes).
#
# One camera, one ustreamer, one URL -> every printer's Fluidd points at it
# (see register-webcam.sh). The camera is a shared HTTP service, not tied to
# any Klipper instance, so there's none of the CH340 port-identity problem.
CHIME="$HOME/play_chime.sh"
SND="$HOME/cam-chimes"
DEV="${CAM_DEV:-/dev/video0}"
PORT="${CAM_PORT:-8080}"
RES="${CAM_RES:-1280x720}"
FPS="${CAM_FPS:-10}"
chime(){ "$CHIME" "$SND/$1" >/dev/null 2>&1; }

running(){ pgrep -f "ustreamer .*--port=$PORT" >/dev/null 2>&1; }
start_stream(){
    running && return 0
    # --slowdown drops to <=1fps when nobody's watching (big CPU save on the R818);
    # native MJPEG passthrough means no re-encoding. niced so it can never starve
    # a printing klippy into "Timer too close".
    setsid nice -n 10 ustreamer \
        --device="$DEV" --host=0.0.0.0 --port="$PORT" \
        --resolution="$RES" --desired-fps="$FPS" --format=MJPEG \
        --drop-same-frames=30 --slowdown \
        --device-timeout=2 --device-error-delay=3 \
        >/tmp/ustreamer.log 2>&1 < /dev/null &
}
stop_stream(){ pkill -f "ustreamer .*--port=$PORT" 2>/dev/null; }

present=-1                       # -1 = unknown (boot); avoids a spurious boot "offline"
while :; do
    if [ -e "$DEV" ]; then now=1; else now=0; fi
    if [ "$now" != "$present" ]; then
        if [ "$now" = "1" ]; then
            start_stream; sleep 1; chime cam_online.wav
        else
            stop_stream
            [ "$present" = "1" ] && chime cam_offline.wav   # only if it was really here
        fi
        present="$now"
    elif [ "$now" = "1" ]; then
        start_stream                 # keepalive: silently relaunch if it died
    fi
    sleep 2
done
