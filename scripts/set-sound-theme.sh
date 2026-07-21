#!/bin/bash
# set-sound-theme.sh — switch the active sound theme.
#
# Layout: ~/sounds/ is the sound library root. Each SUBFOLDER is a theme
# (Default, Doom, Arcade, Zen, Starship, ...) holding start.wav, done.wav,
# pause.wav, resume.wav, error.wav, boot.wav, tick.wav (variants like
# done_b.wav allowed - the daemon shuffles within a family).
# ~/chimes is a symlink to the active theme. The daemon re-scans on every
# play, so switching is instant - no restarts.
#
# Usage:
#   ./set-sound-theme.sh            list themes + show active
#   ./set-sound-theme.sh Doom       activate ~/sounds/Doom

# resolve through the symlink: ~/sounds is a symlink to the Omega config dir, and
# `find`/`ls` on a symlink argument don't descend it - which silently broke the
# "next" cycle (it saw zero themes). Resolve to the real path so listing works.
THEMES_DIR="$(readlink -f "$HOME/sounds" 2>/dev/null || echo "$HOME/sounds")"

if [ -z "$1" ]; then
    echo "Available themes:"
    find "$THEMES_DIR" -mindepth 1 -maxdepth 1 -type d -printf "  %f\n" 2>/dev/null | sort
    if [ -L "$HOME/chimes" ]; then
        echo "Active: $(basename "$(readlink "$HOME/chimes")")"
    else
        echo "Active: none (~/chimes is not a theme link yet)"
    fi
    exit 0
fi

# First run: preserve a plain ~/chimes folder as the Default theme. This runs
# BEFORE any theme lookup so a bare SOUND_THEME press works even on a pad where
# ~/sounds was never populated - the live chime set becomes theme "Default".
if [ -d "$HOME/chimes" ] && [ ! -L "$HOME/chimes" ]; then
    if [ ! -d "$THEMES_DIR/Default" ]; then
        mkdir -p "$THEMES_DIR"
        mv "$HOME/chimes" "$THEMES_DIR/Default"
        ln -sfn "$THEMES_DIR/Default" "$HOME/chimes"
        echo "(moved existing ~/chimes into themes as 'Default')"
    else
        mv "$HOME/chimes" "$HOME/chimes.old.$$"
        ln -sfn "$THEMES_DIR/Default" "$HOME/chimes"
        echo "(parked old ~/chimes as ~/chimes.old.$$)"
    fi
fi

# "next": cycle to the theme after the current one (alphabetical, wraps around).
# This powers the single SOUND_THEME button - each press hops to the next theme.
if [ "$1" = "next" ]; then
    cur=""
    [ -L "$HOME/chimes" ] && cur=$(basename "$(readlink "$HOME/chimes")")
    themes=$(find "$THEMES_DIR" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | sort)
    [ -z "$themes" ] && { echo "no themes in $THEMES_DIR - copy the theme folders to ~/sounds/ first"; exit 1; }
    next=$(echo "$themes" | awk -v c="$cur" '$0==c{if((getline l)>0) print l; exit}')
    [ -z "$next" ] && next=$(echo "$themes" | head -1)   # wrap (or no current link)
    set -- "$next"
fi

if [ ! -d "$THEMES_DIR/$1" ]; then
    echo "No theme named '$1' in $THEMES_DIR"
    exit 1
fi

ln -sfn "$THEMES_DIR/$1" "$HOME/chimes"
echo "Active sound theme: $1"

# audible confirmation: the theme's start sound
f=$(ls "$HOME"/chimes/start*.wav "$HOME"/chimes/chime_start*.wav 2>/dev/null | head -1)
[ -n "$f" ] && "$HOME/play_chime.sh" "$f"
