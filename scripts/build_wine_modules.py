#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Build experimental Wine modules from pinned official LGPL sources."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE_URL = "https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz"
SOURCE_SHA256 = "ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872"
PATCHES = (
           "crossover-kernel.patch",
           "crossover-thread-process-experimental.patch",
           "crossover-september-update.patch",
           "crossover-ace-kernel-exports.patch",
           "crossover-ace-extended-exports.patch",
           "crossover-ace-core-driver-stubs.patch",
           "crossover-ntoskrnl-rosetta-nop.patch",
           "crossover-rosetta-multibyte-nop.patch",
           "crossover-mf-software.patch",
           # PE-side ntdll (Chromium/CEF command line). Independent of
           # the unix-side patch above: loader.c vs unix/signal_x86_64.c.
           "crossover-chromium-flags.patch")
MODULES = {"ntoskrnl.exe": "dlls/ntoskrnl.exe", "mfreadwrite.dll": "dlls/mfreadwrite",
           "mfplat.dll": "dlls/mfplat", "lsass.exe": "programs/lsass",
           "ntdll.dll": "dlls/ntdll"}
# ntdll.so is a Unix library rather than a PE module, so it is built
# separately.  Two things matter here:
#   * the host compiler targets the host arch, which on Apple silicon is
#     arm64, but the bootstrap and every runtime this repo drives are
#     x86_64, so the library has to be built for x86_64 explicitly;
#   * --enable-archs=x86_64 makes configure add -DIS_WOW64_BUILD, which
#     describes the WoW64 host side.  We want a native 64-bit ntdll, so
#     that define is left out.
NTDLL_TARGET = "dlls/ntdll/ntdll.so"
NTDLL_CC = "clang -arch x86_64"
NTDLL_CFLAGS = "-O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0"
NTDLL_UNIX_OBJECTS = "dlls/ntdll/unix"

MACHO_MAGICS = (0xFEEDFACF, 0xFEEDFACE)
MACHO_CPU_X86_64 = 0x01000007
MACHO_CPUS = {MACHO_CPU_X86_64: "x86_64", 0x0100000C: "arm64"}


