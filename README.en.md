# NIKKE CrossOver Compatibility

**Running the Windows PC build of *Goddess of Victory: NIKKE* on Apple Silicon Macs through CrossOver.**

[中文](README.md) · [Install guide](docs/INSTALL.en.md) · [What is actually applied](docs/APPLIED-TECHNIQUES.en.md) · [Validation log](docs/VALIDATION.md) · [Architecture](docs/ARCHITECTURE.md) · [CEF rendering patch](docs/CHROMIUM-FLAGS.md)

A Wine compatibility patch set for NIKKE: it fixes failing to get in, story scenes
hanging, low frame rate, and a stray console window. Every claim here comes from
measurements on the machine described below; conclusions that turned out to be wrong
are kept, with their corrections, in the [validation log](docs/VALIDATION.md).

## Verified environment

| | Measured |
|---|---|
| Model / chip | Mac16,7 / **Apple M4 Pro** |
| macOS | **26.6.2** (25G83) |
| CrossOver | **26.1** |
| NIKKE PC International | **152.8.13** |
| Prefix | `~/Library/Application Support/NIKKE-Wine` |

Other hardware, CrossOver versions and later game updates are untested.

## What it fixes

**1. Launcher black screen / cannot get into the game**
Root cause: Rosetta 2 cannot translate the **register form** of the multi-byte NOP
(`0F 1F` with ModRM.mod = 3), which raises SIGILL and kills both ACE's kernel driver
and Unity's IL2CPP. The fix is on the Wine side (ntoskrnl / ntdll). See
[this update](docs/UPDATE-2026-09-26.en.md).

**2. Hanging on entering a story scene**
Root cause: the two Media Foundation switches must be **paired**. With only
`NOP_BRIDGE_MF_NO_DXGI=1` the configuration is half-applied -- Unity cannot obtain a
DXGI device manager and falls back to software, while the reader still expects D3D
frames, so the video pipeline stalls once it starts: the process stays alive, one core
spins at 103% CPU, and `Player.log` goes silent for minutes. Adding
`NOP_BRIDGE_MF_SOFTWARE=1` makes story playback work.

**3. Low frame rate**
Root cause: `CX_GRAPHICS_BACKEND=dxvk` **had never actually taken effect**. The runtime
view sits on `WINEDLLPATH` and **shadows the prefix**, so Wine resolved the d3d dlls from
the view to its builtins. Installing DXVK into the prefix plus a native override did not
help either -- that loads the view's builtin PE under the native name. Materialising DXVK
inside the view makes it genuinely load, with a clear frame-rate improvement.

**4. A conhost window on every launch that outlives the launcher**
Root cause: this project's own `lsass.exe` is built as a console application and
registered as a service, so Wine allocates a console for it. That window belongs to the
service rather than to the launcher, which is why closing the launcher never closed it.
Building it as a GUI application removes the window; the service is unaffected.

## Launching it

**Double-click `~/Applications/NIKKE Wine.app`, then press 启动.**

The app is self-contained (the Wine loader lives inside it) and calls
`scripts/launch_nikke.sh`, whose defaults are the verified configuration:

```
NOP_BRIDGE_MF_NO_DXGI / NOP_BRIDGE_MF_SOFTWARE = 1    story video does not hang
CX_GRAPHICS_BACKEND = dxvk plus d3d9,d3d10,d3d10_1,d3d10core,d3d11=n,b    makes DXVK load
NOP_BRIDGE_PRIVILEGED = 1
```

Equivalent from a shell: `cd <repo> && scripts/launch_nikke.sh`

> No CrossOver menu entry is used on this machine. `install_crossover_entry.py` is still
> present for the flow that clones a separate bottle from a source bottle, but this setup
> uses the prefix above plus the self-built launcher app.

## Building

Requires Xcode Command Line Tools, Python 3, Bison 3 and MinGW-w64.

