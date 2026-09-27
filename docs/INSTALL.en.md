# Installation Guide

Running NIKKE: Goddess of Victory (Windows PC, international) on an Apple Silicon Mac.

> **Just want one command?** From the repository root run
> `scripts/install_all.sh --installer <game-installer.exe>`.
> It does sections two through five in the order below and creates the launcher app. It can be
> re-run; finished steps are skipped. The rest of this guide is the same flow, step by step.

## Order matters

The four steps depend on each other, so **they cannot be reordered**:

| # | Step | Why it has to be here |
|---|---|---|
| 1 | Build the compatibility patches (including the runtime view) | Everything after it uses the Wine loader and libraries from the view |
| 2 | Create the prefix | `create_prefix.sh` needs the view (`bin/wineloader`, `lib/wine/x86_64-*`) and exits if it is missing |
| 3 | **Install the patched modules into the prefix** | The launcher needs them to render and to download resources |
| 4 | **Install the game** | Must come after the patches; the other way round gives a black launcher, a stall at "initialising" and downloads that never move |

Steps 3 and 4 are the ones people get backwards.

---

## Contents

- [1. Before you start](#1-before-you-start)
- [2. Build the compatibility patches](#2-build-the-compatibility-patches)
- [3. Create the prefix](#3-create-the-prefix)
- [4. Install the patches into the prefix](#4-install-the-patches-into-the-prefix)
- [5. Install the game](#5-install-the-game)
- [6. Verify](#6-verify)
- [7. Launching](#7-launching)
- [8. Updating](#8-updating)
- [9. Troubleshooting](#9-troubleshooting)

---

## 1. Before you start

### Requirements

| Item | Version |
|---|---|
| Hardware | Apple Silicon (M series); tested on an **Apple M4 Pro** (Mac16,7) |
| macOS | **26.6.2** (tested) |
| CrossOver | **26.3** (`brew install --cask crossover`) |
| Game | NIKKE PC International **152.8.13** (tested) |
| Rosetta | installed |
| Python | 3.x |
| Xcode CLT | installed |
| Bison | 3.x |
| MinGW-w64 | to build the Windows probe |

```sh
brew install bison mingw-w64
```

Bison is normally at `/opt/homebrew/opt/bison/bin/bison`; pass `--bison` if yours is elsewhere.

> The patches are anchored to 26.3's source and the build verifies the archive's SHA-256. More than
> 800 files in the runtime view are **symlinks into CrossOver's install directory**, so after
> upgrading CrossOver you must rebuild the modules from that same version's source. The patches
> apply to 26.1 and 26.3 alike.

### Paths used below

```
repository  /path/to/nikke-crossover-compat
prefix      ~/Library/Application Support/NIKKE-Wine
build       <repository>/local/runtime-modules
launcher    ~/Applications/NIKKE Wine.app
```

> `/path/to/nikke-crossover-compat` stands for wherever you cloned this repository.

---

## 2. Build the compatibility patches

Run these **from the repository root**.

### 2.1 Build the macOS-side layer

```sh
cd /path/to/nikke-crossover-compat
make
make test
```

### 2.2 Download the CrossOver source archive

```sh
curl -LO https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz
```

### 2.3 Build the patched Wine modules

```sh
python3 scripts/build_wine_modules.py \
    --archive "$PWD/crossover-sources-26.3.0.tar.gz" \
    --output local/wine-modules
```

The script applies the patches in a fixed order and verifies the archive's SHA-256, refusing to
build on a mismatch:

| Patch | File | What it does |
|---|---|---|
| `crossover-kernel.patch` | `ntoskrnl.exe/sync.c` | kernel synchronisation primitives (guarded mutexes and friends) |
| `crossover-thread-process-experimental.patch` | `ntoskrnl.exe/ntoskrnl.c` | thread-to-process lookup |
| `crossover-september-update.patch` | `ntoskrnl.exe/instr.c` | driver entry point and memory mapping |
| `crossover-ace-kernel-exports.patch` | `ntoskrnl.exe/sync.c` | **the kernel exports ACE needs** |
| `crossover-ace-extended-exports.patch` | `ntoskrnl.exe/ntoskrnl.c` | further kernel exports ACE needs |
| `crossover-ace-core-driver-stubs.patch` | `ntoskrnl.exe/ntoskrnl.c` | stubs the ACE CORE drivers call |
| `crossover-ntoskrnl-rosetta-nop.patch` | `ntoskrnl.exe/instr.c` | multi-byte NOP emulation in kernel mode |
| `crossover-rosetta-multibyte-nop.patch` | `ntdll/unix/signal_x86_64.c` | multi-byte NOP emulation in user mode (Rosetta) |
| `crossover-mf-software.patch` | `mfreadwrite/reader.c` | software video fallback (cutscenes no longer hang) |
| `crossover-chromium-flags.patch` | `ntdll/loader.c` | **appends `--in-process-gpu` to `tbs_browser.exe` (fixes the black launcher)** |

### 2.4 Produce the runtime view

```sh
python3 scripts/prepare_runtime.py \
    --output local/runtime-modules \
    --modules local/wine-modules/build
```

Besides the five patched modules this puts **DXVK** into the view and flips the view's
`lsass.exe` to the **GUI** subsystem (otherwise every launch leaves behind a conhost window you
cannot close).

Both have to take effect in the view: it is mounted on `WINEDLLPATH` and **shadows the prefix**.

---

## 3. Create the prefix

**No CrossOver GUI is involved, and no CrossOver bottle is created.** Only the Wine libraries
CrossOver installs are used; the prefix is created from the command line and is a **plain Wine
prefix**, so it never shows up in CrossOver's bottle list.

```sh
scripts/create_prefix.sh "$HOME/Library/Application Support/NIKKE-Wine"
```

`wineboot` prints a number of `err:` lines while creating it (`cxcompatdb`, `setupapi` and so on).
That noise is normal. `prefix created` means it worked.

---

## 4. Install the patches into the prefix

> ⚠️ **This has to be done before installing the game.** Without the patches the launcher comes up
> black, stalls at "initialising" and cannot download resources.

Five PE modules are replaced:

```sh
PREFIX="$HOME/Library/Application Support/NIKKE-Wine"
RUNTIME="$PWD/local/runtime-modules"

# keep the originals
mkdir -p /tmp/nikke-compat-backup
for f in ntoskrnl.exe mfplat.dll mfreadwrite.dll lsass.exe ntdll.dll; do
  cp -p "$PREFIX/drive_c/windows/system32/$f" /tmp/nikke-compat-backup/ 2>/dev/null
done

# install
for f in ntoskrnl.exe mfplat.dll mfreadwrite.dll lsass.exe ntdll.dll; do
  cp "$RUNTIME/lib/wine/x86_64-windows/$f" "$PREFIX/drive_c/windows/system32/"
done
```

**The PE `ntdll.dll` does go in; the Unix `ntdll.so` does not.**
`ntdll.dll` carries the patch that appends `--in-process-gpu` to the launcher's embedded
TBS/Chromium, so it must come from the same build as the view's `ntdll.so` -- otherwise the
PE and Unix halves of ntdll are different builds. The `.so` is loaded through the launcher
app's `NOP_BRIDGE_NTDLL` and stays in the view. The launcher app points `NOP_BRIDGE_NTDLL` at the view,
so only two things matter:

1. `local/runtime-modules/lib/wine/x86_64-unix/ntdll.so` is the patched one;
2. `lib/wine/x86_64-windows/ntdll.dll` **must exist alongside it**.

The second point is an easy trap: `ntdll` is a Unix/PE pair, and replacing only the `.so` while
the `.dll` is missing fails at startup with `error c0000135`. Generating the view with
`prepare_runtime.py` cannot miss it.

> **Update both layers.** The view shadows the prefix, so updating only one of them leaves the
> view fixed and the prefix stale.

> If you already have a prefix with NIKKE installed (for example a CrossOver bottle created through
> the GUI), this section is all you need. To build a separate copy with a CrossOver menu entry
> while leaving the original untouched, use `scripts/install_crossover_entry.py --help`.

---

## 5. Install the game

### 5.1 Download the PC client

Download the **NIKKE PC International** installer (`NIKKE.PC_Offcial_GL_<version>.exe`). Verified
here with `152.8.13`.

### 5.2 Run the installer

```sh
scripts/create_prefix.sh "$HOME/Library/Application Support/NIKKE-Wine" \
    ~/Downloads/NIKKE.PC_Offcial_GL_<version>.exe
```

The prefix already exists, so the script skips creating it and only runs the installer. Follow the
prompts and keep the default install path `C:\NIKKE\Launcher`.

### 5.3 Create the launcher app

```sh
scripts/create_launch_app.sh
```

This produces `~/Applications/NIKKE Wine.app`, self-contained with the Wine loader inside it.

---

## 6. Verify

```sh
python3 scripts/test_wine_modules.py \
    --prefix "$HOME/Library/Application Support/NIKKE-Wine" \
    --runtime local/runtime-modules
```

Also confirm `ntdll.so` is **x86_64**:

```sh
lipo -archs local/runtime-modules/lib/wine/x86_64-unix/ntdll.so
```

> It must say `x86_64`. An `arm64` build fails during bootstrap with an obscure architecture error.

---

## 7. Launching

**Double-click `~/Applications/NIKKE Wine.app` and press the launch button.**

The equivalent command line:

```sh
cd /path/to/nikke-crossover-compat && scripts/launch_nikke.sh
```

The script's defaults are the verified configuration (both Media Foundation switches,
`CX_GRAPHICS_BACKEND=dxvk`, the d3d native overrides), so using the app cannot leave one out.

### First launch: let it download resources

Log in, then **let it finish downloading** before pressing launch.

> The first download is large (over 10 GB) and the game's own downloader is slow; on a poor
> connection it takes hours.

> If the picture looks soft, turn on **high resolution mode** in the CrossOver bottle settings and
> restart the bottle.

> ⚠️ Never run `wineserver -k` -- it kills every Wine session you have open.

---

## 8. Updating

### 8.1 Update in game

When a new build ships, let the official launcher finish its update first.

### 8.2 Update the patches (if the new build needs it)

```sh
cd /path/to/nikke-crossover-compat
git pull

# build into a new directory so the one in use is untouched
make && make test
python3 scripts/build_wine_modules.py \
    --archive "$PWD/crossover-sources-26.3.0.tar.gz" --output local/wine-modules-new
python3 scripts/prepare_runtime.py \
    --output local/runtime-modules-new --modules local/wine-modules-new/build

# back up and replace all five modules (same as section 4; leaving out
# mfplat / mfreadwrite makes cutscenes hang again)
PREFIX="$HOME/Library/Application Support/NIKKE-Wine"
mkdir -p /tmp/nikke-compat-backup
for f in ntoskrnl.exe mfplat.dll mfreadwrite.dll lsass.exe ntdll.dll; do
  cp -p "$PREFIX/drive_c/windows/system32/$f" /tmp/nikke-compat-backup/
  cp "local/runtime-modules-new/lib/wine/x86_64-windows/$f" \
     "$PREFIX/drive_c/windows/system32/"
done

# switch the view to the new one
mv local/runtime-modules local/runtime-modules-old
mv local/runtime-modules-new local/runtime-modules
```

**Keep the old files until the new build is confirmed working.** To roll back:

```sh
cp /tmp/nikke-compat-backup/* "$PREFIX/drive_c/windows/system32/"
mv local/runtime-modules local/runtime-modules-bad
mv local/runtime-modules-old local/runtime-modules
```

---

## 9. Troubleshooting

### Launcher is black, stalls at "initialising", or downloads never move

The patches are not in the prefix, or the prefix and the view disagree. Redo
[section 4](#4-install-the-patches-into-the-prefix) and make sure **both** layers were updated.

### Cutscenes hang (process alive, 100% CPU, log stops)

The two Media Foundation switches are **not paired**. `NOP_BRIDGE_MF_NO_DXGI=1` on its own is a
half configuration: Unity gets no DXGI device manager, falls back to software, while the reader
side still expects D3D frames, and the video pipeline stalls. Add
`NOP_BRIDGE_MF_SOFTWARE=1`. `scripts/launch_nikke.sh` already sets both.

### A conhost window appears on every launch and outlives the launcher

`lsass.exe` is a CONSOLE application, so Wine gives that service a console window, and the window
belongs to the service rather than the launcher. Flipping its PE subsystem to GUI fixes it
(`prepare_runtime.py` does this). Update **both** the prefix and the view afterwards.

### Startup fails with `unimplemented function ntoskrnl.exe.KeAcquireGuardedMutex`

The stock CrossOver `ntoskrnl.exe` is installed instead of the one built here. Redo
[section 4](#4-install-the-patches-into-the-prefix).

> The `ntoskrnl.exe` built here is a **superset** of CrossOver's; putting the original back
> **breaks ACE**. The built one should export `KeTryToAcquireGuardedMutex`, `KeIpiGenericCall`,
> `KeGetProcessorNumberFromIndex`, `PsGetCurrentThreadTeb` and the rest of what ACE calls.

### ACE errors

Two background ACE CORE driver processes still exit abnormally (a known limit). Being playable does
not mean every protection component is healthy.

### The game will not start after an update

Large game updates tend to call new kernel interfaces. Find out what is missing from the
`KeBugCheck` log:

```
ERR( "KeBugCheck %lx called from %p\n", code, __builtin_return_address(0) );
```

Then add the implementation to `patches/crossover-ace-kernel-exports.patch`.

---

## Licence

This repository is **LGPL-2.1-or-later**; see [LICENSE](../LICENSE) and
[third-party sources](../THIRD_PARTY.md). It contains no game files, no ACE files, no CrossOver
binaries and no account data.
