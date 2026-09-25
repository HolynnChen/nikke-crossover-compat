#!/bin/sh
# Launch NIKKE with the video fix applied.
#
# This deliberately does NOT go through CrossOver's own `bin/wine` wrapper.
# The existing NIKKE Wine.app sets WINELOADER/CX_WINELOADER to its own bootstrap
# and loads CrossOver's libraries directly, so it never involves CrossOver's
# launcher layer. This script reproduces that same environment exactly and adds
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

exec env \
    CX_ROOT="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver" \
    CX_GRAPHICS_BACKEND="dxvk" \
    CX_WINELOADER="$LOADER" \
    DYLD_INSERT_LIBRARIES="$ROOT/build/libnop_bridge.dylib" \
    NOP_BRIDGE_APP_CWD="$PREFIX/drive_c/NIKKE/Launcher" \
    NOP_BRIDGE_APP_PROGRAM='C:\NIKKE\Launcher\nikke_launcher.exe' \
    NOP_BRIDGE_LOG="${NOP_BRIDGE_LOG:-/tmp/nikke-stderr.log}" \
    NOP_BRIDGE_MF_NO_DXGI=1 \
    NOP_BRIDGE_MF_SOFTWARE=1 \
    NOP_BRIDGE_NTDLL="$RUNTIME/lib/wine/x86_64-unix/ntdll.so" \
    NOP_BRIDGE_PRIVILEGED=1 \
    WINEARCH=wow64 \
    WINEDEBUG="-all,err+all,warn+ntoskrnl" \
    WINEDLLOVERRIDES="version=n,b" \
    WINEDLLPATH="$RUNTIME/lib/wine/x86_64-windows:$RUNTIME/lib/wine/i386-windows:$RUNTIME/lib/wine" \
    WINELOADER="$LOADER" \
    WINEPREFIX="$PREFIX" \
    WINESERVER="$RUNTIME/bin/wineserver" \
    "$LOADER" "$@"
