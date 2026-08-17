# Building mopper on Linux

mopper generates Havok MOPP collision trees, which NIF tools need for
`bhkMoppBvTreeShape`. This fork adds a CMake build and two scripts so it can be
built from Linux against a Havok SDK you already have.

## Why this needs MSVC even on Linux

The Havok SDK is distributed only as **MSVC-compiled 32-bit static libraries**
(`Lib/win32_net_9-0/...` for Havok 2010.2, which is Visual Studio 2008).

MinGW cannot link them. MSVC and MinGW use different C++ ABIs and different name
mangling, so the linker cannot resolve a single C++ symbol out of those archives.
No compiler flag fixes this — it is not a configuration problem.

The way round it is to run a genuine MSVC toolchain under Wine, which is what
[msvc-wine](https://github.com/mstorsjo/msvc-wine) sets up. Only **64-bit Wine** is
needed to build, because the compiler is an x64 host binary that cross-targets x86.

## Quick start

```sh
./scripts/install-deps.sh
./scripts/build.sh /path/to/havok_2010_2_0
```

The result is `build/mopper.exe`, a 32-bit Windows executable.

## What install-deps.sh does

1. Installs system packages: `wine64 python3 msitools ca-certificates winbind cmake ninja-build git curl`.
   msvc-wine needs msitools ≥ 0.98 and libgcab ≥ 1.2 to unpack Microsoft's
   installer payloads, which means Ubuntu 19.04 or newer.
2. Clones msvc-wine and runs `vsdownload.py` to fetch the MSVC compiler and Windows
   SDK from Microsoft's package feed (a few GB — accepting their licence is on you),
   then `install.sh` to create the Wine wrapper scripts.
3. Initialises the Wine prefix so the first build does not race `wineboot`.

Override the install locations with `MSVC_DIR` and `MSVC_WINE_DIR`. If your distro
is not apt/dnf/pacman, install the packages yourself and re-run with
`SKIP_PACKAGES=1`.

## Supported Havok versions

Upstream mopper targets **Havok 2012.1**. This fork also builds against **2010.2**,
which is what ck-cmd vendors. Two differences are handled automatically:

| Difference | Handling |
| --- | --- |
| `hkpCompressedMeshShapeBuilder.h` sits under `Deprecated/CompressedMesh/` in 2012 but `Compound/Collection/CompressedMesh/` in 2010 | `__has_include` picks whichever exists |
| `hkcdCollide` and `hkcdInternal` only exist from Havok 2011 on, where that code was split out of `hkBase`/`hkInternal` | CMake links only the libraries the SDK actually ships, and `MOPPER_NO_LIB_PRAGMAS` suppresses the hard-coded `#pragma comment(lib, ...)` list |

Point at a different library flavour with `HAVOK_LIB_SUBDIR`, for example:

```sh
HAVOK_LIB_SUBDIR=win32_net_9-0/debug_multithreaded ./scripts/build.sh /path/to/havok
```

## What the build has to work around

All four of these are handled automatically; they are recorded because each one
fails with an error that does not obviously point at its cause.

| Symptom | Cause | Fix |
| --- | --- | --- |
| `fatal error C1902: Program database manager mismatch` | `/Zi` writes debug info through `mspdbsrv.exe`, a background service Wine cannot run | `CMAKE_MSVC_DEBUG_INFORMATION_FORMAT=Embedded`, i.e. `/Z7`, which puts debug info in the object files. Must be set before `project()` |
| `MT: command ... failed (exit code 0x1)` | CMake embeds a side-by-side manifest with `mt.exe`, which fails under Wine | `/MANIFEST:NO`. A console tool has no use for a manifest |
| `error C2653: 'hkMallocAllocator' is not a class or namespace name` | The header arrives transitively in Havok 2012 but not 2010 | Include `Common/Base/Memory/Allocator/Malloc/hkMallocAllocator.h` explicitly, guarded by `__has_include` |
| `unresolved external symbol _printf`, `__snprintf`, `__vsnprintf`, `_vsprintf`, `___iob_func` | Havok's objects are Visual Studio 2008. VS2015 reorganised the C runtime into the Universal CRT, inlining most stdio functions and dropping others | Link `legacy_stdio_definitions.lib`, plus a hand-written `__iob_func` in `mopper/crt_compat.cpp`. The array behind it must **not** be called `_iob`, or it collides with `libucrt.lib(_file.obj)` |

## Static runtime

The build forces `/MT` and passes `/NODEFAULTLIB:MSVCRT /NODEFAULTLIB:MSVCRTD`,
mirroring ck-cmd, which is known to build this SDK with a modern MSVC. The Havok
libraries are built against the static runtime; mixing in the dynamic one produces
duplicate-symbol and unresolved-external errors.

If you link a `*_dll` flavour from `Lib/` instead, you will need to match it by
switching the runtime to `MultiThreadedDLL` in `CMakeLists.txt`.

## Running the result

Building needs only 64-bit Wine, but *running* a 32-bit Windows binary needs 32-bit
support. On Debian/Ubuntu:

```sh
sudo dpkg --add-architecture i386
sudo apt-get update
sudo apt-get install wine32
```

Then:

```sh
wine build/mopper.exe --help
```

`build.sh` attempts this as a smoke test and tells you if it could not.

## Licence

mopper is BSD licensed (see `LICENSE.TXT`). It **uses Havok**, and the Havok SDK is
not redistributable — its licence forbids shipping it "as part of a commercial or
non-commercial middleware, engine, or tool offering". So neither the SDK nor a
binary built from it belongs in this repository. Build it yourself from an SDK you
are licensed to use.
