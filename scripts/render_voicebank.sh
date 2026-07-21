#!/bin/bash
# render_voicebank.sh — render every announcement phrase into ~/voicebank/.
# Re-run any time after editing the cast or phrase lists.
#
# FINAL CAST (July 19, 2026):
#   Omega   - espeak-ng robot, -s 150 -p 45
#   Unicorn - en_US-amy-low                    (bright female)
#   Dimeter - en_GB-alan-low                   (British male)
#   Trident - en_US-libritts_r-medium, spk 136 (split tempo: name 1.5 / body 1.1)
#   System  - Omega IS the system: farm-wide alerts use Omega's robot voice,
#             spoken without a printer name (the farm's onboard computer).

set -e
# run at LOWEST priority: a full render pegs a core for minutes, and a printing
# klippy starved of CPU throws "Timer too close" - rendering must always yield
if [ -z "$RENICED" ]; then exec env RENICED=1 nice -n 19 "$0" "$@"; fi
PIPER=~/piper/piper/piper
V=~/piper/voices
mkdir -p ~/voicebank

declare -A ESPEAK=(
  [Omega]="-v en-us -s 150 -p 45"
  [System]="-v en-us -s 150 -p 45"   # Omega is the system - same voice
)
declare -A VOICE=(
  [Unicorn]=en_US-amy-low
  [Dimeter]=en_GB-alan-low
  [Trident]=en_US-libritts_r-medium
  [Tesseract]=en_GB-jenny_dioco-medium           # prewired printer 5 / "4" (British female)
  [Pentagram]=en_US-joe-medium                   # prewired printer 6 / "5" (warm US male)
  [Sestina]=en_US-kristin-medium                 # prewired printer 7 / "6" (US female)
  [Hydra]=en_GB-northern_english_male-medium     # prewired printer 8 / "7" (northern English male)
)
declare -A SPEAKER=( [Trident]=136 )
declare -A LENGTH=()
declare -A NAME_LEN=( [Trident]=1.5 )
declare -A BODY_LEN=( [Trident]=1.1 )

# ACTIVE CAST - add Tesseract / Pentagram / Sestina / Hydra here when their instances exist (their
# voices and phrase sets render automatically on the next run; nothing else
# in this script needs touching). See ADD-A-PRINTER.md.
CAST="Omega Unicorn Dimeter Trident"

# per-printer phrases (rendered name-first, in every printer voice)
PHRASES=("preheating" "starting print" "print complete" "paused" "resuming" \
         "print canceled" "error" "offline" "back online" "powering off" \
         "filament runout" "print file received" \
         "filament detected. moving print head for feeding" \
         "feed filament into print head. press x stop on the print head bar to feed" \
         "feeding filament" \
         "press x stop on the print head bar to purge and continue print" \
         "feed timed out" \
         "configuration save failed" "port assigned. restarting" "is printing. input shaping unavailable" \
         "is waiting for its accelerometer move" \
         "print halfway" "first layer complete" "cooled temperature safe" \
         "bed temperature reached" "bed temperature reached. holding" \
         "nozzle temperature reached" \
         "leveling bed" "probing print area" "purging" \
         "starting bed leveling process" "bed leveling complete" \
         "light on" "light off" \
         "motors released" "parking nozzle" "nozzle parked" \
         "homing all axis" "homing x and y axis" "homing x axis" \
         "homing y axis" "homing z axis" \
         "P I D tuning bed" "bed P I D tuning complete" \
         "P I D tuning hot end" "hot end P I D tuning complete" \
         "hot end temperature reached. holding temperature" \
         "bed temperature reached. holding temperature" \
         "calibrating probe" "probe calibration complete" "probe calibration aborted" \
         "starting twist tuning" "twist tuning complete" "twist tuning aborted" \
         "probing point one" "probing point two" "probing point three" \
         "screw tilt adjust" "screw tilt adjust complete" \
         "waiting on nozzle temperature" \
         "starting resonance input shaping process" "claiming accelerometer" \
         "relinquishing accelerometer" "restarting" \
         "starting x axis resonance input shaping" \
         "x axis test complete. move accelerometer to bed. then press x stop on the print head bar for y axis" \
         "resuming. starting y axis resonance input shaping" \
         "y axis test complete" \
         "input shaping model created" "resonance input shaping complete" \
         "input shaping failed" "input shaping timed out and was canceled")

