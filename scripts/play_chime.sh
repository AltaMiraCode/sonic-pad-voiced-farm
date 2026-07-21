#!/bin/bash
# play_chime.sh — play a WAV through the Sonic Pad speaker, reliably.
# Asserts the full known-good mixer state before every play (defeats the BSP
# driver's register resets). Honors the master mute (~/.mute_all) unless
# called with --force (used by thermal alerts so they always sound).
# Usage: play_chime.sh [--force] file.wav

LOUDNESS=$(cat "$HOME/.volume" 2>/dev/null || echo 31)   # LINEOUT 0-31; 31 = max
FORCE=0
if [ "$1" = "--force" ]; then FORCE=1; shift; fi
if [ -f "$HOME/.mute_all" ] && [ "$FORCE" = "0" ]; then exit 0; fi

W="${1:-$HOME/chimes/done.wav}"

amixer -c 0 sset 'digital volume' 0            >/dev/null 2>&1   # ATTENUATOR: 0 = full volume
amixer -c 0 sset 'LINEOUT' on                  >/dev/null 2>&1
amixer -c 0 sset 'LINEOUT volume' "$LOUDNESS"  >/dev/null 2>&1
amixer -c 0 sset 'LINEOUT Output Select' DAC_SINGLE >/dev/null 2>&1
amixer -c 0 sset 'Headphone' on                >/dev/null 2>&1
amixer -c 0 sset 'HpSpeaker' on                >/dev/null 2>&1
amixer -c 0 sset 'DAC Swap' Off                >/dev/null 2>&1

exec aplay -q "$W"
