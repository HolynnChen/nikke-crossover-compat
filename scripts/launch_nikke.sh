#!/bin/sh
# Launch NIKKE with the video fix applied.
#
# This deliberately does NOT go through CrossOver's own `bin/wine` wrapper.
# The app bundle carries its own bootstrap as Contents/MacOS/nikke_wine, and that
# is what WINELOADER/CX_WINELOADER point at, so CrossOver's launcher layer (and
# its licence check, which fails on this machine) is never involved. This script reproduces that same environment exactly and adds
# the one variable the app bundle is missing. That keeps the entry point on the
# configuration that has actually been verified, and it means editing the app's
# Info.plist is never necessary -- which matters, because the bundle is ad-hoc
# signed and editing it would invalidate that signature.
#
# NOP_BRIDGE_MF_SOFTWARE is not optional. Together with NOP_BRIDGE_MF_NO_DXGI it
# forms the pair that makes the Media Foundation video path self-consistent;
# with only the latter set, story video stalls and hangs the game. See
# docs/APPLIED-TECHNIQUES.*.md section 5.3.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)

APP=${NIKKE_APP:-"$HOME/Applications/NIKKE Wine.app"}
PREFIX=${NIKKE_PREFIX:-"$HOME/Library/Application Support/NIKKE-Wine"}
RUNTIME=${NIKKE_RUNTIME:-"$ROOT/local/runtime-modules"}
LOADER="$APP/Contents/MacOS/nikke_wine"

for f in "$LOADER" "$ROOT/build/libnop_bridge.dylib" \
         "$RUNTIME/lib/wine/x86_64-unix/ntdll.so" "$RUNTIME/bin/wineserver"; do
    [ -e "$f" ] || { echo "missing required file: $f" >&2; exit 1; }
done

# The two Media Foundation switches and the graphics backend are overridable so
# an experiment can be run without editing this file, e.g.
#   NOP_BRIDGE_MF_NO_DXGI= NOP_BRIDGE_MF_SOFTWARE= scripts/launch_nikke.sh
#   CX_GRAPHICS_BACKEND=d3dmetal scripts/launch_nikke.sh
NOP_BRIDGE_MF_NO_DXGI=${NOP_BRIDGE_MF_NO_DXGI-1}
NOP_BRIDGE_MF_SOFTWARE=${NOP_BRIDGE_MF_SOFTWARE-1}
CX_GRAPHICS_BACKEND=${CX_GRAPHICS_BACKEND:-dxvk}

# The runtime view carries DXVK's d3d dlls as real files, and a native override is
# what makes Wine pick them; without it the view's copies load as builtins and the
# game silently falls back to wined3d (verified: much lower frame rate). Note the
# view shadows the prefix, so installing DXVK into the prefix alone has no effect.
export WINEARCH=${WINEARCH:-wow64}
export WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-"version=n,b;d3d9,d3d10,d3d10_1,d3d10core,d3d11=n,b"}

exec env \
    CX_ROOT="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver" \
    CX_GRAPHICS_BACKEND="$CX_GRAPHICS_BACKEND" \
    CX_WINELOADER="$LOADER" \
    DYLD_INSERT_LIBRARIES="$ROOT/build/libnop_bridge.dylib" \
    NOP_BRIDGE_APP_CWD="$PREFIX/drive_c/NIKKE/Launcher" \
    NOP_BRIDGE_APP_PROGRAM='C:\NIKKE\Launcher\nikke_launcher.exe' \
    NOP_BRIDGE_LOG="${NOP_BRIDGE_LOG:-/tmp/nikke-stderr.log}" \
    NOP_BRIDGE_MF_NO_DXGI="$NOP_BRIDGE_MF_NO_DXGI" \
    NOP_BRIDGE_MF_SOFTWARE="$NOP_BRIDGE_MF_SOFTWARE" \
    NOP_BRIDGE_NTDLL="$RUNTIME/lib/wine/x86_64-unix/ntdll.so" \
    NOP_BRIDGE_PRIVILEGED=1 \
    WINEARCH="$WINEARCH" \
    WINEDEBUG="-all,err+all,warn+ntoskrnl" \
    WINEDLLOVERRIDES="$WINEDLLOVERRIDES" \
    WINEDLLPATH="$RUNTIME/lib/wine/x86_64-windows:$RUNTIME/lib/wine/i386-windows:$RUNTIME/lib/wine" \
    WINELOADER="$LOADER" \
    WINEPREFIX="$PREFIX" \
    WINESERVER="$RUNTIME/bin/wineserver" \
    "$LOADER" "$@"
