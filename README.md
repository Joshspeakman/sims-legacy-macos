# The Sims Legacy Collection for Apple Silicon Macs

The Sims Legacy Collection (Steam, 2025), statically recompiled from your own copy into native arm64 code. The game
draws with Vulkan, and the app runs that Vulkan directly on Metal: MoltenVK isn't needed. No Wine, no Rosetta, no
emulator.

Nothing from the game is in this repository. `install.sh` reads your Steam copy, recompiles its executable on your
Mac, and builds an app that reads the game's data from your folder. The game folder is only read; nothing is written
into it.

The recompiler and Windows runtime come from the author's earlier ports
([dungeon-siege-macos](https://github.com/Joshspeakman/dungeon-siege-macos), then Dungeon Siege II and Fallout: New
Vegas).

## Status

**Playable, early (2026-10-10).** The code on `main` and `nightly` is currently the same; there is no tagged release yet.

The recompiled game runs the neighbourhood, Select a Family, Create a Family and Create a Sim, lots in live and buy
mode (Sims walking, pie menus, visitors, day turning to night), saving, and music. A 40-minute run at the fastest
speed had no faults (on the Linux build of the same code). On the Mac it runs at the display's resolution and refresh
rate (120 fps on a ProMotion display), widescreen, with a launch window. The starting neighbourhood, the Newbie home by
day and night and a pool in Build/Buy were compared with the original game. See [Known issues](#known-issues).

What's verified and how, and the Mac notes: [docs/SIMS-PORT.md](docs/SIMS-PORT.md).

## What you need

- **A Mac with Apple Silicon** (M1 or later). `install.sh` stops on an Intel Mac.
- **macOS 13 or later** (the app's minimum). Development and testing were done on a recent macOS beta; older
  versions haven't been tried.
- **The Xcode command line tools**: `xcode-select --install`. They provide clang, git and python3.
- **An internet connection while installing**: the build installs two Python packages (Capstone, Unicorn) into
  `recomp/.venv`, and the launch window's artwork is downloaded from the game's Steam store page.
- **Time:** a few minutes to build. Each build redoes the whole recompilation.
- **Your own copy of The Sims Legacy Collection from Steam**, exactly the build below.

### The supported game build

Only the Steam release is supported: **Steam app 3314060, build 17905164**, whose `Sims.exe` is:

```
SHA-256 b7c8765ed2383cbda8c047694d54a21d97895c8dae57dcc87716ca6e78b342e3  Sims.exe
```

The build checks this hash and refuses any other `Sims.exe` (another store, or a newer Steam update) with "not the
Steam Sims.exe this port was made with". `SIMS_ANY_BUILD=1` tries another Steam build anyway: the port finds what it
needs by pattern, so it may work, but only build 17905164 has been tested.

The game folder must be a complete install: `Sims.exe`, `gimex.dll`, `ijl10.dll`, `GameData` and `UIGraphics`, among
the rest.

### Getting the Windows game files onto your Mac

The Legacy Collection is Windows-only on Steam, so the Mac Steam client won't download it. Any of these works:

- **Copy it from a Windows PC:** copy the whole folder `steamapps/common/The Sims Legacy Collection` to the Mac, for
  example to `~/Games/The Sims Legacy Collection`.
- **A CrossOver or Whisky Steam library:** `install.sh` finds the game there by itself (see below).
- **SteamCMD:** `./install.sh --steamcmd <your Steam user name>` downloads the Windows build you own. It needs
  `steamcmd` on your `PATH` (Valve's [SteamCMD for macOS](https://developer.valvesoftware.com/wiki/SteamCMD#macOS), or
  `brew install --cask steamcmd`). SteamCMD asks for your password and Steam Guard code itself; nothing is stored by
  this project. This path hasn't been tested on Apple Silicon, and the macOS SteamCMD may need Rosetta
  (`softwareupdate --install-rosetta`). SteamCMD downloads Steam's current build, so if Steam has moved past build
  17905164, the build refuses it (above).

Without `--game-dir`, `install.sh` uses the game folder of an app it installed before, or looks in:
`~/Games/The Sims Legacy Collection`, CrossOver and Whisky bottles'
`drive_c/Program Files*/Steam/steamapps/common/The Sims Legacy Collection`, and
`/Volumes/*/SteamLibrary/steamapps/common/...` or `/Volumes/*/Program Files*/Steam/steamapps/common/...` on other
drives.

### About the Steam wrapper

Steam ships `Sims.exe` wrapped in SteamStub 3.1 (its code is encrypted). To recompile it, the build removes the wrapper
from a **copy** in the build folder (`recomp/work/sims/`, git-ignored), using `recomp/tools/steamstub.py`. Your game
folder is not modified. This is only for recompiling a copy you bought. The installed app contains that unwrapped copy,
so it is for your own Mac: don't share it.

## Install

```sh
xcode-select --install                     # once, if you don't have the command line tools
git clone https://github.com/Joshspeakman/sims-legacy-macos.git
cd sims-legacy-macos
./install.sh --game-dir "/path/to/The Sims Legacy Collection"
# or: ./install.sh --steamcmd <your Steam user name>
```

This recompiles the game and installs **The Sims Legacy Native** in `~/Applications` (it shows as "The Sims"). Open it
from there or from Launchpad.

**Keep the clone.** The app's Updates button rebuilds from it (see [Updating](#updating)).

### install.sh options

| Option | What it does |
|---|---|
| `--game-dir DIR` | The Sims Legacy Collection folder. Without it: the folder of an app installed before, or the usual places above. With `--steamcmd`, where to download (default `~/Games/The Sims Legacy Collection`). |
| `--steamcmd USER` | Download the Windows build (app 3314060) with SteamCMD, logged in as `USER`, then build. |
| `--app-dir DIR` | Where the app goes (default `~/Applications`). |
| `--data-dir DIR` | Where settings, saves and logs go (default `~/Games/SimsNative`). |
| `--nightly` | Installs **The Sims Legacy Nightly** instead, which follows the `nightly` branch (experimental work) when it updates. It is built from the code you have checked out, so for the nightly code now, run `git checkout nightly` first (or press Updates in the Nightly app). It uses the same game folder and data folder as the stable app. |

Environment variables for the build: `SIMS_ANY_BUILD=1` (accept another Steam build), `SIMS_BUILD_JOBS=n` (parallel
compile jobs; default all cores).

## Where things go

| What | Where |
|---|---|
| The app | `~/Applications/The Sims Legacy Native.app` (or `The Sims Legacy Nightly.app`) |
| Data folder | `~/Games/SimsNative` (set with `--data-dir`) |
| Your neighbourhoods and the game's options | `~/Games/SimsNative/drive_c/Users/player/Saved Games/Electronic Arts/The Sims 25` (`UserData`, `UserData2` ...) |
| Launch window settings | `~/Games/SimsNative/launcher.plist` |
| Log | `~/Games/SimsNative/SimsNative.log` (both apps write to it) |
| Crash reports | `~/Games/SimsNative/CrashReports` |
| Build files | `recomp/work/` and `recomp/.venv` inside the clone; `build/` for the updater's worktrees |

The first start copies the game's template neighbourhoods into the data folder. The Saves button in the launch window
opens them in Finder.

## The launch window

The app opens with a launch window in the game's blue, with its Steam art. Your choices are kept for the next launch.

- **Screen Shape** (top row): Widescreen (the default: the Legacy Collection's wide view, more of the lot) or Original
  4:3 (bars at the sides). This edits the game's own Resolution setting; a change made in the game's Options shows
  here too.
- **Display**
  - **Resolution**: Retina (every pixel: the sharpest, and the default) or Standard (the display's size in points,
    lighter on the GPU).
  - **Interface Size**: 50% to 120% of the game's own size for the screen. Larger gives a larger interface and a closer
    view of the lot; smaller shows more of the lot.
  - **Window**: Full Screen or a Window you can move and resize.
  - **Notch** (only on displays with one): Below the Notch, or Whole Display.
  - **Frame Rate**: the display's (up to 120 on ProMotion), 60 or 30 fps.
- **Graphics**: the game's own Shadows, Lighting, Interface Effects (on/off) and Terrain Detail (High, Medium, Low),
  written into its settings file. They take effect from the second start: the game makes that file the first time.
- **Controls**: Edge Scrolling (Easy, the default: the pointer within 8 points of an edge scrolls; Easiest: 20 points;
  Original: only the outermost pixels, as the game does) and Trackpad (Pinch to Zoom, or Off).
- **Saves**: opens the neighbourhoods folder in Finder.
- **Updates**: shows whether a newer version is on GitHub, and installs it (below).

In the game: zoom with the mouse wheel, a trackpad pinch, or the game's buttons. The window's close button and Cmd-Q
ask the game to quit, so it shows its own "Quit?" dialog.

## Updating

**From the app:** the launch window's **Updates** row asks GitHub for the newest commit of the branch the app follows
(`main` for The Sims Legacy Native, `nightly` for The Sims Legacy Nightly). Press it to update: it fetches that branch
into a worktree inside the clone you installed from (`build/stable` or `build/nightly`), rebuilds the app from your own
game copy with the same game, app and data folders, and reinstalls it. Saves and settings are kept. For this to work,
the clone must still be where you installed it from, and `git` must be able to fetch from GitHub without asking for a
password.

**By hand:** `git pull` in the clone, then `./install.sh` (it reuses the game folder of the installed app).

## Uninstall

1. Delete `~/Applications/The Sims Legacy Native.app` (and `The Sims Legacy Nightly.app`).
2. Delete the clone (it holds the build folder).
3. Delete `~/Games/SimsNative` only if you don't want to keep your neighbourhoods.

Your game folder was never changed.

## Known issues

- The game's own animated cursors show as the system arrow.
- Moving the game's window to another display isn't supported: the screen is chosen at start-up.
- Zoom has only the game's three levels (each is a separate set of pre-drawn sprites); zooming between or beyond them
  isn't possible without engine work.
- The music was checked against the original on the Linux build, not yet on the Mac.
- Not tried yet: building walls and floors, Downtown, Vacation, Studio Town and the other expansion destinations,
  pets, and a whole Sim life (jobs, skills, ageing).
- Compared with the original so far: the starting neighbourhood, the Newbie home by day and night, and a pool in
  Build/Buy. Expansion destinations, larger households, live swimming and night pool lighting haven't been compared.
- The log in the data folder isn't rotated; delete it if it grows large.

## Troubleshooting

| Message or symptom | What to do |
|---|---|
| `not the Steam Sims.exe this port was made with (build 17905164)` | Your copy isn't the supported Steam build, or Steam updated the game. `SIMS_ANY_BUILD=1 ./install.sh ...` tries it anyway. |
| `the game folder has no ...` | Point `--game-dir` at a complete install (the folder holding `Sims.exe`). |
| `steamcmd is missing` | Install SteamCMD (see above), or copy the game folder instead. |
| `clang is missing` / `python3 is missing` | Run `xcode-select --install`. |
| The launch window shows no artwork | The Steam store page couldn't be reached while installing. Run `./install.sh` again when online. |
| Graphics choices don't seem to apply | They take effect from the second start (the game makes its settings file on the first). |
| The neighbourhood is empty | Don't put files into `UserData` before the game's first start: the game copies its template town only into an empty folder. Start again with a fresh `--data-dir`. |
| Updates says "Couldn't check" | GitHub couldn't be reached, or `git` needs a sign-in. Update by hand. |
| The game crashes | Look in `~/Games/SimsNative/CrashReports` and `SimsNative.log`, and open an issue with them. |

## How it works

- `recomp/tools/steamstub.py` undoes the Steam wrapper on a copy of `Sims.exe` in the build folder (the code section
  is AES-encrypted by SteamStub 3.1; the key is in the stub's header).
- `recomp/tools/analyze.py` and `lift.py` turn the executable into one C function per original function (40,022 of
  them, 96.1% of the code), along with the game's own `gimex.dll` and `ijl10.dll`; clang compiles them for arm64.
- `recomp/runtime/win32` implements the Windows APIs the game uses (kernel32, user32, gdi32, advapi32, winmm,
  DirectSound, the C runtime's Vista-era synchronisation, an offline Steam that owns the game, ...).
- The game draws with Vulkan. `recomp/tools/gen_vulkan.py` generates, from the Khronos registry, a thunk for each of
  the 113 Vulkan commands the game uses, converting structures between the 32-bit game's layout and the host's
  (`runtime/win32/vulkan_gen.c`); `runtime/win32/vulkan.c` does instances, devices, surfaces and mapped memory.
- On the Mac, `recomp/host/vk_metal.mm` implements the part of Vulkan the game uses directly on Metal, with
  SPIRV-Cross translating the game's shaders at run time. MoltenVK isn't needed or used (`SIMS_MOLTENVK=<path to
  libMoltenVK.dylib>` loads it instead, only for comparison). `recomp/host/sims_mac.m` is the Mac host and
  `recomp/host/launcher.m` the launch window. On Linux the game uses the system's Vulkan.

More: [recomp/README.md](recomp/README.md).

## Build and run on Linux (development)

Needs clang, python3, SDL2, and the game installed by Steam (app 3314060, build 17905164).

```sh
G="$HOME/.local/share/Steam/steamapps/common/The Sims Legacy Collection"   # or your Steam library
recomp/build_sims.sh "$G/Sims.exe"                  # -> recomp/work/sims/app/SimsLinux (about 4 minutes)
recomp/work/sims/app/SimsLinux --exe recomp/work/sims/Sims.exe --game "$G" --data ~/Games/SimsNative
```

`SIMS_RELINK=1 recomp/build_sims.sh ...` relinks after runtime changes without recompiling the game.

Testing: `DS_TEST=1` (hidden 1024×768 window), `DS_SCRIPT="800:click:336,108"` (clicks at presented frames),
`W32_VK_SHOT=<prefix> W32_VK_SHOT_AT=<frames>` (screenshots of presented frames), `W32_TRACE=<file>` (every Windows
and Vulkan call), `W32_VKLOG=1`, `W32_MSGLOG=1`, `W32_STEAMLOG=1`, `W32_VK_SHADOW=1` (shadowed mappings).
`recomp/tests/sims_smoke.py` is a first check of a build (a fresh data folder to the neighbourhood).

## Documentation

- [docs/SIMS-PORT.md](docs/SIMS-PORT.md): the port's notes: the executable, the Vulkan design, what's verified, the
  Mac (screen, interface size, zoom, edge scrolling, graphics settings, testing), next steps.
- [recomp/README.md](recomp/README.md): the recompiler and runtime.
- [NOTICE.md](NOTICE.md): notices and credits.

## Legal

The Sims is a trademark of Electronic Arts Inc. This project is not affiliated with or endorsed by Electronic Arts or
Valve. You need your own copy of the game. Nothing from the game is distributed here, and the build reads only your
files.

The code in this repository is under the MIT license ([LICENSE](LICENSE)).