def require_x86_64(path):
    """Refuse a Mach-O artifact that is not x86_64.

    Every process here runs as x86_64 under Rosetta, so an arm64 library simply
    cannot be loaded by it.  Checking at build time keeps that from surfacing
    only when the game refuses to start.
    """
    header = path.read_bytes()[:8]
    if len(header) < 8:
        raise ValueError(f"{path} is too short to be a Mach-O file")
    magic = int.from_bytes(header[0:4], "little")
    if magic not in MACHO_MAGICS:
        raise ValueError(f"{path} is not a little-endian Mach-O file (magic {magic:#x})")
    cpu = int.from_bytes(header[4:8], "little")
    if cpu != MACHO_CPU_X86_64:
        name = MACHO_CPUS.get(cpu, f"cputype {cpu:#x}")
        raise ValueError(f"{path} was built for {name}; this project needs x86_64")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path, help=SOURCE_URL)
    parser.add_argument("--output", type=Path, default=ROOT / "local/wine-modules")
    parser.add_argument("--bison", default="/opt/homebrew/opt/bison/bin/bison")
    parser.add_argument("--with-thread-process", action="store_true",
                        help="deprecated: PsGetThreadProcess is now included by default")
    args = parser.parse_args()
    archive = args.archive.resolve()
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""): digest.update(chunk)
    if digest.hexdigest() != SOURCE_SHA256:
        parser.error("archive does not match the pinned CrossOver 26.3 source hash")
    target = args.output.resolve()
    if target.exists(): parser.error("output already exists; choose a new --output")
    target.mkdir(parents=True)
    source = target / "source"
    source.mkdir()
    with tarfile.open(archive) as bundle:
        for item in bundle:
            if not item.name.startswith("sources/wine/"): continue
            relative = Path(item.name[len("sources/wine/"):])
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("unsafe archive member")
            path = source / relative
            if item.isdir(): path.mkdir(parents=True, exist_ok=True)
            elif item.isfile():
                path.parent.mkdir(parents=True, exist_ok=True)
                with bundle.extractfile(item) as src, path.open("wb") as dest:
                    shutil.copyfileobj(src, dest)
                path.chmod(item.mode & 0o777)
            else: raise ValueError(f"unexpected archive member type: {item.name}")
    for patch in PATCHES:
        subprocess.run(["patch", "-p1", "--batch", "--forward", "-i", str(ROOT / "patches" / patch)],
                       cwd=source, check=True)
    # Build the upstream Wine system-process component against the same headers
    # and ntdll import library as the kernel modules; no host service is installed.
    lsass = source / "programs/lsass"
    lsass.mkdir()
    shutil.copy2(ROOT / "src/lsass.c", lsass / "lsass.c")
    (lsass / "Makefile.in").write_text(
        "MODULE = lsass.exe\nIMPORTS = ntdll\nEXTRADLLFLAGS = -mconsole\nSOURCES = lsass.c\n")
    for name, anchor, addition in (
        ("configure", "wine_fn_config_makefile programs/services enable_services",
         "wine_fn_config_makefile programs/lsass enable_lsass"),
        ("configure.ac", "WINE_CONFIG_MAKEFILE(programs/services)",
         "WINE_CONFIG_MAKEFILE(programs/lsass)"),
    ):
        path = source / name
        content = path.read_text()
        if content.count(anchor) != 1: raise ValueError(f"unexpected {name} layout")
        path.write_text(content.replace(anchor, addition + "\n" + anchor))
    build = target / "build"
    build.mkdir()
    env = os.environ.copy()
    env["BISON"] = args.bison
    env.setdefault("CFLAGS", "-O2")
    env.setdefault("OBJCFLAGS", "-O2")
    with (target / "configure.log").open("w") as log:
        subprocess.run([str(source / "configure"), "--enable-archs=x86_64",
                        "--without-x", "--without-freetype", "--disable-tests"],
                       cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    targets = [f"{directory}/x86_64-windows/{name}" for name, directory in MODULES.items()]
    with (target / "build.log").open("w") as log:
        subprocess.run(["make", "-j8", *targets], cwd=build, env=env,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    # Any ntdll Unix object already present was compiled for the host arch;
    # drop it so the x86_64 rebuild below is not skipped as up to date.
    unix_objects = build / NTDLL_UNIX_OBJECTS
    if unix_objects.is_dir():
        for stale in unix_objects.glob("*.o"): stale.unlink()
    (build / NTDLL_TARGET).unlink(missing_ok=True)
    # CC/CFLAGS have to be make command-line variables, not environment variables:
    # configure bakes them into the generated Makefile, and a Makefile assignment
    # beats the environment.  Passing them in the environment silently did nothing,
    # so the host compiler built this Unix library for the host architecture --
    # arm64 here -- and kept the -DIS_WOW64_BUILD define we do not want.  A
    # command-line variable overrides the Makefile, which is the effect intended.
    with (target / "build-ntdll.log").open("w") as log:
        subprocess.run(["make", "-j8", f"CC={NTDLL_CC}", f"OBJC={NTDLL_CC}",
                        f"CFLAGS={NTDLL_CFLAGS}", NTDLL_TARGET], cwd=build, env=env,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    require_x86_64(build / NTDLL_TARGET)
    # lsass.exe is built as a console application, but this project registers it
    # as the WineLsassCompat service, so Wine allocates a console for it at
    # session start and a conhost.exe window appears -- one that outlives the
    # launcher, because it belongs to the service rather than to the launcher.
    # Flipping the PE subsystem to GUI removes the window and matches how Wine's
    # own daemons are built; the service itself keeps running unchanged.
    lsass = build / "programs/lsass/x86_64-windows/lsass.exe"
    if lsass.is_file():
        data = bytearray(lsass.read_bytes())
        pe = int.from_bytes(data[0x3C:0x40], "little")
        if data[pe:pe + 4] != b"PE\0\0":
            raise ValueError(f"unexpected PE signature in {lsass}")
        subsystem_at = pe + 24 + 68
        if int.from_bytes(data[subsystem_at:subsystem_at + 2], "little") != 2:
            data[subsystem_at:subsystem_at + 2] = (2).to_bytes(2, "little")
            lsass.write_bytes(data)
    for name, directory in MODULES.items():
        result = build / directory / "x86_64-windows" / name
        print(f"{name}: {hashlib.sha256(result.read_bytes()).hexdigest()}")
    ntdll = build / NTDLL_TARGET
    print(f"ntdll.so: {hashlib.sha256(ntdll.read_bytes()).hexdigest()}")
    print(f"Build complete: {build}. No runtime or bottle was modified.")


if __name__ == "__main__": main()
