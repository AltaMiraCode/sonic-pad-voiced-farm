# sonic-pad-voiced-farm

Turn an abandoned **Creality Sonic Pad** into a modern, multi-printer **Klipper** farm with a personality: one Fluidd portal for every printer, automated backups, spoken status, themed chimes, LED light choreography, interactive filament-reload and input-shaping helpers, cameras, and one-button "silly" shows — built and battle-tested on four **Elegoo Neptune 3 Pro** printers, prewired for eight.

**📖 Start here: [`docs/BUILD-GUIDE.md`](docs/BUILD-GUIDE.md)** — the complete beginning-to-end roadmap (flash the pad → four-printer stack → configs → sound/voice/lights → cameras → backups → scaling to eight → tuning), with a Raspberry Pi / tablet path, every command explained, and clear 💻 PC-vs-🖥️ pad labels. A rendered HTML version and the architecture diagrams are in [`docs/`](docs/).

> ### ⚠️ Adapt these files to *your* fleet first
> Everything here uses the author's four printer **names** — `Omega`, `Unicorn`, `Dimeter`, `Trident` — and their Moonraker **ports** — `7128` (Omega, also the port-80 default), `7125` (Unicorn), `7126` (Dimeter), `7127` (Trident). Prewired names/ports for printers 5–8: `Tesseract 7129`, `Pentagram 7130`, `Sestina 7131`, `Hydra 7132`.
>
> These names and ports appear throughout the scripts and `macros.cfg`. **Before first use, find-and-replace them with your own printer names and ports** (a single pass across `scripts/` and `config/`), and set each printer's `[mcu] serial:` to its own `by-path` value. The build guide's §7 explains why identity is keyed to the physical USB port.

## What's in here

```
scripts/    play_chime.sh · say.sh · sonicpad-chimes.py (event→sound daemon) ·
            set-sound-theme.sh · render_voicebank.sh · setup_voicebank.sh · narrate.sh
   shows    rangers.sh · invaders.sh · cradle.sh · race.sh
   shaping  shape.sh · shape-run.sh · setup-shaper.sh   (one-button input shaping)
   runout   runout_alert.sh · runout-feed.sh           (guided filament reload)
   cameras  register-webcam.sh · cam-watch.sh · cam-snapshot.sh
   fleet    port-assign.sh · restart-all.sh · fleet.sh · replicate-fluidd-macros.sh ·
            overload-watch.sh · cal-watch.sh · usb-watch.sh
config/     macros.cfg (ALL fleet + SILLY show macros + _LEDW light helper) ·
            shaper.cfg · adxl-shape.cfg · machine.cfg.example ·
            sonicpad-chimes.service · asound.conf · cameras.conf
sounds/     five swappable themes — Default · Doom · Arcade · Zen · Rangers
docs/       BUILD-GUIDE.md · diagrams.html · VOICES.md
```

**The macros live in [`config/macros.cfg`](config/macros.cfg)** — the shared, deploy-to-every-printer file. It defines the everyday macros (`PRINT_START`/`PRINT_END`, `PAUSE`/`RESUME`/`CANCEL_PRINT`, `TUNE_PID_*`, `BED_LEVELING`, `NOZZLE_PARK`, `LIGHTS_*`/`FLEET_LIGHTS_*`, `SOUND_*`, `RUNOUT_ALERT`/`RUNOUT_INSERT`, `M600`, Marlin shims `G28`/`G29`/`M420`), the four `SILLY_*` shows and their motion/`_LEDW` light helpers, and `RUN_INPUT_SHAPER`. Add `[include macros.cfg]` to each printer's `printer.cfg`.

## Quick start (after the OS upgrade in the guide)

```bash
git clone https://github.com/AltaMiraCode/sonic-pad-voiced-farm.git ~/farm-kit
# sound: see docs/BUILD-GUIDE.md §12
cd ~/farm-kit
cp scripts/play_chime.sh scripts/say.sh scripts/set-sound-theme.sh scripts/sonicpad-chimes.py ~
cp -r sounds ~/sounds && ln -sfn ~/sounds/Default ~/chimes
cp config/asound.conf ~ && sudo cp ~/asound.conf /etc/asound.conf
chmod +x ~/*.sh ~/sonicpad-chimes.py && sudo apt install -y python3-websockets
sudo cp config/sonicpad-chimes.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now sonicpad-chimes
```

## Notes

- **No secrets here.** No private printer configs, WiFi, or GitHub tokens — those stay on your pad. Any example IP is a placeholder; set `PAD_IP` (or edit the default) to your pad's address.
- **Voices:** spoken lines are pre-rendered with [Piper](https://github.com/rhasspy/piper); [`docs/VOICES.md`](docs/VOICES.md) is the recipe to reproduce or extend every voice. Delete the Piper models afterward to reclaim ~0.5 GB.
- **The sounds** are original compositions in the *spirit* of their themes, free to ship.

## Credits

Stands on the shoulders of [SonicPad-Debian](https://github.com/Jpe230/SonicPad-Debian), [KIAUH](https://github.com/dw-0/kiauh), [Klipper](https://www.klipper3d.org/), [Moonraker](https://github.com/Arksine/moonraker), [Fluidd](https://docs.fluidd.xyz), [KlipperScreen](https://klipperscreen.readthedocs.io), [Crowsnest](https://github.com/mainsail-crew/crowsnest), [klipper-backup](https://github.com/Staubgeborener/klipper-backup), and [Piper](https://github.com/rhasspy/piper).

## License

MIT — see [`LICENSE`](LICENSE).
