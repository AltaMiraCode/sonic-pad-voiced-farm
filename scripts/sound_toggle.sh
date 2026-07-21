#!/bin/bash
# sound_toggle.sh — flip the sound mute flags, with a spoken confirmation
# that plays even while muted (--force). Called by the SOUND_MUTE /
# SOUND_NARRATION macros.
#   mute_toggle  -> all sounds on/off (thermal alerts still sound)
#   narr_toggle  -> print-progress narration on/off

say_force() {
    local T
    T=$(mktemp /tmp/tog.XXXXXX)
    espeak-ng -v en-us -s 150 -p 45 -a 190 -w "$T" "$1" 2>/dev/null
    "$HOME/play_chime.sh" --force "$T"
    rm -f "$T"
}

case "$1" in
  mute_toggle)
    if [ -f "$HOME/.mute_all" ]; then rm -f "$HOME/.mute_all"; say_force "sound on";
    else say_force "sound muted"; touch "$HOME/.mute_all"; fi ;;
  narr_toggle)
    if [ -f "$HOME/.mute_narration" ]; then rm -f "$HOME/.mute_narration"; say_force "narration on";
    else touch "$HOME/.mute_narration"; say_force "narration off"; fi ;;
  vol_up)
    v=$(cat "$HOME/.volume" 2>/dev/null || echo 31); v=$((v+3)); [ $v -gt 31 ] && v=31
    echo $v > "$HOME/.volume"; p=$(( ((v*100/31)+5)/10*10 )); say_force "volume $p percent" ;;
  vol_down)
    v=$(cat "$HOME/.volume" 2>/dev/null || echo 31); v=$((v-3)); [ $v -lt 3 ] && v=3
    echo $v > "$HOME/.volume"; p=$(( ((v*100/31)+5)/10*10 )); say_force "volume $p percent" ;;
  vol_max)
    echo 31 > "$HOME/.volume"; say_force "volume 100 percent" ;;
  stack_toggle)
    if [ -f "$HOME/.voice_stacking" ]; then rm -f "$HOME/.voice_stacking"; say_force "voice stacking off";
    else touch "$HOME/.voice_stacking"; say_force "voice stacking on"; fi ;;
esac
