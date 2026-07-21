#!/bin/bash
# setup_voicebank.sh — one-time: install Piper neural TTS on the pad and
# render the announcement voice bank. Run ON THE PAD, ideally while the
# printers are idle. Downloads ~90MB, renders ~2-5 minutes.
set -e

PIPER_URL="https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_armv7l.tar.gz"
HF="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0"

echo "== Installing Piper =="
mkdir -p ~/piper/voices
if [ ! -x ~/piper/piper/piper ]; then
    wget -q --show-progress -O /tmp/piper.tar.gz "$PIPER_URL"
    tar -xzf /tmp/piper.tar.gz -C ~/piper/
fi

echo "== Downloading voices (4 x ~20MB) =="
declare -A PATHS=(
  [en_US-amy-low]="en/en_US/amy/low"
  [en_US-libritts_r-medium]="en/en_US/libritts_r/medium"
  [en_GB-alan-low]="en/en_GB/alan/low"
  [en_GB-jenny_dioco-medium]="en/en_GB/jenny_dioco/medium"             # Tesseract (prewired)
  [en_US-joe-medium]="en/en_US/joe/medium"                             # Pentagram (prewired)
  [en_US-kristin-medium]="en/en_US/kristin/medium"                     # Sestina (prewired)
  [en_GB-northern_english_male-medium]="en/en_GB/northern_english_male/medium"  # Hydra (prewired)
)
for m in "${!PATHS[@]}"; do
    for ext in onnx onnx.json; do
        [ -f ~/piper/voices/$m.$ext ] || wget -q --show-progress -O ~/piper/voices/$m.$ext "$HF/${PATHS[$m]}/$m.$ext"
    done
done

echo "== Rendering the voice bank =="
~/render_voicebank.sh

echo "== Done. Test with: ~/say.sh Unicorn print complete =="
