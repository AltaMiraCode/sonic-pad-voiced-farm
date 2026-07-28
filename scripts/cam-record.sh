#!/bin/bash
# cam-record.sh {toggle|start|stop} - SINGLE smart-button recording of the shared
# farm camera to an mp4. One press starts, next press stops. Sounds:
#   cam_record.wav      on start
#   cam_record_stop.wav on stop
#   cam_failure.wav     if it can't start (no camera stream)
# The ustreamer feed is already MJPEG, so we STREAM-COPY it (-c:v copy, no
# re-encode) -> negligible CPU, safe even during a print. Files -> ~/recordings.
PORT="${CAM_PORT:-8080}"
DIR="$HOME/recordings"; mkdir -p "$DIR"
PIDF="$HOME/.cam_recording.pid"
CURF="$HOME/.cam_recording.file"
CHIME="$HOME/play_chime.sh"; SND="$HOME/cam-chimes"
chime(){ "$CHIME" "$SND/$1" >/dev/null 2>&1 & }

recording(){ [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; }

start(){
    if recording; then echo "already recording"; return 0; fi
    if ! curl -s -m4 -o /dev/null "http://127.0.0.1:$PORT/snapshot"; then
        chime cam_failure.wav; echo "no stream on :$PORT - is the camera connected?"; return 1
    fi
    OUT="$DIR/rec_$(date +%Y%m%d_%H%M%S).mp4"; echo "$OUT" > "$CURF"
    # -f mpjpeg: ustreamer serves a multipart MJPEG stream. -c:v copy muxes frames
    # straight in (no encoding). wallclock timestamps keep playback timing sane.
    setsid nice -n 10 ffmpeg -nostdin -y \
        -use_wallclock_as_timestamps 1 -f mpjpeg -i "http://127.0.0.1:$PORT/stream" \
        -c:v copy -movflags +faststart "$OUT" >/tmp/cam-record.log 2>&1 < /dev/null &
    echo $! > "$PIDF"; sleep 1
    if recording; then
        chime cam_record.wav; echo "recording -> $OUT"
    else
        chime cam_failure.wav; rm -f "$PIDF" "$CURF"
        echo "ffmpeg failed to start (see /tmp/cam-record.log)"; return 1
    fi
}

stop(){
    if ! recording; then echo "not recording"; return 0; fi
    pid=$(cat "$PIDF")
    kill -INT "$pid" 2>/dev/null                 # SIGINT -> ffmpeg finalizes the moov atom cleanly
    for i in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
    kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null   # fallback if it ignored SIGINT
    rm -f "$PIDF"; f=$(cat "$CURF" 2>/dev/null); rm -f "$CURF"
    chime cam_record_stop.wav; echo "saved ${f:-?}"
}

case "$1" in
    toggle) recording && stop || start ;;
    start)  start ;;
    stop)   stop ;;
    *) echo "usage: $0 {toggle|start|stop}"; exit 1 ;;
esac
