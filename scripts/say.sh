#!/bin/bash
# say.sh — speak text through the Sonic Pad speaker.
# Plays the pre-rendered WAV from ~/voicebank/ if it exists. DYNAMIC lines
# (filenames, computed times - anything not in the bank) are synthesized LIVE
# with the speaking printer's own Piper voice, keyed off the first word; only
# Omega/System lines (and anything else unmatched) fall back to espeak, which
# IS Omega's voice. Forwards an optional leading --force to play_chime.sh so
# forced (thermal) alerts bypass the master mute.
# Usage: say.sh [--force] Omega print complete

FORCEARG=""
if [ "$1" = "--force" ]; then FORCEARG="--force"; shift; fi

# VOICE SERIALIZATION: one voice at a time, farm-wide. EVERY voice - the
# daemon's queue, macro narration, cal-watch, the shaper handshake - flows
# through this script, so this single lock keeps voices from talking over
# each other (dmix would happily mix them). Chimes bypass say.sh and still
# overlap freely, by design. The lock is taken AFTER any synthesis below so
# a slow Piper render never holds the farm silent; it rides through the exec
# into aplay and releases the moment playback ends.
KEY=$(echo "$*" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
F="$HOME/voicebank/$KEY.wav"
if [ -f "$F" ]; then
    exec 9>/tmp/.voice_lock
    flock -w 30 9 2>/dev/null
    exec "$HOME/play_chime.sh" $FORCEARG "$F"
fi

# dynamic line: pick the printer's live voice from the leading name
first=$(echo "$*" | awk '{print tolower($1)}')
PIPER="$HOME/piper/piper/piper"; V="$HOME/piper/voices"
MODEL=""; SARG=""
case "$first" in
  unicorn) MODEL="$V/en_US-amy-low.onnx" ;;
  dimeter) MODEL="$V/en_GB-alan-low.onnx" ;;
  trident) MODEL="$V/en_US-libritts_r-medium.onnx"; SARG="-s 136 --length-scale 1.1" ;;
  tesseract) MODEL="$V/en_GB-jenny_dioco-medium.onnx" ;;
  pentagram) MODEL="$V/en_US-joe-medium.onnx" ;;
  sestina)   MODEL="$V/en_US-kristin-medium.onnx" ;;
  hydra)     MODEL="$V/en_GB-northern_english_male-medium.onnx" ;;
esac

# unique temp file per call: concurrent fallbacks must not overwrite each other
T=$(mktemp /tmp/tts.XXXXXX)
if [ -n "$MODEL" ] && [ -f "$MODEL" ] && [ -x "$PIPER" ]; then
    # nice'd: live synthesis must never steal CPU from a printing klippy
    echo "$*" | nice -n 19 "$PIPER" -m "$MODEL" $SARG -f "$T" -q >/dev/null 2>&1
fi
# piper missing/failed (or an Omega/System line): espeak = the robot voice
[ -s "$T" ] || espeak-ng -v en-us -s 150 -p 45 -a 190 -w "$T" "$*" 2>/dev/null

exec 9>/tmp/.voice_lock
flock -w 30 9 2>/dev/null
"$HOME/play_chime.sh" $FORCEARG "$T"
rc=$?
rm -f "$T"
exit $rc
