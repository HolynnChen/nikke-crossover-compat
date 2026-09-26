#!/bin/sh
# One command to build the compatibility patches and set NIKKE up.
#
#   scripts/install_all.sh --installer ~/Downloads/NIKKE.PC_Offcial_GL_<version>.exe
#
# What it automates
#   1. checks the prerequisites
#   2. downloads the CrossOver 26.1 source archive and verifies its hash
#   3. builds the macOS-side layer                      (make && make test)
#   4. builds the patched Wine modules                  (slow: tens of minutes)
#   5. produces the runtime view
#   6. creates the Wine prefix
#   7. installs the four patched modules into that prefix
#   8. runs the NIKKE installer, if you point it at one
#   9. creates the launcher app
#
# What it deliberately does not do
#   * install CrossOver -- commercial software, install it yourself first
#   * download the NIKKE client -- there is no stable public URL for it, so pass
#     --installer or --installer-url, or download it and re-run with --installer
#   * log in, or download the >10 GB of game assets -- those happen inside the
#     launcher and are interactive by design
#
# Re-running is safe: every step is skipped when its output already exists.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=${NIKKE_PREFIX:-"$HOME/Library/Application Support/NIKKE-Wine"}
ARCHIVE=${NIKKE_ARCHIVE:-"$ROOT/local/downloads/crossover-sources-26.1.0.tar.gz"}
MODULES_OUT="$ROOT/local/wine-modules"
RUNTIME_OUT="$ROOT/local/runtime-modules"
INSTALLER=${NIKKE_INSTALLER:-}
INSTALLER_URL=
ASSUME_YES=0
FORCE=0
SKIP_BUILD=0

usage() {
    cat <<'EOF'
Usage: scripts/install_all.sh [options]

  --installer PATH      NIKKE installer (.exe) to run once the prefix exists
  --installer-url URL   download the installer from URL first
  --prefix PATH         Wine prefix (default ~/Library/Application Support/NIKKE-Wine)
  --archive PATH        CrossOver source archive (default local/downloads/...)
  --skip-build          reuse existing local/wine-modules and local/runtime-modules
  --force               redo steps whose output already exists
  --yes                 do not ask before the long build
  -h, --help            this text

Prerequisites it checks: CrossOver 26.1, Rosetta, python3, make, curl, Xcode Command
Line Tools, and bison 3 (install with: brew install bison).
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

step() {
    printf '\n=== %s\n' "$*"
}

skip() {
    echo "  skipped: $*"
}

while [ $# -gt 0 ]; do
    case "$1" in
    --installer) [ $# -ge 2 ] || die "--installer needs a value"; INSTALLER=$2; shift 2 ;;
    --installer-url) [ $# -ge 2 ] || die "--installer-url needs a value"; INSTALLER_URL=$2; shift 2 ;;
    --prefix) [ $# -ge 2 ] || die "--prefix needs a value"; PREFIX=$2; shift 2 ;;
    --archive) [ $# -ge 2 ] || die "--archive needs a value"; ARCHIVE=$2; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --force) FORCE=1; shift ;;
    --yes | -y) ASSUME_YES=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
    esac
done

# Whether the module build can be reused decides whether the source archive is
# needed at all: with --skip-build and existing output, nothing has to be downloaded.
NEED_MODULES=1
if [ "$SKIP_BUILD" -eq 1 ] && [ -d "$MODULES_OUT/build" ]; then NEED_MODULES=0; fi
if [ -d "$MODULES_OUT" ] && [ "$FORCE" -ne 1 ]; then NEED_MODULES=0; fi

# ---------------------------------------------------------------- 1. prerequisites
step "1/9 checking prerequisites"

CROSSOVER=${CX_ROOT:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver}
[ -d "$CROSSOVER" ] || die "CrossOver not found at $CROSSOVER -- install CrossOver 26.1 first"
echo "  CrossOver 26.1: $CROSSOVER"

if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
    echo "  Rosetta: working"
else
    die "Rosetta is not available -- run: softwareupdate --install-rosetta --agree-to-license"
fi

command -v python3 >/dev/null 2>&1 || die "python3 not found"
command -v make >/dev/null 2>&1 || die "make not found -- install Xcode Command Line Tools"
command -v curl >/dev/null 2>&1 || die "curl not found"
xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools missing -- run: xcode-select --install"

# Wine's build needs bison 3; macOS ships 2.3, which fails deep inside the build with
# a confusing error, so it is worth catching here.
BISON=${BISON:-/opt/homebrew/opt/bison/bin/bison}
[ -x "$BISON" ] || BISON=$(command -v bison || true)
[ -n "$BISON" ] && [ -x "$BISON" ] || die "bison not found -- run: brew install bison"
case "$("$BISON" --version | head -1)" in
*" 3."*) echo "  bison: $("$BISON" --version | head -1) ($BISON)" ;;
*) die "bison 2.x is too old for Wine -- run: brew install bison" ;;
esac
echo "  python3/make/curl/Xcode CLT: ok"

# ------------------------------------------------------------- 2. source archive
step "2/9 CrossOver source archive"

if [ "$NEED_MODULES" -eq 0 ]; then
    skip "the module build is being reused, so no archive is needed"
