#!/bin/bash
# narrate.sh — print-progress narration (bed/nozzle temp reached, leveling,
# purging, starting print). Suppressed when narration is toggled off; still
# routes through say.sh -> play_chime.sh so the master mute also applies.
# Usage: narrate.sh Omega bed temperature reached
[ -f "$HOME/.mute_narration" ] && exit 0
exec "$HOME/say.sh" "$@"
