#!/bin/bash
# render-prewired-names.sh - render the bare NAME clips for the prewired
# printers 5-8 (Tesseract, Pentagram, Sestina, Hydra) into ~/voicebank, each in
# its own Piper voice, then delete the temporarily-downloaded models to reclaim
# disk. Idempotent. Matches the voice map in render_voicebank.sh / VOICES.md.
set -e
echo "== render-prewired-names start $(date) =="

PIPER_URL="https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_armv7l.tar.gz"
HF="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0"
PIPER="$HOME/piper/piper/piper"
V="$HOME/piper/voices"
mkdir -p "$V"

if [ ! -x "$PIPER" ]; then
  echo "-- downloading piper binary"
  wget -q -O /tmp/piper.tar.gz "$PIPER_URL"
  tar -xzf /tmp/piper.tar.gz -C "$HOME/piper/"
fi

render_name () {  # $1=Name  $2=model  $3=hf-path
  local name="$1" model="$2" path="$3"
  local out="$HOME/voicebank/$(echo "$name" | tr '[:upper:]' '[:lower:]').wav"
  for ext in onnx onnx.json; do
    if [ ! -f "$V/$model.$ext" ]; then
      echo "-- fetching $model.$ext"
      wget -q -O "$V/$model.$ext" "$HF/$path/$model.$ext"
    fi
  done
  echo "$name!" | "$PIPER" -m "$V/$model.onnx" -f "$out" -q >/dev/null 2>&1
  echo "-- rendered $out"
}

render_name Tesseract en_GB-jenny_dioco-medium             en/en_GB/jenny_dioco/medium
render_name Pentagram en_US-joe-medium                     en/en_US/joe/medium
render_name Sestina   en_US-kristin-medium                 en/en_US/kristin/medium
render_name Hydra     en_GB-northern_english_male-medium   en/en_GB/northern_english_male/medium

echo "-- peak-normalizing the four new clips"
python3 - <<'PY'
import wave, audioop, os
for n in ('tesseract','pentagram','sestina','hydra'):
    f=os.path.expanduser('~/voicebank/%s.wav' % n)
    try:
        w=wave.open(f,'rb'); p=w.getparams(); d=w.readframes(w.getnframes()); w.close()
        mx=audioop.max(d,p.sampwidth)
        if mx>0:
            factor=min(4.0, int(0.97*32767)/mx)
            if abs(factor-1.0)>0.01: d=audioop.mul(d,p.sampwidth,factor)
        o=wave.open(f,'wb'); o.setparams(p); o.writeframes(d); o.close()
        print("   normalized", n)
    except Exception as e:
        print("   skip", n, e)
PY

echo "-- reclaiming disk: removing ~/piper (VOICES.md is the recipe to recreate)"
rm -rf "$HOME/piper"

echo "== verify =="
ls -la "$HOME"/voicebank/tesseract.wav "$HOME"/voicebank/pentagram.wav "$HOME"/voicebank/sestina.wav "$HOME"/voicebank/hydra.wav 2>/dev/null
df -h / | tail -1
echo "== done $(date) =="
