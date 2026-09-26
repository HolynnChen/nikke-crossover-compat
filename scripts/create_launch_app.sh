#!/bin/sh
# Create the self-contained launcher app, by default ~/Applications/NIKKE Wine.app.
#
# The app is a thin shell: Contents/MacOS/launch calls scripts/launch_nikke.sh in this
# repository, and Contents/MacOS/nikke_wine is the Wine loader built by `make`. Nothing
# CrossOver ships is modified. An existing app is left alone unless --force is given.
#
#   scripts/create_launch_app.sh [app-path] [--force]
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${NIKKE_APP:-"$HOME/Applications/NIKKE Wine.app"}
FORCE=0
for arg in "$@"; do
    case "$arg" in
    --force) FORCE=1 ;;
    -*) echo "unknown option: $arg" >&2; exit 1 ;;
    *) APP=$arg ;;
    esac
done

LOADER="$ROOT/build/NopBridgeLab.app/Contents/MacOS/wine_bootstrap"
[ -x "$LOADER" ] || {
    echo "missing $LOADER -- run 'make' first" >&2
    exit 1
}
if [ -e "$APP" ] && [ "$FORCE" -ne 1 ]; then
    echo "already exists: $APP"
    echo "pass --force to recreate it"
    exit 0
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

printf '#!/bin/sh\nexec "%s/scripts/launch_nikke.sh" "$@"\n' "$ROOT" >"$APP/Contents/MacOS/launch"
chmod +x "$APP/Contents/MacOS/launch"
cp "$LOADER" "$APP/Contents/MacOS/nikke_wine"

# Note CFBundleExecutable=launch: this app is the wrapper, not the loader. Reusing
# src/Info.plist here would point Finder at wine_bootstrap and launching would fail.
cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>launch</string>
	<key>CFBundleIdentifier</key><string>org.nopbridge.nikke.wine</string>
	<key>CFBundleName</key><string>NIKKE Wine</string>
	<key>CFBundleDisplayName</key><string>NIKKE Wine</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>LSMinimumSystemVersion</key><string>11.0</string>
</dict>
</plist>
PLIST

# The game's icon is not redistributed with this repository. Reuse one if the user
# has it (NIKKE_ICON, src/NIKKE.icns, or the icon already inside the target app).
ICON=${NIKKE_ICON:-}
if [ -z "$ICON" ]; then
    for candidate in "$ROOT/src/NIKKE.icns" "$HOME/Applications/NIKKE Wine.app/Contents/Resources/NIKKE.icns"; do
        [ -f "$candidate" ] && ICON=$candidate && break
    done
fi
if [ -n "$ICON" ] && [ -f "$ICON" ]; then
    cp "$ICON" "$APP/Contents/Resources/NIKKE.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string NIKKE.icns" \
        "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi

plutil -lint "$APP/Contents/Info.plist" >/dev/null || {
    echo "generated Info.plist is malformed" >&2
    exit 1
}
echo "created $APP"
