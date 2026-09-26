# Installation Guide

Getting *Goddess of Victory: NIKKE* (Windows PC) running on an Apple Silicon Mac,
plus how to update this project's compatibility patches afterwards.

Based on the actual installation performed 2026-09-22 ~ 09-23.
Every command and path below was verified on the reference machine.

---

## Contents

- [1. Prerequisites](#1-prerequisites)
- [2. Installing NIKKE](#2-installing-nikke)
- [3. Building the compatibility patches](#3-building-the-compatibility-patches)
- [4. Installing into the Wine prefix](#4-installing-into-the-wine-prefix)
- [5. Verifying the installation](#5-verifying-the-installation)
- [6. Launching](#6-launching)
- [7. Updating](#7-updating)
- [8. Troubleshooting](#8-troubleshooting)

---

## 1. Prerequisites

| Item | Version |
|---|---|
| Hardware | Apple Silicon (M-series); measured on **Apple M4 Pro** (Mac16,7) |
| macOS | **26.6.2** (25G83, measured) |
| CrossOver | 26.1 |
| Game | NIKKE PC International **152.8.13** (measured) |
| Rosetta | installed |
| Python | 3.x |
| Xcode CLT | installed |
| Bison | 3.x (`brew install bison`) |
| MinGW-w64 | for building Windows probes |

```sh
brew install bison mingw-w64
```

Bison defaults to `/opt/homebrew/opt/bison/bin/bison`; override with `--bison`.

### Path conventions

```
repo        ~/work/nikke-crossover-compat
Wine prefix ~/Library/Application Support/NIKKE-Wine
build       <repo>/local/runtime-modules
launcher    ~/Applications/NIKKE Wine.app
```

---

## 2. Installing NIKKE

> Skip to [section 3](#3-building-the-compatibility-patches) if the official
> launcher already opens and logs in.

### 2.1 Download the PC build

Get the **NIKKE PC International** installer (`NIKKE.PC_Offcial_GL_<version>.exe`).
Verified version: `152.8.13`.

### 2.2 Install via CrossOver

1. CrossOver → **Install Windows Software**
2. Pick the downloaded installer
3. Suggested bottle name: `NIKKE-Compatibility`
4. Keep the default install path `C:\NIKKE\Launcher`

### 2.3 First launch — let it download assets

Launch the official launcher from CrossOver, log in, and **let it finish
downloading all assets**.

> ⚠️ The initial download exceeds 10 GB and the game's own downloader is slow
> (~0.3 MB/s). On a poor connection this can take hours.

### 2.4 Confirm the launcher works

The official launcher opens, logs in, and shows a "Start Game" button.
If the launcher itself does not open, fix that first — this project's patches
do not repair the launcher.

---

## 3. Building the compatibility patches

Run everything from the repository root.

### 3.1 Build the native compatibility layer

```sh
cd ~/work/nikke-crossover-compat
make
make test
```

### 3.2 Fetch the CrossOver source

```sh
curl -LO https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.1.0.tar.gz
```

### 3.3 Build the Wine patch modules

```sh
python3 scripts/build_wine_modules.py \
    --archive "$PWD/crossover-sources-26.1.0.tar.gz" \
    --output local/wine-modules
```

Patches applied, in order:

| Patch | Purpose |
|---|---|
| `crossover-26.1-kernel.patch` | Rosetta NOP forms and privileged-exception handling |
| `crossover-26.1-thread-process-experimental.patch` | thread owning-process queries |
| `crossover-26.1-september-update.patch` | 152.8.11 driver entry points and memory mapping |
| `crossover-26.1-ace-kernel-exports.patch` | **kernel exports required by ACE** |
| `crossover-26.1-mf-software.patch` | video software fallback (fixes the black screen) |

The script verifies a pinned SHA-256 of the source archive and refuses to
build on mismatch.

### 3.4 Produce the runtime

```sh
python3 scripts/prepare_runtime.py \
    --output local/runtime-modules \
    --modules local/wine-modules/build
```

Besides the five patched modules, this step places **DXVK** into the view and flips the
view's `lsass.exe` PE subsystem to **GUI** (otherwise every launch pops up a conhost window
that will not close). Both must take effect inside the view: it sits on `WINEDLLPATH` and
**shadows the prefix**.

---

## 4. Installing into the Wine prefix

### 4.1 Option A — existing prefix (recommended)

Replace only the compatibility modules:

**Five files** are replaced: four under `x86_64-windows/`, one under
`x86_64-unix/`. The full list and hashes are in [5.1](#51-check-module-hashes).

```sh
PREFIX="$HOME/Library/Application Support/NIKKE-Wine"
RUNTIME="$PWD/local/runtime-modules"

# back up the originals
mkdir -p /tmp/nikke-compat-backup
for f in ntoskrnl.exe mfplat.dll mfreadwrite.dll lsass.exe; do
  cp "$PREFIX/drive_c/windows/system32/$f" /tmp/nikke-compat-backup/ 2>/dev/null
done

for f in ntoskrnl.exe mfplat.dll mfreadwrite.dll lsass.exe; do
  cp "$RUNTIME/lib/wine/x86_64-windows/$f" "$PREFIX/drive_c/windows/system32/"
done
```

> The Unix-side `ntdll.so` (user-mode Rosetta NOP emulation) reaches Wine
> through the app's `NOP_BRIDGE_NTDLL`, which points at the runtime view, so it
> does **not** need copying into the prefix. Two things must hold:
> `local/runtime-modules/lib/wine/x86_64-unix/ntdll.so` is the patched one, and
> `lib/wine/x86_64-windows/ntdll.dll` **exists alongside it**. ntdll is a
> Unix/PE pair; overlaying the `.so` without the PE `.dll` fails to start with
> > **Update both the prefix and the view.** The view sits on `WINEDLLPATH` and shadows the
> prefix, so updating only one layer leaves them inconsistent.

`error c0000135`. Generating the view with `prepare_runtime.py` cannot miss
> this, because the script copies that unmodified `ntdll.dll` in from CrossOver.

### 4.2 Option B — separate bottle

```sh
python3 scripts/install_crossover_entry.py \
    --source-prefix "$HOME/Library/Application Support/CrossOver/Bottles/YOUR_NIKKE_BOTTLE" \
    --source-runtime local/runtime-modules \
    --source-app build/NopBridgeLab.app \
    --source-bridge build/libnop_bridge.dylib \
    --bottle-name NIKKE-Compatibility-152 \
    --menu-name "NIKKE Compatibility 152" \
    --support "$HOME/Library/Application Support/NIKKE Compatibility 152"
```

Uses APFS cloning, preserves downloaded assets, leaves the source bottle
untouched, and never overwrites an existing target.

---

## 5. Verifying the installation

### 5.1 Check module hashes

```sh
RUNTIME="$PWD/local/runtime-modules"
for f in ntoskrnl.exe mfplat.dll mfreadwrite.dll lsass.exe; do
  md5 -q "$RUNTIME/lib/wine/x86_64-windows/$f"
done
md5 -q "$RUNTIME/lib/wine/x86_64-unix/ntdll.so"
```

Reference values :

```
ntoskrnl.exe     553a755df4792272d091168c7a4ac189
mfplat.dll       9e05b449b0042c1828db913def2a1bcc
mfreadwrite.dll  1d3509c2e55d5581fc2e26426b1fe440
lsass.exe        b09816da5eb8d431c748f7709ef7b390
ntdll.so         ae6489f07e27c0ddbf541d2db82446c9   (must be x86_64)
```

> `ntdll.so` **must** be `x86_64`. The host-default build produces `arm64`,
> which fails in the bootstrap with an obscure architecture error. Check it
> with `lipo -archs`.

### 5.2 Confirm the ACE exports are present

The built `ntoskrnl.exe` must export these (called by ACE):

```
KeTryToAcquireGuardedMutex
KeIpiGenericCall
KeGetProcessorNumberFromIndex
KeRevertToUserGroupAffinityThread
KeSetSystemGroupAffinityThread
ObDereferenceObjectDeferDelete
PsGetCurrentThreadTeb
```

A missing `KeAcquireGuardedMutex` makes ACE report
`unimplemented function ntoskrnl.exe.KeAcquireGuardedMutex` and refuse to start.

### 5.3 Run the interface tests

```sh
python3 scripts/test_wine_modules.py \
    --prefix "$PREFIX" \
    --runtime local/runtime-modules
```

---

## 6. Launching

**Double-click `~/Applications/NIKKE Wine.app`, then press 启动.**

The app is self-contained (the Wine loader lives inside it) and calls
`scripts/launch_nikke.sh`, whose defaults are the verified configuration (both MF switches,
DXVK, and the d3d native overrides). Equivalent from a shell:

```sh
cd ~/work/nikke-crossover-compat && scripts/launch_nikke.sh
```

> If you created a separate bottle per [4.2](#42-option-b--separate-bottle) you can also
> launch from the CrossOver menu; with 4.1 (an existing prefix) there is no such entry, so use
> the app above.

The launch profile uses **DXVK**. Changing the graphics backend in CrossOver
does not rewrite this dedicated profile.

For a sharper image, enable **High Resolution Mode** on the right-hand panel
of the bottle and restart it.

> ⚠️ Never run `wineserver -k` — it kills every running Wine session.

---

## 7. Updating

### 7.1 Update the game

Let the official launcher download the update itself.

### 7.2 Update the compatibility patches (if the new version needs it)

```sh
cd ~/work/nikke-crossover-compat
git pull
git checkout <new-branch>

make && make test
python3 scripts/build_wine_modules.py \
    --archive "$PWD/crossover-sources-26.1.0.tar.gz" \
    --output local/wine-modules-<new>
python3 scripts/prepare_runtime.py \
    --output local/runtime-<new> \
    --modules local/wine-modules-<new>/build

RUNTIME="$PWD/local/runtime-<new>"
cp "$RUNTIME/lib/wine/x86_64-windows/ntoskrnl.exe" \
   "$HOME/Library/Application Support/NIKKE-Wine/drive_c/windows/system32/"
cp "$RUNTIME/lib/wine/x86_64-windows/lsass.exe" \
   "$HOME/Library/Application Support/NIKKE-Wine/drive_c/windows/system32/"
```

**Keep the old files until the new build is confirmed working.** To roll back:

```sh
cp /tmp/nikke-compat-backup/*.exe \
   "$HOME/Library/Application Support/NIKKE-Wine/drive_c/windows/system32/"
```

---

## 8. Troubleshooting


### Story scenes hang (process alive, one core at 100%, log frozen)

The two Media Foundation switches are **not paired**. `NOP_BRIDGE_MF_NO_DXGI=1` alone is a
half-applied state: Unity cannot get a DXGI device manager and falls back to software, while
the reader still expects D3D frames, so the video pipeline stalls. Adding
`NOP_BRIDGE_MF_SOFTWARE=1` fixes it. `scripts/launch_nikke.sh` carries both by default, so
the self-built launcher app never hits this.

### A conhost window appears on every launch and outlives the launcher

`lsass.exe` is a console application, so Wine allocates a console for that service; the
window belongs to the service rather than the launcher, which is why closing the launcher
does not close it. Flip its PE subsystem to GUI (`prepare_runtime.py` does this
automatically) and remember to update **both the prefix and the view**.

### `unimplemented function ntoskrnl.exe.KeAcquireGuardedMutex`

You are running CrossOver's stock `ntoskrnl.exe`, not the one built here.
Redo [section 4](#4-installing-into-the-wine-prefix).

> Note: our `ntoskrnl.exe` is a **superset** of CrossOver's. Restoring the
> original **breaks ACE**.

### Launcher black screen

Handled by `crossover-26.1-mf-software.patch` (video takes the software
fallback path). Confirm the patch was applied.

### ACE errors

Two background ACE CORE driver processes still exit abnormally (known
limitation). Playable does not mean every protection component is healthy.

### Game won't start after a game update

Major updates usually introduce new kernel calls. Use the `KeBugCheck` log:

```
ERR( "KeBugCheck %lx called from %p\n", code, __builtin_return_address(0) );
```

Then add the missing implementation to
`patches/crossover-26.1-ace-kernel-exports.patch`.

### Blurry image

Enable **High Resolution Mode** for the bottle in CrossOver and restart it.

---

## Appendix — full command sequence

```sh
cd ~/work/nikke-crossover-compat
make && make test

curl -LO https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.1.0.tar.gz

python3 scripts/build_wine_modules.py \
    --archive "$PWD/crossover-sources-26.1.0.tar.gz" \
    --output local/wine-modules

python3 scripts/prepare_runtime.py \
    --output local/runtime-modules \
    --modules local/wine-modules/build

PREFIX="$HOME/Library/Application Support/NIKKE-Wine"
RUNTIME="$PWD/local/runtime-modules"
cp "$RUNTIME/lib/wine/x86_64-windows/"{ntoskrnl.exe,lsass.exe} \
   "$PREFIX/drive_c/windows/system32/"
```

---

## License

**LGPL-2.1-or-later** — see [LICENSE](../LICENSE) and
[third-party notices](../THIRD_PARTY.md).
No game files, ACE binaries, CrossOver binaries, or account data are included.
