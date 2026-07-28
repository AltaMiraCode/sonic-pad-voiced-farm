#!/bin/bash
# cam-timelapse.sh {toggle|frame|end} - SINGLE smart-button print timelapse.
#   toggle : ARM (start capturing from now) <-> DISARM (stop + render). Sounds:
#            cam_record.wav on arm, cam_record_stop.wav on stop.
#   frame  : grab one still IF armed (add to your slicer's on-layer-change gcode)
#   end    : auto-finalize at PRINT_END if still armed (render + disarm)
# Captures from the moment you arm it until the print ends (auto) OR you press the
# button again. Frames are numbered GAPLESSLY so the render uses a plain %06d
# sequence (no ffmpeg glob dependency). Files -> ~/timelapses.
PORT="${CAM_PORT:-8080}"
FDIR="$HOME/.timelapse_frames"
ODIR="$HOME/timelapses"; mkdir -p "$ODIR"
CNTF="$FDIR/.count"
ACTIVE="$HOME/.timelapse_active"
FPS_OUT="${TL_FPS:-20}"
CHIME="$HOME/play_chime.sh"; SND="$HOME/cam-chimes"
chime(){ "$CHIME" "$SND/$1" >/dev/null 2>&1 & }
say(){ "$HOME/say.sh" "$*" >/dev/null 2>&1; }

armed(){ [ -f "$ACTIVE" ]; }

dorender(){
    cnt=$(ls "$FDIR"/f_*.jpg 2>/dev/null | wc -l)
    if [ "${cnt:-0}" -lt 2 ]; then echo "not enough frames ($cnt) - nothing to render"; return 0; fi
    OUT="$ODIR/timelapse_$(date +%Y%m%d_%H%M%S).mp4"
    setsid "$0" _render "$OUT" </dev/null >/dev/null 2>&1 &     # detach: encode freely, announce when done
    echo "rendering $cnt frames -> $OUT (detached)"
}

arm(){
    rm -rf "$FDIR"; mkdir -p "$FDIR"; echo 0 > "$CNTF"; : > "$ACTIVE"
    chime cam_record.wav; echo "timelapse armed - capturing until print end or next press"
}
disarm(){                      # manual stop: sound + render now
    rm -f "$ACTIVE"; chime cam_record_stop.wav; dorender
}

case "$1" in
  toggle) armed && disarm || arm ;;
  frame)
    armed || exit 0                                    # only capture while armed
    [ -d "$FDIR" ] || { mkdir -p "$FDIR"; echo 0 > "$CNTF"; }
    n=$(cat "$CNTF" 2>/dev/null || echo 0)
    printf -v fn "%06d" "$n"
    curl -s -m5 "http://127.0.0.1:$PORT/snapshot" -o "$FDIR/f_$fn.jpg" 2>/dev/null
    if [ -s "$FDIR/f_$fn.jpg" ]; then echo $((n+1)) > "$CNTF"; else rm -f "$FDIR/f_$fn.jpg"; fi
    ;;
  end)                                                 # auto-finalize at print end
    armed || exit 0
    rm -f "$ACTIVE"; chime cam_record_stop.wav; dorender
    ;;
  _render)
    OUT="$2"
    if ffmpeg -nostdin -y -start_number 0 -framerate "$FPS_OUT" -i "$FDIR/f_%06d.jpg" \
         -c:v libx264 -preset veryfast -pix_fmt yuv420p -movflags +faststart "$OUT" \
         >/tmp/cam-timelapse.log 2>&1; then
        say "timelapse saved"
    else
        say "timelapse render failed"
    fi
    ;;
  *) echo "usage: $0 {toggle|frame|end}"; exit 1 ;;
esac
