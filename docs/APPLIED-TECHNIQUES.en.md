# The working solution: what is actually applied

This file answers one question: **which techniques does the runtime that
currently launches the game actually use?** Every claim comes from measuring
the installed runtime, not from restating the design. The method is in
section 6 so each claim can be reproduced.

---

## 1. Summary

The runtime view holds 840 entries: **828 symlinks** into the installed
CrossOver (unmodified) and **7 real files**. Of those seven, **six are
replaced**:

```
lib/wine/x86_64-windows/ntoskrnl.exe      <- replaced (customized)
lib/wine/x86_64-windows/mfplat.dll        <- replaced (customized)
lib/wine/x86_64-windows/mfreadwrite.dll   <- replaced (customized)
lib/wine/x86_64-windows/lsass.exe         <- replaced (customized)
lib/wine/x86_64-unix/ntdll.so             <- replaced (customized)
lib/wine/x86_64-windows/ntdll.dll         <- replaced (Chromium/CEF command line, 5.2)
LOCAL_ONLY.txt                            <- notes
```

Add one macOS-side dylib and one locally built bootstrap, and that is the
whole thing.

---

## 2. The five replaced files

| File | md5 | Produced by | Required? |
|---|---|---|---|
| `x86_64-windows/ntoskrnl.exe` | `553a755df4792272d091168c7a4ac189` | 7 kernel patches | **yes, proven** |
| `x86_64-unix/ntdll.so` | `ae6489f07e27c0ddbf541d2db82446c9` | `rosetta-multibyte-nop` | in use (necessity not isolated) |
| `x86_64-windows/mfplat.dll` | `9e05b449b0042c1828db913def2a1bcc` | `mf-software` | in use |
| `x86_64-windows/mfreadwrite.dll` | `1d3509c2e55d5581fc2e26426b1fe440` | `mf-software` | in use |
| `x86_64-windows/lsass.exe` | `3410c261f87e9d36ba1614d883b9e824` | `src/lsass.c` | in use (RunServices entry) |
| `x86_64-windows/ntdll.dll` | see 5.2 | `chromium-flags` | in use (CEF render patch, and the `.so`'s pair) |

**`ntoskrnl.exe` is the only file proven to be load-bearing.** Before the
kernel-mode Rosetta NOP patch, the ACE dialog appeared every time and
`ACE-CORE102797` sat at `STOPPED` (`error 31`); only after the patch did it
become `RUNNING` and the dialog disappear.

---

## 3. What the ten patches do

The order cannot be permuted — each patch is generated against the file as the
previous ones left it.

| # | Patch | Files | Effect | Lands in |
|---|---|---|---|---|
| 1 | `kernel` | `sync.c` `ntoskrnl.c` `ntoskrnl_private.h` `*.spec` | Kernel infrastructure: synchronization, object-name lifetime, callback-list ownership, caller-owned memory-range arrays | ntoskrnl.exe |
| 2 | `thread-process-experimental` | `ntoskrnl.c` `*.spec` | Thread/process ownership | ntoskrnl.exe |
| 3 | `september-update` | `instr.c` `ntoskrnl.c` `*.spec` `*_private.h` | September upstream sync + kernel-mode RIP conversion | ntoskrnl.exe |
| 4 | `ace-kernel-exports` | `sync.c` `ntoskrnl.c` `*.spec` | Kernel exports ACE needs (first batch) | ntoskrnl.exe |
| 5 | `ace-extended-exports` | `ntoskrnl.c` `*.spec` | Kernel exports ACE needs (second batch) | ntoskrnl.exe |
| 6 | `ace-core-driver-stubs` | `ntoskrnl.c` `*.spec` | The ten stubs ACE's CORE drivers import | ntoskrnl.exe |
| 7 | **`ntoskrnl-rosetta-nop`** | `instr.c` | **Kernel-mode multi-byte NOP decode + handling `EXCEPTION_ILLEGAL_INSTRUCTION`** | ntoskrnl.exe |
| 8 | `rosetta-multibyte-nop` | `ntdll/unix/signal_x86_64.c` | User-mode `handle_rosetta_nop()` | **ntdll.so** |
| 9 | `mf-software` | `mfreadwrite/reader.c` `mfplat/main.c` | Media Foundation software fallback. **It contains two switches that must be paired**: `NOP_BRIDGE_MF_NO_DXGI` makes `MFCreateDXGIDeviceManager` return `E_NOTIMPL`, `NOP_BRIDGE_MF_SOFTWARE` stops the reader fetching a D3D manager. Setting only the first hangs the game -- see 5.3 | mfplat.dll, mfreadwrite.dll |

Patch 7 is the core of this fix. Patches 1–6 and 9 predate 0.4.0.

---

## 4. What is active on the macOS side

From `LSEnvironment` in `NIKKE Wine.app/Contents/Info.plist`. This part is
**unchanged**, per the standing constraint to leave it alone.

| Variable | Effect |
|---|---|
| `DYLD_INSERT_LIBRARIES` | Injects `libnop_bridge.dylib` (`src/bridge.c` + `nop_decode.h` + `priv_decode.h`) |
| `NOP_BRIDGE_PRIVILEGED=1` | Enables the `priv_decode` path: recasts a `MOV CR*` trap 6 as trap 13 |
| `NOP_BRIDGE_NTDLL` | Points at `runtime-modules/.../x86_64-unix/ntdll.so` (row 2 above) |
| `NOP_BRIDGE_MF_NO_DXGI=1` | Enables the NO_DXGI branch of `mf-software`. **Must be set together with `NOP_BRIDGE_MF_SOFTWARE=1`**, or the video pipeline stalls and hangs the game (see 5.3) |
| `NOP_BRIDGE_APP_PROGRAM/CWD` | Names the hosted program and its working directory |
| `NOP_BRIDGE_LOG` | Where the bridge writes |
| `CX_GRAPHICS_BACKEND=dxvk` | **DXVK is the backend, not CrossOver's DXMT/Metal** — this decides section 5.1 |
| `WINEDLLPATH` | Points at the runtime view's `lib/wine/{x86_64-windows,i386-windows}` |
| `WINEDLLOVERRIDES=version=n,b` | Native-first for the version DLL |
| `WINEARCH=wow64` | Prefix architecture |
| `WINE(L)OADER` / `WINESERVER` / `CX_ROOT` / `WINEPREFIX` | Launch and container resolution |

**`NOP_BRIDGE_TRACE` is not set**, so the bridge prints nothing even when it
hits. A count of zero `[nop-bridge] emulated register NOP` lines in
`NOP_BRIDGE_LOG` is *not* evidence that the bridge never fired.

---

## 5. What this round removed

### 5.1 Deleted `x86_64-unix/winemetal.so` (24 MB)

Three independent pieces of evidence that it was dead weight:

1. **It is not the graphics backend.** The app sets
   `CX_GRAPHICS_BACKEND=dxvk`, and the runtime log confirms DXVK loaded
   (`DXVK: cxaddon-1.10.3-1-25-g737aacd`).
2. **No PE module imports it.** Scanning import tables across
   `lib/wine/x86_64-windows/` and `lib/dxmt/x86_64-windows/`: `winemetal.dll`
   is imported by exactly three DLLs, `d3d11.dll`, `dxgi.dll` and
   `nvapi64.dll`, all under `lib/dxmt/` — and **zero** under `lib/wine/`.
   DXMT is not selected, so none of those load.
3. **No script produces it.** `winemetal` appears 0 times in
   `prepare_runtime.py`, and `lib/dxmt` is already present as a symlink. This
   24 MB file is byte-identical to
   `CrossOver/lib/dxmt/x86_64-unix/winemetal.so`
   (`548cb7eeb4dbd993f193fa02226a6019`) — a manual, redundant copy.

The runtime view dropped from 30 MB to 6.9 MB and the smoke test passed
(`RUNTIME_OK`).

> If the backend is ever switched back to `CX_GRAPHICS_BACKEND=dxmt`, this
> `.so` has to be restored.

### 5.2 The PE `ntdll.dll` has to be there (a near miss)

It is byte-identical to CrossOver's original
(`28f9240613d2472d1091530bebf969a6`), so I first judged it a pointless copy and
deleted it. **The runtime then refused to start:**

```
wine: failed to load .../local/runtime-modules/lib/wine/x86_64-unix/ntdll.dll
error c0000135
```

`c0000135` is `STATUS_DLL_NOT_FOUND`. The reason is that **ntdll is a pair**:
the Unix `.so` and the PE `.dll` must sit together. Since our `.so` is overlaid,
the PE `.dll` has to be overlaid with it, or loading fails outright.

So the corrected conclusion is: **this `ntdll.dll` is required.**

**Where it comes from depends on whether a build was supplied:**

- **With a build (the normal flow) -> the built one**, because the
  `chromium-flags` patch changes the PE-side `dlls/ntdll/loader.c`; only a
  locally built `.dll` carries it.
- **Without a build -> CrossOver's original**, in which case only the Unix half
  is overlaid and the pair still holds.

Note the trade-off: using a locally built `ntdll.dll` **gives up CodeWeavers'
own PE-side ntdll patches**. That is inherent to the `chromium-flags` approach
(those two command-line switches cannot be added without editing `loader.c`),
not something this merge introduced.

> One more trap fixed along the way: `prepare_runtime.py` only turned
> `x86_64-windows` from a symlink into a real directory inside the
> `if modules:` branch. Copying `ntdll.dll` before that point would have written
> **through the symlink into the installed CrossOver directory**. The script now
> materializes that directory unconditionally before copying anything in;
> CrossOver's mtime and md5 were checked before and after and are unchanged.

### 5.3 The video pipeline stalls unless both MF switches are paired (new)

**Symptom.** Entering a story scene (`StoryEvent` / `EpisodePlayOverlay`) makes the
game **hang without exiting** -- process alive, one core pinned at 103% CPU,
`Player.log` silent (measured: 206 seconds). `sample` shows the video pipeline
threads all **blocked** in `g_cond_wait`, with ten GStreamer pipelines
(`qtdemux` / `multiqueue` / `vtdechw`) piled up in the process.

**Trigger.** The last thing in `Player.log` before the silence is five parallel

```
WindowsVideoMedia error 0x80004001
Context: Creating DXGI DeviceManager      <- this is where it fails
```

`0x80004001` is `E_NOTIMPL`, **produced by this patch's NO_DXGI branch**.

**Mechanism.** `NOP_BRIDGE_MF_NO_DXGI=1` prevents Unity from obtaining a DXGI
device manager (so Unity falls back to software), but the reader still behaves as
if D3D frames are coming. The mismatch stalls the pipeline once it starts.
Adding `NOP_BRIDGE_MF_SOFTWARE=1` makes the reader skip the D3D manager and emit
system-memory samples, matching Unity's software fallback; the stall goes away.

**Measured A/B** (environment identical except `MF_SOFTWARE`):

| | `NO_DXGI` only | `NO_DXGI` + `MF_SOFTWARE` |
|---|---|---|
| `using system-memory video samples` | **0** | **6** |
| The same `EventFieldHud -> StoryEvent` | hangs, 206 s silent | passes, continues to the battle result |
| Game process CPU | 103% (spinning) | ~52% (decoding) |
| Screen | frozen | story renders normally |

This does not contradict the earlier findings in `VALIDATION.md`; it completes
them. `MF_SOFTWARE` **alone** failed (the manager is still created, so Unity keeps
asking for `IMFDXGIBuffer` and logs `E_NOINTERFACE`). `NO_DXGI` **alone** was
enough for the download-screen background animation, but stalls on story video.
**Both together** are the self-consistent software video path.

> Note: as of this commit the combination has only been validated in a manually
> launched process. The app bundle's `Info.plist` does not yet carry
> `NOP_BRIDGE_MF_SOFTWARE`, so launching from the icon still hangs. See section 8.

### 5.4 GPU video pass-through: not settled (earlier conclusion corrected)

> **This section previously asserted that neither DXMT nor DXVK implements DXGI
> shared handles, and therefore that pass-through is impossible. That assertion
> was wrong and was corrected on 2026-09-26.** It was wrong for two methodological
> reasons, recorded here so the mistake is not repeated.

**Mistake one: the wrong module was searched.** `CreateSharedHandle` is a COM
vtable method implemented in **`d3d11.dll`**, not in `dxgi.dll`; searching only
`dxgi.dll` yields a false negative. All three implementations actually have it:

| Implementation | Evidence |
|---|---|
| DXVK `d3d11.dll` | `CreateSharedHandle: access / attributes / name`, `D3D11Device::OpenSharedResourceGeneric: Handle not found:`, `Failed to create shared resource:` |
| DXMT `d3d11.dll` | `dxmt::DeviceTexture<...>::CreateSharedHandle(_SECURITY_ATTRIBUTES*, unsigned long, wchar_t const*, void**)` (mangled symbols) |
| Wine builtin `d3d11.dll` | 4 matches |

**Mistake two: the test used the wrong backend.** The experiment that "hung as
soon as the DXGI path was opened" ran with `CX_GRAPHICS_BACKEND=d3dmetal`, which
on this machine is judged unusable and **silently falls back to Wine's builtin
d3d11**. That hang therefore only shows that the **builtin** implementation
cannot do it -- **DXVK was never tested with the DXGI path open**.

**What still holds:**

- With the DXGI path open the game hangs on a story scene (reproduced under the
  builtin d3d11): log silent for 200+ seconds, one core at 103% CPU, GStreamer
  pipelines piling up.
- The decoder really is `vtdec_hw` (VideoToolbox hardware); the frame handoff is
  what goes through system memory.
- `NOP_BRIDGE_MF_NO_DXGI` dates to 2026-09-08 (commit `9b1884d`), long before
  this fix.

**New open question.** DXVK's shared handles rely on Vulkan external-memory
handles, and MoltenVK exposes only the base `VK_KHR_external_memory` -- none of
`_win32`, `_fd` or `_metal`. So whether DXVK's shared handles function on macOS
is still undetermined; it may degrade to an in-process share table (DXVK has
`OpenSharedResourceGeneric` name-to-resource lookup), and **in-process sharing may
well be sufficient for Unity's MF path**.

**TODO:** retest with a **verified-active `dxvk` backend** (check the loaded dll
paths) plus both MF switches cleared. Until then, "pass-through is impossible"
should not be treated as a conclusion.

### 5.5 A backend-selection trap (operational note)

The valid `CX_GRAPHICS_BACKEND` values are `d3dmetal` / `dxmt` / `dxvk` / `wined3d`.
Wine-side `cxcompatdb.so` reads the variable and redirects the d3d dlls to
`lib/dxmt` or `lib/dxvk`.

**Measured here**: with `d3dmetal` the backend is judged unusable and the game
**silently falls back to Wine's builtin d3d11** -- it loads
`lib/wine/x86_64-windows/d3d11.dll` plus `libMoltenVK.dylib`. So **never conclude
the backend took effect from the environment variable alone**; check which dlls
were actually loaded:

```sh
lsof -p <game pid> | grep -iE "d3d11|dxgi" | awk '{print $NF}'
```

`lib/dxmt/...` or `lib/dxvk/...` means the backend is live;
`lib/wine/x86_64-windows/...` means it fell back to the builtin implementation.


### 5.6 DXVK has to live in the runtime view (and the view shadows the prefix)

**Background.** Wine's builtin wined3d is markedly slower than DXVK, which the user
confirmed feels far smoother. Yet in this project's configuration
`CX_GRAPHICS_BACKEND=dxvk` **had never actually taken effect**, for this reason.

**The view shadows the prefix.** `WINEDLLPATH` points at `local/runtime-modules`,
and Wine resolves the d3d dlls **from the view first**. Hence:

| Attempt | Result |
|---|---|
| Only `CX_GRAPHICS_BACKEND=dxvk` | fails -- resolved from the view to the builtin dll |
| Adding `CX_ACTIVE_GRAPHICS_BACKEND=dxvk` | no effect (measured, hypothesis disproven) |
| Installing DXVK into the prefix `system32` plus a native override | the override "works", but loads the **view's builtin PE as if it were native** |
| **Putting DXVK's dlls into the runtime view** | works -- genuinely loaded |

**How to verify (do not trust the environment variable):**

```sh
# the loaded dll's inode must equal the view's file
f=$(lsof -p <game pid> | awk '$NF ~ /d3d11.dll$/ {print $NF}' | head -1)
stat -f '%i %z' "$f" "$RUNTIME/lib/wine/x86_64-windows/d3d11.dll"
# DXVK d3d11 is about 3165760 bytes; Wine's builtin about 425552. DXVK also writes d3d9.log
```

`prepare_runtime.py` now materialises
`lib/dxvk/x86_64-windows/{d3d9,d3d10,d3d10_1,d3d10core,d3d11}.dll` into the view
(CrossOver's DXVK ships no `dxgi.dll`, so Wine's builtin dxgi stays), and
`launch_nikke.sh` carries the native override by default:

```
WINEDLLOVERRIDES=version=n,b;d3d9,d3d10,d3d10_1,d3d10core,d3d11=n,b
```

> **Warning: writing through a symlink.** The view's `lib/wine/i386-windows` is a
> **symlink back into CrossOver's own install**. Running `rm` plus `cp` on files
> beneath it rewrites CrossOver itself (32-bit d3d dlls were damaged this way and
> then restored from the prefix's builtin copies; `codesign --verify` passes again).
> Check that a view directory is not such a link before replacing anything in it.

### 5.7 Why opening the DXGI path fails: Wine's own mfplat

Retested with **DXVK verified as genuinely loaded** and both MF switches cleared:

- The game **still hangs on the story scene** (log frozen 90+ seconds, one core at
  103% CPU, GStreamer pipelines piling up).
- Unity still reports `WindowsVideoMedia error 0x80004001` with the context
  `Creating DXGIDeviceManager`.
- The patch was **off**, so the `E_NOTIMPL` comes from **Wine's own
  `MFCreateDXGIDeviceManager`**.

**Corrected conclusion.** The blocker is not DXVK's shared handles -- DXVK does
implement `CreateSharedHandle` -- but that **Wine's mfplat cannot supply a DXGI
device manager in this environment at all**. The MF switch pairing is therefore
required regardless of the rendering backend.

**Recommended configuration:** DXVK for performance plus
`NOP_BRIDGE_MF_NO_DXGI=1` and `NOP_BRIDGE_MF_SOFTWARE=1` so video does not hang.
The two coexist: measured, the story scene passes normally at 62-96% CPU, against
103% spinning while hung.

---

## 6. How these conclusions were reached

None of this was inferred by reading code; each claim comes from:

1. **Comparing the installed runtime against CrossOver's originals.** Walk the
   runtime view, use `find -type f` to isolate every non-symlink real file, and
   compare each against the same-named file under
   `/Applications/CrossOver.app/.../CrossOver/`. Identical means "just a copy",
   different means "genuinely customized". This produced the five files in
   section 2 directly.
2. **Scanning import tables in both ASCII and UTF-16.** This step nearly led me
   to a wrong conclusion: searching `UnityPlayer.dll` for `mfplat` as ASCII
   yields **0** hits, which looks like "the game does not use Media
   Foundation". Searching **UTF-16LE** instead finds `mfplat.dll` and
   `mfreadwrite.dll`. Unity loads them by name in UTF-16, so both modules
   **really are on the path** — corroborated by `MFStartup`,
   `MFCreateSourceReader` and `IMFSourceReader` strings in the same binary.
   **Any "this DLL is unused" claim must check both encodings.**
3. **Reverse-looking-up open handles.** `lsof +D <prefix>` finds the files
   processes actually hold, which is far more reliable than matching process
   names with `ps` — Wine writes titles like `-timestamps` that reveal nothing.
4. **Rebuild, compare, and actually boot it.** Regenerate a runtime view with
   `prepare_runtime.py` and confirm its file list is **md5-identical** to the
   hand-installed set. But **hashes alone are not enough**: an earlier version
   of the script produced a view whose hashes all matched yet which could not
   start at all, because one `ntdll.dll` was missing. The final criterion is
   therefore to **boot the new view**:

   ```sh
   NOP_BRIDGE_NTDLL=/tmp/rt-new/lib/wine/x86_64-unix/ntdll.so \
     "$HOME/Applications/NIKKE Wine.app/Contents/MacOS/nikke_wine" \
     "C:\\windows\\system32\\cmd.exe" /c "echo OK"
   ```

---

## 7. Kept, though redundant or unverified

These were **not** removed: deleting them carries more risk than benefit, or
the evidence does not settle the question.

| Item | Status |
|---|---|
| The user-mode `ntdll.so` patch | Covers **the same encoding** as the macOS-side `nop_bridge` (`src/nop_decode.h`). ACE still failed while the bridge was active, so the bridge does not cover the kernel path — but each one's contribution *inside the game process* has not been isolated |
| `crossover-26.1-thread-process-experimental.patch` | Only 28 lines; `ARCHITECTURE.md` notes its implementation is now part of the default build. The file is kept for provenance |
| `ACE-CORE202797` | Still `STOPPED` (`sc start` returns `87 ERROR_INVALID_PARAMETER`). **Does not block the game** |

---

## 8. Reproducing

**`MF_SOFTWARE` has to be included**, or story video hangs (5.3).

For daily use, launch through `scripts/launch_nikke.sh`. It **reproduces the app
bundle's own environment** (`WINELOADER`/`CX_WINELOADER` point at the bundle's
bootstrap) and adds only `NOP_BRIDGE_MF_SOFTWARE=1`. That avoids editing the
app's `Info.plist` -- it is ad-hoc signed, so editing it invalidates the
signature -- and adds no extra layer.

> **Why not `scripts/launch_crossover.py`.** It invokes CrossOver's own `bin/wine`
> wrapper, which is an **extra dependency layer**; the original app deliberately
> bypasses it by using its own bootstrap as the loader. On this machine that path
> brought up only a `wineserver` and never started the launcher, so this entry
> point launches the bootstrap directly instead. For what it is worth, `bin/wine`
> is a Perl script containing **no licence or expiry checks**; both routes depend
> on CrossOver.app being installed either way, because the runtime view's files
> are symlinks into it.

The equivalent graphical entry is `~/Applications/NIKKE Wine (video fix).app`, a
**newly created** wrapper app; the original `NIKKE Wine.app` is untouched.

```sh
# 1. Build the five modules (ntdll.so is forced to x86_64, hashes printed)
python3 scripts/build_wine_modules.py

# 2. Generate the runtime view (the script selects the patched ntdll.so)
python3 scripts/prepare_runtime.py \
    --output local/runtime-modules \
    --modules local/wine-modules/build

# 3. Check: should list exactly these five real files
find local/runtime-modules -type f

# 4. Launch
open "$HOME/Applications/NIKKE Wine.app"
```

`prepare_runtime.py` now **fails loudly** when the built `ntdll.so` is not
x86_64, instead of leaving it to surface later as an inscrutable loader error —
a trap hit earlier in this work.
