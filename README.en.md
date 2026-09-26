# NIKKE CrossOver Compatibility

**Running the Windows PC build of *Goddess of Victory: NIKKE* on Apple Silicon Macs through CrossOver.**

[中文](README.md) · [Install guide](docs/INSTALL.en.md)

A set of Wine compatibility patches that fix startup failure, story scenes hanging, low frame
rate, and a stray console window on Apple Silicon. Everything below was verified on the machine
described here.

## Requirements

| | Needed |
|---|---|
| Mac | Apple Silicon (verified on an **M4 Pro**) |
| macOS | **26.6.2** |
| CrossOver | **26.1**, with Rosetta installed |
| Game | NIKKE PC International (**152.8.13 verified**); already installed, with the official launcher opening and able to log in |
| Build tools | Xcode Command Line Tools, Python 3, Bison 3, MinGW-w64 |

This repository ships source only; it contains no game, ACE files, CrossOver binaries or account
data.

## Installing

**One command (recommended):**

```sh
scripts/install_all.sh --installer ~/Downloads/NIKKE.PC_Offcial_GL_<version>.exe
```

It checks prerequisites, downloads and verifies the CrossOver source archive, builds the macOS
layer, builds the Wine patch modules (**tens of minutes**), produces the runtime, creates the
prefix, installs the four modules, runs the game's installer, and creates the launcher app.
**Re-running is safe**: finished steps are skipped.

Two things it cannot do for you:

- **Install CrossOver** -- commercial software; install it first.
- **Download the NIKKE client** -- there is no stable public URL. Download it yourself and pass
  `--installer <path>`, or give a direct link with `--installer-url <url>`.

Logging in and the >10 GB asset download happen inside the launcher and cannot be automated.

<details>
<summary>Prefer to do it step by step, or want to see what each stage does</summary>

```sh
# 1. the macOS-side compatibility layer
make && make test

# 2. build the Wine patch modules from the CrossOver 26.1 source archive (download it first)
python3 scripts/build_wine_modules.py \
    --archive /path/to/crossover-sources-26.1.0.tar.gz --output local/wine-modules

# 3. produce the runtime view
python3 scripts/prepare_runtime.py \
    --output local/runtime-modules --modules local/wine-modules/build

# 4. create the prefix and install the game (no CrossOver GUI, no CrossOver bottle)
#    the second argument is the installer; omit it to only create the prefix
scripts/create_prefix.sh "$HOME/Library/Application Support/NIKKE-Wine" <installer.exe>

# 5. install the runtime modules into the prefix and create the launcher app
for f in ntoskrnl.exe mfplat.dll mfreadwrite.dll lsass.exe; do
  cp "local/runtime-modules/lib/wine/x86_64-windows/$f" \
     "$HOME/Library/Application Support/NIKKE-Wine/drive_c/windows/system32/"
done
scripts/create_launch_app.sh

```

Full details are in the **[install guide](docs/INSTALL.en.md)**. Skip step 4 if NIKKE is already
installed. **Neither installing nor playing needs CrossOver's graphical interface.**

</details>

## Launching

**Double-click `~/Applications/NIKKE Wine.app`, then press 启动.**

The app is self-contained (the Wine loader lives inside it) and calls `scripts/launch_nikke.sh`,
which already carries every required setting. Equivalent from a shell:

```sh
cd <this repo> && scripts/launch_nikke.sh
```

## What it fixes

| Problem | Cause | Fixed by |
|---|---|---|
| Launcher black screen / cannot get in | Rosetta 2 cannot translate the **register form** of the `0F 1F` multi-byte NOP, which kills both ACE's kernel driver and Unity's IL2CPP | the Wine-side ntoskrnl / ntdll patches |
| Story scenes hang | The two Media Foundation switches **must be paired**; `NOP_BRIDGE_MF_NO_DXGI=1` alone stalls the video pipeline | `NOP_BRIDGE_MF_SOFTWARE=1` |
| Low frame rate | `CX_GRAPHICS_BACKEND=dxvk` on its own does nothing -- the runtime view shadows the prefix | DXVK placed inside the view, plus the d3d native overrides |
| A conhost window on every launch | `lsass.exe` is a console application, so Wine allocates a console for that service | rebuilt as a GUI application |

All but the first are baked into `scripts/launch_nikke.sh` and `scripts/prepare_runtime.py`, so a
normal install needs no manual configuration.

## If something goes wrong

See [troubleshooting in the install guide](docs/INSTALL.en.md#8-troubleshooting). The usual ones:

- **Story scenes hang** (process alive, one core at 100%, log frozen): the two MF switches are
  unpaired.
- **A black window appears on every launch and will not close**: `lsass.exe`'s subsystem was not
  changed, or only one of the two layers was updated.
- **Launcher black screen**: make sure you launched through this repository's entry, not
  CrossOver's own menu entry.

## Known limits

- **GPU video pass-through is not achievable.** Unity's Media Foundation path needs a DXGI device
  manager, and Wine's own `MFCreateDXGIDeviceManager` cannot supply one here. Video frames
  therefore travel through system memory, costing one extra copy per frame; this is also why the
  two MF switches above are **required**, independent of the rendering backend.
- **The decode itself is still hardware** (VideoToolbox / `vtdec_hw`); only the frame handoff is on
  the CPU. This is not "decoding on the CPU".
- **ACE CORE driver processes still record abnormal exits**, though they do not block the game.
- Verified only on the single environment above; CrossOver or game updates may need re-adapting.

## Licence and credits

**LGPL-2.1-or-later**, see [LICENSE](LICENSE) and [THIRD_PARTY.md](THIRD_PARTY.md).

This project neither modifies nor redistributes the game or ACE binaries, and it does not replace
failing interface queries with fixed success values.

Thanks to Wine, CodeWeavers, DW-Proton, Endfield_FineWine and the earlier launcher-fix projects
for their public work. NIKKE, CrossOver and Rosetta are products of their respective owners; this
is independent community compatibility research.
