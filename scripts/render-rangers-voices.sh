#!/bin/bash
# render-rangers-voices.sh - renders the ONE show-specific clip: Omega's battle
# cry "Go go power printers!" into ~/rangers/.
#
# The roll-call NAME clips (omega/unicorn/dimeter/trident) no longer live here -
# they are general, reusable voicebank assets now (each printer just saying its
# own name), rendered by render_voicebank.sh into ~/voicebank/<name>.wav. The
# cry is the only truly Rangers-specific line, so it is the only thing left here.
# Re-run any time (idempotent). Runs niced so it can never starve a printing klippy.
set -e
if [ -z "$RENICED" ]; then exec env RENICED=1 nice -n 19 "$0" "$@"; fi
mkdir -p ~/rangers
CRY="Go go power printers!"

# Omega's solo - the espeak robot voice, higher pitch (-p 60) for the hype
espeak-ng -v en-us -s 150 -p 60 -a 190 -w ~/rangers/cry_omega.wav "$CRY" 2>/dev/null

# peak-normalize to match the chimes (same rule as the voicebank render)
python3 - <<'PY'
import wave, audioop, glob, os
for f in glob.glob(os.path.expanduser('~/rangers/cry_*.wav')):
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
echo "rangers voice: $(ls ~/rangers/cry_*.wav 2>/dev/null | wc -l)/1 rendered (cry_omega)"
