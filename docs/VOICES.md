# Fleet Voice Specifications — the permanent record
*(written July 21, 2026, at the piper-model cleanup — keep this file: it is the
recipe for re-creating every voice if the models are ever needed again)*

## Why this file exists

To free ~485 MB on the pad, the Piper TTS models (`~/piper/`) were **deleted**
after every needed line was pre-rendered into `~/voicebank/` (and
`~/rangers/`). The WAVs *are* the voices now. Omega's voice needs no model —
it is espeak-ng, installed as a system package, and can still speak **any new
line live**. To render new lines for the other printers, re-download the
models below (10 minutes, one command each), render, and delete again.

## The cast

| Printer | Engine | Model / args | Character |
|---|---|---|---|
| **Omega** | espeak-ng (kept!) | `-v en-us -s 150 -p 45 -a 190` | the farm's robot computer; also the System voice and every announcer line |
| **Unicorn** | Piper | `en_US-amy-low.onnx` | bright female |
| **Dimeter** | Piper | `en_GB-alan-low.onnx` | British male |
| **Trident** | Piper | `en_US-libritts_r-medium.onnx` + `-s 136`, split tempo: name `--length-scale 1.5`, body `1.1` | slow, dramatic |
| Tesseract (prewired) | Piper | `en_GB-jenny_dioco-medium.onnx` | British female |
| Pentagram (prewired) | Piper | `en_US-joe-medium.onnx` | warm US male |
| Sestina (prewired) | Piper | `en_US-kristin-medium.onnx` | US female |
| Hydra (prewired) | Piper | `en_GB-northern_english_male-medium.onnx` | northern English male |
| System | espeak-ng | same as Omega (Omega IS the system) | farm-wide PA |
| *(retired)* Argus | espeak-ng | `-v en-us+f4 -s 175 -p 80` | the camera's voice — persona retired, camera speaks in chimes now |

Special renders worth knowing about: Trident's thermal alarm brackets
("warning warning") render at `--length-scale 1.5` with the body at `1.1`,
stitched into one clip; every clip is peak-normalized to ~-0.3 dBFS with a 4x
boost cap (see the tail of `render_voicebank.sh` — the same normalization
MUST be applied to any new render or it will sound quiet next to the rest).

## Re-creating the models

Piper binary + voices came from the rhasspy releases:

```
mkdir -p ~/piper/voices && cd ~/piper
wget https://github.com/rhasspy/piper/releases/latest/download/piper_linux_aarch64.tar.gz
tar xzf piper_linux_aarch64.tar.gz    # yields ~/piper/piper/piper
cd voices
# each voice = .onnx + .onnx.json pair from huggingface.co/rhasspy/piper-voices, e.g.:
wget https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/low/en_US-amy-low.onnx
wget https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/low/en_US-amy-low.onnx.json
# (paths follow the pattern en/<lang>/<name>/<quality>/ - see the repo tree)
```

`setup_voicebank.sh` / `test-voices.sh` in the sound-kit automate this.

## Rendering new lines

1. Re-download the model(s) you need (above).
2. Add the phrase to the right list in `render_voicebank.sh` (`PHRASES` =
   name-prefixed, every printer; `FREQ_PHRASES` = spoken without the name;
   `SYS_PHRASES` / the fleet-lines list = System voice) and run it — it is
   idempotent and re-renders everything including your addition, then
   normalizes.
3. Or for a one-off clip, mimic `render-rangers-voices.sh` (and normalize!).
4. Delete `~/piper` again when done if the space matters.

## What still speaks LIVE (espeak = Omega's voice, by design)

- Any `say.sh` line whose first word is not a cast name and isn't in the bank
  (announcer lines like "the winner is Trident", "start your engines" - now
  also banked in the System voice).
- Dynamic, unbankable content: the daemon's per-print milestones
  ("Unicorn 75 percent, 32 minutes remaining") and "print file <name>
  received". These were piper before the cleanup; they are espeak now —
  the one audible change of the cleanup.
- A brand-new printer's lines until its models are downloaded and its
  voicebank rendered (ADD-A-PRINTER day).
