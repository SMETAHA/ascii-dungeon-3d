#!/usr/bin/env bash
set -euo pipefail
out="ascii-dungeon-3d-v19.love"
rm -f "$out"
zip -9 -r "$out" . -x "*.git*" -x "$out"
echo "Built $out"
