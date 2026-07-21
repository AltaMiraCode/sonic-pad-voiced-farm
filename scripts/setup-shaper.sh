#!/bin/bash
# setup-shaper.sh - ONE-TIME wiring of the shared-accelerometer input-shaping
# system into all four printers. Run on the pad AFTER copying shape.sh,
# shape-run.sh, adxl-shape.cfg and shaper.cfg into ~/. Idempotent - safe to re-run.
set -e
declare -A PORT=( [OMEGA]=7128 [UNICORN]=7125 [DIMETER]=7126 [TRIDENT]=7127 )
# add [TESSERACT]=7129 [PENTAGRAM]=7130 [SESTINA]=7131 [HYDRA]=7132 above when their instances exist (setup would
# otherwise try to wire config dirs that do not exist yet)

echo "== prerequisites =="
[ -e /dev/spidev2.0 ]        && echo "  spidev2.0 ........ OK" || echo "  spidev2.0 ........ MISSING (SPI not enabled - sensor can't be read yet)"
[ -S /tmp/klipper_host_mcu ] && echo "  host mcu socket .. OK" || echo "  host mcu socket .. MISSING (linux host MCU not running)"

echo "== wiring each printer =="
for f in shape.sh shape-run.sh; do
    if [ -f "$HOME/$f" ]; then chmod +x "$HOME/$f"
    else echo "  WARNING: ~/$f is missing - copy it before running RUN_INPUT_SHAPER"; fi
done
for P in "${!PORT[@]}"; do
    cfg="$HOME/printer_${P}_data/config"
    cp "$HOME/shaper.cfg" "$cfg/shaper.cfg"           # static macros, always loaded
    [ -f "$cfg/adxl.cfg" ] || : > "$cfg/adxl.cfg"     # empty hardware include
    for inc in shaper.cfg adxl.cfg; do
        if ! grep -q "include $inc" "$cfg/printer.cfg"; then
            if grep -q "include machine.cfg" "$cfg/printer.cfg"; then
                sed -i "/include machine.cfg/a [include $inc]" "$cfg/printer.cfg"
            else
                sed -i "1a [include $inc]" "$cfg/printer.cfg"
            fi
            echo "  $P: added [include $inc]"
        else
            echo "  $P: [include $inc] already present"
        fi
    done
done

echo "== reloading printers to pick up the includes =="
for P in "${!PORT[@]}"; do
    curl -s -m5 -X POST "http://127.0.0.1:${PORT[$P]}/printer/firmware_restart" >/dev/null 2>&1
done
echo "== done. Now: RUN_INPUT_SHAPER on the printer you want to test. =="