```sh
# 1. macOS side (the Rosetta NOP bridge)
make && make test

# 2. Download the official CrossOver 26.1 source archive
#    https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.1.0.tar.gz
python3 scripts/build_wine_modules.py \
    --archive /absolute/path/to/crossover-sources-26.1.0.tar.gz \
    --output local/wine-modules

# 3. Create the runtime view
#    This overlays the five patched modules, materialises DXVK, and flips lsass.exe
#    to the GUI subsystem.
python3 scripts/prepare_runtime.py \
    --output local/runtime-modules \
    --modules local/wine-modules/build
```

The step 3 output is **local only**: it holds absolute symlinks and third-party binaries.
Do not publish it; regenerate it on each machine.

The launcher app is a thin shell and can be recreated at any time:

```sh
make                                   # produces build/NopBridgeLab.app with the Wine loader
APP="$HOME/Applications/NIKKE Wine.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
printf '#!/bin/sh\nexec "%s/scripts/launch_nikke.sh" "$@"\n' "$PWD" > "$APP/Contents/MacOS/launch"
chmod +x "$APP/Contents/MacOS/launch"
cp build/NopBridgeLab.app/Contents/MacOS/wine_bootstrap "$APP/Contents/MacOS/nikke_wine"
cp src/Info.plist "$APP/Contents/Info.plist"
```

## What the runtime replaces

Five modules (`ntoskrnl.exe`, `mfplat.dll`, `mfreadwrite.dll`, `lsass.exe`, and the Unix
`ntdll.so`), the PE `ntdll.dll` that pairs with it, and the DXVK dlls inside the view.
Full hashes, the evidence for each file and the order of the ten patches are in
[what is actually applied](docs/APPLIED-TECHNIQUES.en.md).

## Known limits

All measured, not assumed:

- **GPU video pass-through is not achievable.** Unity's Media Foundation path needs a DXGI
  device manager, and **Wine's own `MFCreateDXGIDeviceManager` cannot supply one in this
  environment** (the error context is literally `Context: Creating DXGIDeviceManager`).
  Video frames therefore travel through system memory, costing one extra GPU-to-memory-to-GPU
  copy per frame. This is also why the two switches in item 2 are **required**, independent of
  the rendering backend -- switching to DXVK does not change it.
- **The decode itself is still hardware.** The GStreamer pipeline uses `vtdec_hw`, a
  VideoToolbox hardware-only element; only the frame handoff is on the CPU, so this is not
  "decoding on the CPU".
- **ACE CORE driver processes still record abnormal exits**, though they do not block the
  game. That is not a statement that every anti-cheat component is healthy.
- No long-run stability testing and no quantitative FPS measurement. CrossOver or game
  updates may require re-adapting.

## Pitfalls (read before changing anything)

- **The view's `lib/wine/i386-windows` is a symlink back into CrossOver's own install.**
  Running `rm` plus `cp` beneath it rewrites CrossOver itself -- this project damaged the
  32-bit d3d dlls that way once. Check that a view directory is not such a link first.
- **Never overwrite this project's `ntoskrnl.exe` with CrossOver's** -- the project's build
  is a superset.
- **Do not judge the backend from the environment variable.** Check which dlls actually
  loaded and their sizes (DXVK's `d3d11.dll` is about 3165760 bytes, Wine's builtin about
  425552).
- **`build/wine_bootstrap` is a symlink created by `make`**, pointing at `build/NopBridgeLab.app/Contents/MacOS/wine_bootstrap`. Before `make` has run it is a **broken link**: `cat` prints nothing and `stat` reports 46 bytes (the length of the target path), so it looks like an empty file.
- Watch what you search for in a binary: `CreateSharedHandle` is a COM vtable method
  implemented in `d3d11.dll`, so grepping only `dxgi.dll` yields a false negative.

## Licence and credits

**LGPL-2.1-or-later**, see [LICENSE](LICENSE) and [THIRD_PARTY.md](THIRD_PARTY.md).

The repository ships source only; it contains no game, ACE files, CrossOver binaries or
account data. It neither modifies nor redistributes the game or ACE binaries, and it does
not replace failing interface queries with fixed success values -- some interfaces still
report unsupported.

Thanks to Wine, CodeWeavers, DW-Proton, Endfield_FineWine and the earlier launcher-fix
projects for their public work. NIKKE, CrossOver and Rosetta are products of their
respective owners; this is independent community compatibility research.
