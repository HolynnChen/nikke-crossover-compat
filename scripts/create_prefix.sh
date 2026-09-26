#!/bin/sh
# Create a Wine prefix for NIKKE, and optionally run the game's installer in it.
#
# Nothing here uses CrossOver's graphical interface or its bottle system -- only
# CrossOver's Wine libraries, through this project's runtime view. The resulting
# prefix is a plain Wine prefix and never appears in CrossOver's bottle list.
#
#   scripts/create_prefix.sh [prefix-path] [installer.exe]
#
# Defaults to ~/Library/Application Support/NIKKE-Wine. The installer is optional:
# run this first to create the prefix, then pass the downloaded NIKKE installer,
# or run the installer later with the same command this script prints.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RUNTIME=${NIKKE_RUNTIME:-"$ROOT/local/runtime-modules"}
PREFIX=${1:-"$HOME/Library/Application Support/NIKKE-Wine"}
INSTALLER=${2:-}
# Same root the launcher uses, so Wine finds CrossOver's DXVK, MoltenVK and
# compatibility database instead of warning that they are missing.
CX_ROOT=${CX_ROOT:-"/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"}
WINE_PATH="$RUNTIME/lib/wine/x86_64-windows:$RUNTIME/lib/wine/i386-windows:$RUNTIME/lib/wine"

[ -x "$RUNTIME/bin/wineloader" ] || {
    echo "runtime view is missing: $RUNTIME" >&2
    echo "build it first -- see docs/INSTALL.zh-CN.md section 3" >&2
    exit 1
}

# Wine refuses to create its configuration directory under a path it does not
# own, and /tmp belongs to root on macOS. Catch it here rather than there.
case "$PREFIX" in
/tmp/* | /private/tmp/*)
    echo "refusing $PREFIX: choose a path under your home directory" >&2
    exit 1
    ;;
esac

run_wine() {
    env WINEPREFIX="$PREFIX" WINESERVER="$RUNTIME/bin/wineserver" \
        WINEDLLPATH="$WINE_PATH" WINEARCH=wow64 CX_ROOT="$CX_ROOT" \
        "$RUNTIME/bin/wineloader" "$@"
}

if [ -f "$PREFIX/system.reg" ]; then
    echo "prefix already exists: $PREFIX"
else
    echo "creating prefix: $PREFIX"
    run_wine wineboot.exe
    echo "prefix created"
fi

if [ -n "$INSTALLER" ]; then
    [ -f "$INSTALLER" ] || {
        echo "installer not found: $INSTALLER" >&2
        exit 1
    }
    echo "running installer: $INSTALLER"
    run_wine "$INSTALLER"
fi
