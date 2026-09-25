#!/bin/sh
# Launch NIKKE through this repository's own entry point.
#
# Using launch_crossover.py keeps the app bundle's ad-hoc signature untouched:
# editing its Info.plist would invalidate that signature. The two video switches
# below are a pair -- with only --disable-dxgi-video, story video stalls and
# hangs the game (see docs/APPLIED-TECHNIQUES.*.md section 5.3).
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=${NIKKE_PREFIX:-"$HOME/Library/Application Support/NIKKE-Wine"}

exec python3 "$ROOT/scripts/launch_crossover.py" \
    --prefix "$PREFIX" \
    --runtime "$ROOT/local/runtime-modules" \
    --graphics dxvk \
    --privileged-faults \
    --software-video \
    --disable-dxgi-video \
    --workdir 'C:\NIKKE\Launcher' \
    'C:\NIKKE\Launcher\nikke_launcher.exe' "$@"
