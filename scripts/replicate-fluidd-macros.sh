#!/bin/bash
# replicate-fluidd-macros.sh - copy OMEGA's Fluidd macro organization (categories,
# per-macro visibility, colors) to Unicorn, Dimeter and Trident.
#
# Fluidd keeps this in each printer's Moonraker database (namespace "fluidd",
# key "macros"), so replicating is one GET + three POSTs. All four printers run
# the identical macros.cfg, so the settings transfer cleanly.
#
# Run on the pad AFTER arranging the categories in Omega's Fluidd:
#   ~/replicate-fluidd-macros.sh
# Then hard-refresh (Ctrl+F5) each other printer's Fluidd tab.
python3 - <<'PY'
import json, urllib.request

SRC = 7128                       # Omega - the printer you organized
DEST = {7125: "Unicorn", 7126: "Dimeter", 7127: "Trident"}
# when they exist: DEST[7129] = "Tesseract"; DEST[7130] = "Pentagram"; DEST[7131] = "Sestina"; DEST[7132] = "Hydra"

with urllib.request.urlopen(
        f"http://127.0.0.1:{SRC}/server/database/item?namespace=fluidd&key=macros",
        timeout=5) as r:
    val = json.load(r)["result"]["value"]

if not val:
    raise SystemExit("no macro settings found on Omega (7128) - organize its Fluidd first")

cats = val.get("categories", []) if isinstance(val, dict) else []
print(f"Omega's layout: {len(cats)} categories - replicating...")

body = json.dumps({"namespace": "fluidd", "key": "macros", "value": val}).encode()
for port, name in DEST.items():
    try:
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/server/database/item", data=body,
            headers={"Content-Type": "application/json"}, method="POST")
        urllib.request.urlopen(req, timeout=5)
        print(f"  {name} ({port}): replicated")
    except Exception as e:
        print(f"  {name} ({port}): FAILED - {e}")

print("Done. Hard-refresh (Ctrl+F5) each printer's Fluidd tab to see it.")
PY
