# sonic-pad-voiced-farm

Turn an abandoned **Creality Sonic Pad** into a modern, multi-printer **Klipper** farm with a personality: one Fluidd portal for every printer, automated backups, spoken status, themed chimes, LED light choreography, and one-button "silly" shows — built and battle-tested on four **Elegoo Neptune 3 Pro** printers, prewired for eight.

**📖 Start here: [`docs/BUILD-GUIDE.md`](docs/BUILD-GUIDE.md)** — the complete beginning-to-end roadmap (flash the pad → four-printer stack → configs → sound/voice/lights → backups → tuning), with a Raspberry Pi / tablet path, every command, and every gotcha. A rendered HTML version and the architecture diagrams are in [`docs/`](docs/).

## What's in here

```
scripts/    play_chime.sh, say.sh, sonicpad-chimes.py (event→sound daemon),
            set-sound-theme.sh, render_voicebank.sh, setup_voicebank.sh,
            and the four shows: rangers.sh, invaders.sh, cradle.sh, race.sh
config/     macros.cfg (shared fleet macros), sonicpad-chimes.service, asound.conf
sounds/     five swappable themes — Default · Doom · Arcade · Zen · Rangers
docs/       BUILD-GUIDE.md, diagrams.html, VOICES.md
```

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

- **No secrets here.** This kit has no private printer configs, WiFi, or GitHub tokens — those stay on your pad. Ports (`7125–7128`) and printer names are the author's; adapt them to your fleet.
- **Voices:** the spoken lines are pre-rendered with [Piper](https://github.com/rhasspy/piper); `docs/VOICES.md` is the recipe to reproduce or extend every voice. Delete the Piper models afterward to reclaim ~0.5 GB.
- **The sounds** are original compositions in the *spirit* of their themes, free to ship.

## Credits

Stands on the shoulders of [SonicPad-Debian](https://github.com/Jpe230/SonicPad-Debian), [KIAUH](https://github.com/dw-0/kiauh), [Klipper](https://www.klipper3d.org/), [Moonraker](https://github.com/Arksine/moonraker), [Fluidd](https://docs.fluidd.xyz), [KlipperScreen](https://klipperscreen.readthedocs.io), [klipper-backup](https://github.com/Staubgeborener/klipper-backup), and [Piper](https://github.com/rhasspy/piper).

## License

MIT — see [`LICENSE`](LICENSE).
