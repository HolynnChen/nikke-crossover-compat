# Chromium/CEF command-line workaround (ntdll)

Status: **implemented and verified locally** (2026-09-10). Not a general fix for the
underlying Wine limitation — see "Limitations".

## Problem

On this Wine/CrossOver runtime the main NIKKE launcher window (a Chromium/CEF host,
`intl_service\tbs_browser.exe`) stays black unless the CEF process is started with
`--in-process-gpu`. Investigated with minimal, Chromium-free reproducers:

| scenario | API result | screen |
|---|---|---|
| GDI `BitBlt` from the window's owning process | success | correct |
| GDI `BitBlt` into a window owned by **another process** | success | **black** |
| D3D11 swapchain on an own window (same process) | success | correct |
| D3D11 swapchain on a window owned by **another process** | success | **black** |

Root cause (source level, CrossOver 26.1 sources), `dlls/winemac.drv/surface.c`:

```c
BOOL macdrv_CreateWindowSurface(HWND hwnd, BOOL layered, const RECT *rect,
                                struct window_surface **surface)
{
    if (!(data = get_win_data(hwnd))) return TRUE;   /* use default surface */
    ...
}
```

`macdrv_win_data` (which holds the Cocoa window) only exists in the process that
created the window. For any other process `win32u`'s `create_window_surface()` ends up
with a NULL window surface, so the drawing is silently discarded — every API reports
success and nothing appears.

Chromium is built exactly the other way round: the **GPU process** renders and presents
into the **browser process's** window, so a default-configured CEF browser produces a
black window here. `--in-process-gpu` keeps the drawing in the window-owning process and
`--disable-gpu-compositing` avoids the GPU (ANGLE/EGL) compositing path, which fails for
the same reason. Both switches are needed; either one alone still renders black.

## Patch

`patches/crossover-26.1-chromium-flags.patch` — in `dlls/ntdll/loader.c`:

* `append_chromium_workaround_flags()` appends
  `--in-process-gpu --disable-gpu-compositing` to `Peb->ProcessParameters->CommandLine`
  when the process image basename matches an explicit whitelist
  (`tbs_browser.exe`, `INTLWebViewHelper.exe`).
* Called from `loader_init()` right after `init_user_process_params()`, which rebuilds
  the parameter block; the process heap already exists at that point and the entry point
  has not run yet, so `GetCommandLineW()` and the CRT argv both observe the added
  switches.
* Idempotent (`--in-process-gpu` is used as "already applied" marker).

The whitelist is deliberately explicit: `nikke_launcher.exe` and `nikke.exe` must keep
their original command lines, because the launcher/game Sail login handshake depends on
them.

## Build and install

```bash
# 1. build the patched modules (adds ntdll.dll to the existing module set)
python3 scripts/build_wine_modules.py --archive /path/to/crossover-sources-26.1.0.tar.gz \
        --output local/wine-modules

# 2. create the local runtime view (copies the built ntdll.dll, keeps ntdll.so a real file)
python3 scripts/prepare_runtime.py --output local/runtime \
        --modules local/wine-modules/build
```

`prepare_runtime.py` must copy `ntdll.dll` (like the other built modules) **and** keep
`x86_64-unix/ntdll.so` a real file: the PE ntdll is located relative to the *resolved*
unix ntdll path (`realpath`), so a symlinked `ntdll.so` would silently pull the PE ntdll
back out of the CrossOver installation.

## Verification

Unit test (a probe that only prints its own command line, run through the local runtime):

```
as  C:\tbs_browser.exe   ->  "C:\tbs_browser.exe" --in-process-gpu --disable-gpu-compositing
as  C:\other_name.exe    ->  "C:\other_name.exe"                       (untouched)
```

Live test: `intl_service/tbs_browser.exe` restored to the pristine binary
(md5 `933124d56a01f6a7ac4f3742fabe4f3b`, no proxy) with the patched ntdll installed:

* launcher window renders normally (window capture 1 958 049 bytes, identical in size to
  the reference capture of a working render; the all-black failure mode is 29 379 bytes)
* no `--type=gpu-process` process exists (the in-process switch reached Chromium)
* no debug port is opened

## Limitations

* This neutralises the defect **for the whitelisted Chromium hosts only**; it does not
  implement cross-process window surfaces. A real fix is a much larger change
  (`win32u` + `wineserver` + `winemac.drv`, unix-side `.so` modules, which the current
  build flow does not build).
* Other windows that are not CEF windows are unaffected — in particular the launcher's
  "system settings" popup is a native window whose webview host is never created, which
  is a separate defect (it shows black with or without this patch).
* Secondary, unrelated finding: wined3d's D3D11 present-to-HWND renders black even
  in-process (DXVK is fine), and `IDXGIResource::GetSharedHandle` fails on both backends
  (CrossOver's `lib/dxvk` ships no `dxgi.dll`, so DXVK runs against the builtin dxgi).

## Rollback

```bash
R=local/runtime-modules/lib/wine/x86_64-windows
rm -f "$R/ntdll.dll"
ln -s /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-windows/ntdll.dll "$R/ntdll.dll"
```
