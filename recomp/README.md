# Recompiler and runtime: The Sims Legacy Collection as native code

Static recompilation of the user's own Steam copy of The Sims Legacy Collection (`Sims.exe`, and `gimex.dll` and
`ijl10.dll` from its folder) into C, compiled for Apple Silicon (Metal) or Linux x86-64 (SDL and the system's Vulkan).
Nothing derived from the game is committed: the scripts regenerate everything under `recomp/work/` (git-ignored) from
the user's files. Installing and playing: the [root README](../README.md). The port's notes and open work:
[docs/SIMS-PORT.md](../docs/SIMS-PORT.md).

This tree was inherited from the author's Dungeon Siege II and Fallout: New Vegas ports. Their scripts and runtime files
(`build.sh`, `build_fnv.sh`, `fnv_imports.c`, the Direct3D 9 code, ...) are still here, but The Sims build doesn't use
them.

## Building by hand

`install.sh` does this. By hand:

```sh
recomp/build_sims.sh "/path/to/The Sims Legacy Collection/Sims.exe"   # -> recomp/work/sims/app/SimsNative (Linux: SimsLinux)
```

`build_sims.sh` checks `Sims.exe` (Steam build 17905164, SHA-256 `b7c8765e…42e3`; `SIMS_ANY_BUILD=1` accepts another),
unwraps Steam's SteamStub 3.1 wrapper from a copy (`tools/steamstub.py`), then analyses (`tools/analyze.py`: 40,022
functions, 96.1% of `.text`), lifts (`tools/lift.py --game sims`), does the same for `gimex.dll` and `ijl10.dll`
(`ijl10.dll` is lifted from a copy relocated to `0x61000000` by `tools/rebase_pe.py`), compiles everything with clang
(`SIMS_BUILD_JOBS=n` parallel jobs) and links it with the runtime (`tools/build_runtime.sh`; on the Mac
`tools/build_mac_sims.sh`). `SIMS_RELINK=1 recomp/build_sims.sh ...` relinks after runtime-only changes.

## What's where

- `tools/`: the recompiler (`analyze.py`, `lift.py`, `sse.py`, `link_tables.py`), `steamstub.py`, `gen_vulkan.py`
  (the Vulkan thunks), and the app helpers (`extract_icon.py`, `sims_art.py`).
- `runtime/rt.c`, `rt.h`, `rt_sse.h`: the execution model below. `runtime/edition.h`: the per-game profile
  (`SIMS_EDITION`).
- `runtime/win32/`: the Windows APIs: loader, memory, heaps, threads, SEH, files, registry, USER32, GDI, DirectSound,
  the game's own imports (`sims_imports.c`), the offline Steam (`steam_api.c`), and Vulkan (`vulkan.c`, and the
  generated `vulkan_gen.c` that converts the 32-bit game's structures).
- `host/sims_mac.m` (the Mac host: window, input, crash reports), `host/vk_metal.mm` (Vulkan on Metal) and
  `host/launcher.m` (the launch window). `host/linux.c`: the Linux host.
- `third_party/`: the Vulkan headers and registry, SPIRV-Cross (the game's shaders to Metal at run time), minimp3,
  MojoShader (linked but unused by The Sims).

## Execution model

- **Memory:** one 4 GB host region; guest address = offset. The image sits at its preferred base `0x400000`, so the
  pointers the game stores keep their 32-bit values.
- **Functions:** one C function per original function. Registers are C locals, written back to a per-thread context
  around calls. The guest stack is real, so calling conventions, `this` pointers and stack-walking code behave as
  before.
- **Flags:** lazy: flag-setting instructions record their operands; consumers compute only the flags they need.
- **x87:** eight doubles with TOP and the control/status words; transcendentals use the host math library.
- **Indirect calls and jumps:** an address to function table; jump tables become `switch` statements; imports go
  through `rt_import`.
- **Exceptions:** SEH4 through the game's own handlers.
- **CPU:** `cpuid` reports an SSE2-only CPU, so the executable's SSE4.1 and AVX paths are never taken. Instructions the
  lifter doesn't support become traps that name their address.
- **Vulkan memory:** the game's mapped memory is shared with the GPU (on the Mac, guest pages as Metal buffers); see
  "Mapped memory" in the port notes.

## Testing

- Test mode: `DS_TEST=1` (a test window, no launch window), `DS_RESOLUTION=WxH`, `DS_SCRIPT` and `DS_CMDFILE`
  (scripted input), `W32_VK_SHOT`/`W32_VK_SHOT_AT` (screenshots), `W32_TRACE=<file>`; the full list is under
  "Testing" in [docs/SIMS-PORT.md](../docs/SIMS-PORT.md).
- `tests/sims_smoke.py`: a first check of a build (a fresh data folder to the neighbourhood).
- `tests/check_vk_fences.sh`: the Metal backend's fence waits under AddressSanitizer/UBSan (`SANITIZE=thread` for
  ThreadSanitizer); no game files needed.
- `tests/check_linux.sh`: the Linux checks run in CI.
- On Linux, `tools/sims_iterate.sh` (relink and one test run) and `tools/sims_session.sh` (a long run driven from
  outside); set `SIMS_GAME` to your game folder.