else
    SOURCE_URL=$(sed -n 's/^SOURCE_URL = "\(.*\)"/\1/p' "$ROOT/scripts/build_wine_modules.py")
    SOURCE_SHA=$(sed -n 's/^SOURCE_SHA256 = "\(.*\)"/\1/p' "$ROOT/scripts/build_wine_modules.py")
    [ -n "$SOURCE_URL" ] && [ -n "$SOURCE_SHA" ] || die "cannot read SOURCE_URL/SOURCE_SHA256 from build_wine_modules.py"

    if [ -f "$ARCHIVE" ] && [ "$FORCE" -ne 1 ]; then
        skip "$ARCHIVE already exists"
    else
        mkdir -p "$(dirname "$ARCHIVE")"
        echo "  downloading $SOURCE_URL"
        echo "  (about 270 MB; a partial download is left as .part and resumed next run)"
        curl -L --fail --progress-bar -C - -o "$ARCHIVE.part" "$SOURCE_URL" ||
            die "download failed; fetch it yourself and pass --archive PATH"
        mv "$ARCHIVE.part" "$ARCHIVE"
    fi

    actual=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
    [ "$actual" = "$SOURCE_SHA" ] || die "$ARCHIVE does not match the pinned CrossOver 26.1 hash
  expected $SOURCE_SHA
  actual   $actual"
    echo "  sha256 verified"
fi

# ------------------------------------------------------------------ 3. native layer
step "3/9 building the macOS layer"
if [ -f "$ROOT/build/libnop_bridge.dylib" ] && [ "$FORCE" -ne 1 ]; then
    skip "build/libnop_bridge.dylib already exists"
else
    (cd "$ROOT" && make && make test)
    echo "  built"
fi

# --------------------------------------------------------------- 4. Wine modules
step "4/9 building the patched Wine modules"
if [ "$NEED_MODULES" -eq 0 ]; then
    skip "reusing $MODULES_OUT"
else
    if [ "$ASSUME_YES" -ne 1 ] && [ -t 0 ]; then
        printf '  This compiles Wine from source and can take tens of minutes. Continue? [y/N] '
        read -r answer
        case "$answer" in [Yy]*) ;; *) die "stopped at the user's request" ;; esac
    fi
    [ "$FORCE" -eq 1 ] && rm -rf "$MODULES_OUT"
    python3 "$ROOT/scripts/build_wine_modules.py" \
        --archive "$ARCHIVE" --output "$MODULES_OUT" --bison "$BISON"
fi

# ------------------------------------------------------------------ 5. runtime view
step "5/9 producing the runtime view"
if [ "$SKIP_BUILD" -eq 1 ] && [ -d "$RUNTIME_OUT/lib/wine" ]; then
    skip "--skip-build: reusing $RUNTIME_OUT"
elif [ -d "$RUNTIME_OUT/lib/wine" ] && [ "$FORCE" -ne 1 ]; then
    skip "$RUNTIME_OUT already exists (pass --force to regenerate)"
else
    [ "$FORCE" -eq 1 ] && rm -rf "$RUNTIME_OUT"
    python3 "$ROOT/scripts/prepare_runtime.py" \
        --output "$RUNTIME_OUT" --modules "$MODULES_OUT/build"
fi

# ---------------------------------------------------------------------- 6. prefix
step "6/9 creating the Wine prefix"
if [ -f "$PREFIX/system.reg" ]; then
    skip "$PREFIX already exists"
else
    "$ROOT/scripts/create_prefix.sh" "$PREFIX"
fi

# ------------------------------------------------------- 7. modules into the prefix
step "7/9 installing the patched modules into the prefix"
mkdir -p "$ROOT/local/backup"
for module in ntoskrnl.exe mfplat.dll mfreadwrite.dll lsass.exe; do
    source_file="$RUNTIME_OUT/lib/wine/x86_64-windows/$module"
    [ -f "$source_file" ] || die "missing $source_file"
    target="$PREFIX/drive_c/windows/system32/$module"
    if [ -f "$target" ] && cmp -s "$source_file" "$target"; then
        echo "  $module: already current"
        continue
    fi
    [ -f "$target" ] && cp -p "$target" "$ROOT/local/backup/$module"
    cp "$source_file" "$target"
    echo "  $module: replaced (previous copy in local/backup)"
done

# ------------------------------------------------------------------------ 8. game
step "8/9 installing NIKKE"
if [ -n "$INSTALLER_URL" ]; then
    mkdir -p "$ROOT/local/downloads"
    INSTALLER="$ROOT/local/downloads/$(basename "${INSTALLER_URL%%\?*}")"
    echo "  downloading $INSTALLER_URL"
    curl -L --fail --progress-bar -o "$INSTALLER.part" "$INSTALLER_URL" ||
        die "download failed; download it yourself and pass --installer PATH"
    mv "$INSTALLER.part" "$INSTALLER"
fi

if [ -n "$INSTALLER" ]; then
    [ -f "$INSTALLER" ] || die "installer not found: $INSTALLER"
    echo "  running the installer -- follow its prompts, keeping C:\\NIKKE\\Launcher"
    "$ROOT/scripts/create_prefix.sh" "$PREFIX" "$INSTALLER"
else
    cat <<EOF
  no installer given, skipping.
  Download the NIKKE PC International installer yourself, then either re-run:
      scripts/create_prefix.sh "$PREFIX" <installer.exe>
  or run this script again with --installer <installer.exe>.
EOF
fi

# ------------------------------------------------------------------------- 9. app
step "9/9 creating the launcher app"
"$ROOT/scripts/create_launch_app.sh"

# --------------------------------------------------------------------- summary
cat <<EOF

Done. Next steps:
  1. Open the launcher app and log in; let it download the assets (>10 GB, slow).
  2. Enable High Resolution Mode in CrossOver's bottle panel if you want a sharper image.

If the launcher shows a black screen or story scenes hang, see the troubleshooting
section of docs/INSTALL.zh-CN.md -- those are the two failures the patches address.
EOF