# content-only callouts: the KEY is name-prefixed so each plays in THIS printer's
# voice, but the spoken audio is only the phrase itself (no name) - the frequency
# ticks, the "accelerometer claimed" confirmation, and the "calculating" line.
FREQ_PHRASES=("accelerometer claimed" "testing frequencies. 5 hertz" "25 hertz" \
              "50 hertz" "test halfway" "100 hertz" "125 hertz" \
              "calculating input shaping model. please wait" \
              "please paper test this point" "saving configuration")

# system phrases (System voice, literal - no printer name)
SYS_PHRASES=("low disk space" "update available" "wifi reconnected" "unknown printer connected")

render_one() {  # $1=model-or-espeak-args  $2=out  $3=text  $4=is_espeak  $5=sargs
    if [ "$4" = "1" ]; then
        espeak-ng $1 -a 190 -w "$2" "$3" 2>/dev/null
    else
        echo "$3" | "$PIPER" -m "$1" $5 -f "$2" -q >/dev/null 2>&1
    fi
}

for NAME in $CAST; do
    if [ -n "${ESPEAK[$NAME]}" ]; then IS_ESP=1; MODEL="${ESPEAK[$NAME]}"; SARG=""
    else IS_ESP=0; MODEL="$V/${VOICE[$NAME]}.onnx"; SARG=""; [ -n "${SPEAKER[$NAME]}" ] && SARG="-s ${SPEAKER[$NAME]}"; fi

    for ph in "${PHRASES[@]}"; do
        TEXT="$NAME $ph"
        KEY=$(echo "$TEXT" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
        OUT=~/voicebank/$KEY.wav
        echo "  $TEXT"
        if [ "$IS_ESP" = "0" ] && [ -n "${NAME_LEN[$NAME]}" ]; then
            echo "$NAME" | "$PIPER" -m "$MODEL" $SARG --length-scale "${NAME_LEN[$NAME]}" -f /tmp/_n.wav -q >/dev/null 2>&1
            echo "$ph"   | "$PIPER" -m "$MODEL" $SARG --length-scale "${BODY_LEN[$NAME]}" -f /tmp/_b.wav -q >/dev/null 2>&1
            python3 -c "import wave;o=wave.open('$OUT','w');a=wave.open('/tmp/_n.wav');b=wave.open('/tmp/_b.wav');o.setparams(a.getparams());o.writeframes(a.readframes(a.getnframes()));o.writeframes(b.readframes(b.getnframes()));o.close()"
        else
            LARG=""; [ "$IS_ESP" = "0" ] && [ -n "${LENGTH[$NAME]}" ] && LARG="--length-scale ${LENGTH[$NAME]}"
            render_one "$MODEL" "$OUT" "$TEXT" "$IS_ESP" "$SARG $LARG"
        fi
    done

    # frequency callouts: KEY is name-prefixed (voice selection) but the spoken
    # content is only the frequency, so you hear "25 hertz" in this printer's voice.
    for fph in "${FREQ_PHRASES[@]}"; do
        KEY=$(echo "$NAME $fph" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
        OUT=~/voicebank/$KEY.wav
        echo "  [$NAME voice] $fph"
        if [ "$IS_ESP" = "0" ] && [ -n "${BODY_LEN[$NAME]}" ]; then
            echo "$fph" | "$PIPER" -m "$MODEL" $SARG --length-scale "${BODY_LEN[$NAME]}" -f "$OUT" -q >/dev/null 2>&1
        else
            LARG=""; [ "$IS_ESP" = "0" ] && [ -n "${LENGTH[$NAME]}" ] && LARG="--length-scale ${LENGTH[$NAME]}"
            render_one "$MODEL" "$OUT" "$fph" "$IS_ESP" "$SARG $LARG"
        fi
    done

    # thermal alert: warning brackets both ends, name embedded, printer's own voice.
    # For split-tempo printers (Trident) the bracketing "warning warning" is
    # slowed to 1.5 and the middle stays at his body tempo; stitched to one clip.
    TEXT="warning warning $NAME heating failed warning warning"
    KEY=$(echo "$TEXT" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
    OUT=~/voicebank/$KEY.wav
    echo "  $TEXT"
    if [ "$IS_ESP" = "0" ] && [ -n "${NAME_LEN[$NAME]}" ]; then
        echo "warning warning"       | "$PIPER" -m "$MODEL" $SARG --length-scale 1.5 -f /tmp/_w1.wav -q >/dev/null 2>&1
        echo "$NAME heating failed"  | "$PIPER" -m "$MODEL" $SARG --length-scale "${BODY_LEN[$NAME]}" -f /tmp/_m.wav -q >/dev/null 2>&1
        echo "warning warning"       | "$PIPER" -m "$MODEL" $SARG --length-scale 1.5 -f /tmp/_w2.wav -q >/dev/null 2>&1
        python3 -c "
import wave
o=wave.open('$OUT','w')
parts=['/tmp/_w1.wav','/tmp/_m.wav','/tmp/_w2.wav']
a=wave.open(parts[0]); o.setparams(a.getparams()); a.close()
for pp in parts:
    w=wave.open(pp); o.writeframes(w.readframes(w.getnframes())); w.close()
o.close()"
    else
        render_one "$MODEL" "$OUT" "$TEXT" "$IS_ESP" "$SARG"
    fi
done

# BARE PRINTER-NAME clips: each printer saying just its own name, into
# ~/voicebank/<name>.wav. These are general, reusable assets - the shows'
# roll-call (rangers.sh) and the race winner reveal (race.sh) call
# `say.sh <Name>`, which resolves straight to these. Rendered in each printer's
# own voice, with the show's "!" intonation; split-tempo printers (Trident) get
# their name at the slow name-length. The normalize pass below levels them.
for NAME in $CAST; do
    OUT=~/voicebank/$(echo "$NAME" | tr '[:upper:]' '[:lower:]').wav
    echo "  name clip: $NAME"
    if [ -n "${ESPEAK[$NAME]}" ]; then
        espeak-ng ${ESPEAK[$NAME]} -a 190 -w "$OUT" "$NAME!" 2>/dev/null
    else
        SARG=""; [ -n "${SPEAKER[$NAME]}" ] && SARG="-s ${SPEAKER[$NAME]}"
        LARG=""; [ -n "${NAME_LEN[$NAME]}" ] && LARG="--length-scale ${NAME_LEN[$NAME]}"
        echo "$NAME!" | "$PIPER" -m "$V/${VOICE[$NAME]}.onnx" $SARG $LARG -f "$OUT" -q >/dev/null 2>&1
    fi
done

# system PA phrases (prefixed "System" so they're unmistakable)
for ph in "${SYS_PHRASES[@]}"; do
    TEXT="System $ph"
    KEY=$(echo "$TEXT" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
    echo "  $TEXT"
    espeak-ng ${ESPEAK[System]} -a 190 -w ~/voicebank/$KEY.wav "$TEXT" 2>/dev/null
done

# fleet-wide lines in the System (Omega) voice, spoken WITHOUT the "System"
# prefix - the farm's computer announcing farm-wide actions ("all lights on"),
# plus the overload guardian's alert (bracketed with "warning" both ends for
# urgency, like the thermal alarm).
for ph in "all lights on" "all lights off" "start your engines" \
          "warning. system at overload. offload devices to reduce system strain. warning"; do
    KEY=$(echo "$ph" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
    echo "  [System voice] $ph"
    espeak-ng ${ESPEAK[System]} -a 190 -w ~/voicebank/$KEY.wav "$ph" 2>/dev/null
done

rm -f /tmp/_n.wav /tmp/_b.wav /tmp/_w1.wav /tmp/_m.wav /tmp/_w2.wav

# peak-normalize every clip to ~-0.3 dBFS so speech is as loud as the chimes
# (Piper output runs quiet; this is the biggest perceived-loudness win since
# the LINEOUT hardware is already maxed). Cap boost at 4x to avoid blowing up
# near-silent files.
echo "  normalizing loudness..."
python3 - <<'PY'
import wave, audioop, glob, os
for f in glob.glob(os.path.expanduser('~/voicebank/*.wav')):
    try:
        w = wave.open(f, 'rb'); p = w.getparams()
        d = w.readframes(w.getnframes()); w.close()
        mx = audioop.max(d, p.sampwidth)
        if mx > 0:
            factor = min(4.0, int(0.97 * 32767) / mx)
            if abs(factor - 1.0) > 0.01:
                d = audioop.mul(d, p.sampwidth, factor)
        o = wave.open(f, 'wb'); o.setparams(p); o.writeframes(d); o.close()
    except Exception as e:
        print("  skip", os.path.basename(f), e)
PY

echo "Bank: $(ls ~/voicebank | wc -l) files"
