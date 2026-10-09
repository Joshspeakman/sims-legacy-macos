# The Sims Legacy Collection, native

The Sims Legacy Collection (Steam, 2025), statically recompiled from your own copy into native code: the goal is an
Apple Silicon Mac app, as [dungeon-siege-macos](https://github.com/Joshspeakman/dungeon-siege-macos),
dungeon-siege-2-macos, diablo-2-macos and fallout-nv-macos do for their games. No Wine, no Rosetta, no emulator.
Nothing from the game is in this repository: the build regenerates everything locally from your Steam files, and the
game folder is only read.

**State: plays on Linux and runs on the Mac (2026-10-08).** The recompiled `Sims.exe` runs the neighbourhood, Create
a Sim, lots in live and buy mode (Sims walking, pie menus, day and night), saving, and music; a 40-minute run at full
speed had no faults on Linux. On the Mac the game's Vulkan runs on Metal directly (`recomp/host/vk_metal.mm`, no
MoltenVK), at the display's resolution and refresh rate (120 fps on a ProMotion display), widescreen, with a launch
window. Details, what's verified and the Mac notes: [docs/SIMS-PORT.md](docs/SIMS-PORT.md).

## Install (Mac)

```sh
./install.sh --game-dir "/path/to/The Sims Legacy Collection"   # a copy of the Steam (Windows) install
./install.sh --steamcmd <your Steam user name>                  # or let SteamCMD download the Windows build you own
```

## How it works

- `recomp/tools/steamstub.py` undoes the Steam wrapper on a copy of the player's own `Sims.exe` in the build folder
  (the code section is AES-encrypted by SteamStub 3.1; the key is in the stub's header).
- `recomp/tools/analyze.py` and `lift.py` turn the executable into one C function per original function (40,022 of
  them, 96.1% of the code), along with the game's own `gimex.dll` and `ijl10.dll`; clang compiles them.
- `recomp/runtime/win32` implements the Windows APIs the game uses (kernel32, user32, gdi32, advapi32, winmm, the
  C runtime's Vista-era synchronisation, an offline Steam that owns the game, ...).
- The game draws with Vulkan. `recomp/tools/gen_vulkan.py` generates, from the Khronos registry, a thunk for each of
  the 113 Vulkan commands the game uses, converting structures between the 32-bit game's layout and the host's
  (`runtime/win32/vulkan_gen.c`); `runtime/win32/vulkan.c` does instances, devices, surfaces and mapped memory (placed
  inside the game's 4 GB with `VK_EXT_map_memory_placed`, shadowed where the driver lacks it). On Linux it runs on the
  system's Vulkan; on the Mac a subset of Vulkan on Metal (`recomp/host/vk_metal.mm`).

## Build and run (Linux, for development)

Needs clang, python3, SDL2, and the game installed by Steam (app 3314060, build 17905164).

```sh
G="$HOME/.local/share/Steam/steamapps/common/The Sims Legacy Collection"   # or your Steam library
recomp/build_sims.sh "$G/Sims.exe"                  # -> recomp/work/sims/app/SimsLinux (about 4 minutes)
recomp/work/sims/app/SimsLinux --exe recomp/work/sims/Sims.exe --game "$G" --data ~/Games/SimsNative
```

`SIMS_RELINK=1 recomp/build_sims.sh ...` relinks after runtime changes without recompiling the game.

Testing: `DS_TEST=1` (hidden 1024×768 window), `DS_SCRIPT="800:click:336,108"` (clicks at presented frames),
`W32_VK_SHOT=<prefix> W32_VK_SHOT_AT=<frames>` (screenshots of presented frames), `W32_TRACE=<file>` (every Windows
and Vulkan call), `W32_VKLOG=1`, `W32_MSGLOG=1`, `W32_STEAMLOG=1`, `W32_VK_SHADOW=1` (shadowed mappings, as on the
Mac).

Notices and credits: [NOTICE.md](NOTICE.md).
