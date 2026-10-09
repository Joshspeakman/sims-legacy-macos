# The Sims Legacy Collection: port notes

Started 2026-10-07 from `fallout-nv-linux` (the Dungeon Siege II recompiler with SSE lifting, the SDL Linux host and
the Metal Mac host). Development is on Linux; the Mac build comes from the same tree.

## The game

| | |
|---|---|
| Steam app | 3314060, build 17905164, `Sims.exe` SHA-256 `b7c8765e…42e3` (`build_sims.sh` checks it) |
| Executable | MSVC 2022, linked 2025-03-28, 32-bit, base `0x400000`, image end `0xb02000`, static TLS, SEH4 |
| Wrapper | SteamStub 3.1 (`.bind`): `.text` AES-256-CBC. `tools/steamstub.py` unwraps a copy (SHA-256 of the result `526add76…083b`, `editions.py` `sims`) |
| Code | 40,022 functions, 96.1% of `.text`; SSE2 throughout, SSE4.1/AVX only behind CPU checks (the runtime reports an SSE2 CPU) |
| DLLs | `gimex.dll` (EA image codecs) and `ijl10.dll` (Intel JPEG, links the system MSVCRT), both loaded by name; both want `0x60000000`, so ijl10 is lifted at `0x61000000` |
| Graphics | Vulkan 1.0 + swapchain, 113 commands resolved through `vkGetInstanceProcAddr`; the game draws its sprites on the CPU, uploads them (`vkCmdCopyBufferToImage`) and composites them (about 100 draws a frame) |
| Other | DirectSound (`dsound.dll` by name), crashpad (switched off), WinINet telemetry (offline), Steamworks flat API + interfaces |

Data: the first run copies `TemplateUserData` to `Saved Games\Electronic Arts\The Sims 25\UserData` (and
`UserData2`–`8`) with std::filesystem.

## Where things are

- `recomp/build_sims.sh`: verify, unwrap, analyse, lift (exe and DLLs), compile, link. `SIMS_RELINK=1` relinks only.
- `recomp/tools/sims_iterate.sh`: relink and one test-mode run (`DATA=`, `T=`, `NOLINK=1`, `SIMS_GAME=`), log in
  `recomp/work/run.log`. Use a fresh `DATA` folder after a run that crashed during the first-run copy.
- `recomp/tools/steamstub.py`: SteamStub 3.1 x86 unwrapping (header at entry − 0xF0, XOR-chained; key, IV and
  "stolen" first ciphertext block in it). `cryptography` if installed, else `openssl enc`.
- `recomp/tools/lift.py --game sims`: no DS2 hooks; the override at `0x467020` (crash reporting); SEH4 support
  (`_except_handler4` at `0x7af450`, `__SEH_prolog4` `0x7a94e0`, `_GS` `0x944940`).
- `recomp/runtime/edition.h` `SIMS_EDITION`; `runtime/win32/sims_imports.c` (Vista synchronisation, wide APIs,
  filesystem, monitors, menus, WinINet, timers, APCs, ...), `steam_api.c`, `msvcrt.c`.
- Vulkan: `tools/gen_vulkan.py` → `runtime/win32/vulkan_gen.{c,h}` (regenerate after editing the generator or
  `vulkan_commands.txt`: `python3 recomp/tools/gen_vulkan.py recomp/third_party/vulkan/registry/vk.xml
  recomp/runtime/win32/vulkan_commands.txt recomp/runtime/win32/vulkan_gen.c`); `runtime/win32/vulkan.c`;
  `runtime/win32/vulkan_rt.h`; headers and registry in `third_party/vulkan` (vulkan-sdk-1.4.341.0).
- `recomp/host/sims_mac.m`, `recomp/tools/build_mac_sims.sh`, `install.sh`: the Mac app (see below).
- `recomp/tools/sims_session.sh`: a long test-mode run driven from outside (`start`, `cmd "click:x,y"`, `shot NAME`,
  `stop`; `SESSION=`, `DATA=`, `SIMS_BUILD=`); `recomp/tests/sims_smoke.py`: a first check of a build.
- `recomp/host/linux.c` under `SIMS_EDITION`: Vulkan window, `w32_host_vk_*` hooks (loader, surface extensions,
  surface, presented), absolute cursor, an event loop instead of the DSR command ring.

## Design notes

**Vulkan across the 32/64-bit boundary.** Guest structures are MSVC x86: pointers, `size_t` and dispatchable
handles 4 bytes; `VkDeviceSize` and non-dispatchable handles 8 bytes, 8-aligned (`/Zp8`); stdcall arguments are
dwords (a 64-bit argument is two, unpadded). Structures without pointers, `size_t` or dispatchable handles have the
same layout on both sides and are used in place in guest memory (41 of 104); the rest are converted into a per-call
arena. Dispatchable handles are 16-byte guest allocations mapped to host pointers. Strings, scalar arrays and blittable
arrays are passed as pointers into guest memory. Unknown `pNext` structures are logged once and left out.

**Mapped memory.** Each allocation is mapped whole the first time and stays mapped; the game never flushes (it
relies on coherent memory), so the guest must see the device memory itself or a copy kept in step. Three ways, the
first the device offers (`W32_VK_MAP=placed|import|shadow` chooses):
- *placed* (`VK_EXT_map_memory_placed`, NVIDIA on Linux): the driver maps the allocation at a guest address reserved
  with `vm_alloc`; unmapping keeps the range reserved (`VK_MEMORY_UNMAP_RESERVE_BIT_EXT`) and gives it back.
- *import* (`VK_EXT_external_memory_host`, MoltenVK): host-visible allocations are made in guest pages and imported;
  a memory type that can't import is swapped for a host-visible coherent one that can (NVIDIA's resizable-BAR type).
  Safe on Metal because the game only binds buffers to host-visible memory: in a traced run its 4 imported
  allocations (32, 32, 64, 128 MB) back buffers only, and its images live in separate device-local memory fed by
  `vkCmdCopyBufferToImage` (Metal can't put an optimally tiled texture in an imported buffer).
- *shadow*: the guest gets a copy, written to the device before every submission and at flushes, read back at
  invalidations and (host-cached memory) after waits. The game's two persistent 32 MB buffers make this 64 MB per
  submission, about three a frame: a fallback only.

**Instance and device.** `vkCreateInstance` swaps `VK_KHR_win32_surface` for the host's surface extensions (SDL on
Linux), adds portability enumeration where present (MoltenVK), raises the API version to 1.1 and drops unavailable
extensions and layers. `vkCreateDevice` drops unavailable extensions and features (logged) and adds
`VK_KHR_map_memory2` + `VK_EXT_map_memory_placed` when available, and `VK_KHR_portability_subset` on MoltenVK.

## Verified on Linux (2026-10-07, RTX 3080 Ti, NVIDIA 615)

- Start-up through Steam, CPU detection, locale, window, Vulkan device and swapchain (1024×768 B8G8R8A8_UNORM, FIFO).
- First run: the template user data copies completely; the neighbourhood draws with all its houses; lot tooltips.
- Select a Family, Create a Family and Create a Sim (typing names, the 3D Sim turning, outfits and heads changing).
- Lots: empty and furnished ones open; the game's notices; save from the options panel (the house file is written);
  back to the neighbourhood; moving a family into a lot (Purchase House).
- Live mode: Sims walking and running, pie menus (Go Here), reading the paper, visitors with dogs, time passing,
  day turning to night; buy mode (catalogue, a chair bought and placed for §80); build mode's tools.
- Quitting: the window's close (WM_CLOSE, what Cmd-Q sends on the Mac) shows the game's "Quit?" dialog; OK ends the
  game with exit 0.
- Sound: music through DirectSound matches an independent decode of the same MP3 (correlation 0.97–0.99, no drift).
- A 40-minute soak at the fastest speed with a family of four: no faults, 139,323 frames presented (about 58 a
  second in the hidden test window), the game thread using about half a core, 500 MB resident.
- All three mapped-memory modes render: placed (default here), imported (`W32_VK_MAP=import`, MoltenVK's), shadowed.
- What the game needs from Vulkan: `VK_KHR_swapchain`, no optional features, formats D32_SFLOAT, B8G8R8A8_UNORM,
  R8_UNORM (all on Apple GPUs; D24S8 would be swapped by `vk_fix_format`).
- `recomp/tests/sims_smoke.py` passes (fresh data folder → neighbourhood in 80 s).

## The Mac

`recomp/host/sims_mac.m` (AppKit window, CAMetalLayer, absolute mouse, keyboard, crash reports, `launch.plist`, test
scripts), `recomp/host/vk_metal.mm` (the Vulkan the game uses, on Metal: SPIRV-Cross translates its shaders at run
time; MoltenVK only with `SIMS_MOLTENVK=<libMoltenVK.dylib>`, for comparison), `recomp/host/launcher.m` (the launch
window), `recomp/tools/build_mac_sims.sh` and `install.sh` (`--nightly` for the Nightly app).

**Screen.** The Legacy Collection keeps its screen as a label, Options > Graphics > Resolution ("1920x1200 (14:9)",
"1024x768 (4:3)"), saved as the last string of the `Optn` chunk of `UserData/Options.iff` and read at start-up. The
label must match an entry of the game's own list exactly (else it takes the whole screen): the screen itself,
"WxH (q:9)" with q = 9W/H rounded ("4:3" when q is 12), and a 4:3 entry whose width is (8H+3)/6 made even (0x6efd8b,
0x6effcf; checked: 1602x1202 gives bars, 1603x1202 fills). 4:3 draws a 4:3 picture with bars, any other a full-width
one. A fresh data folder, and an `Options.iff` older than the Legacy Collection's display settings (version 4: no
strings), get the default "1024x768 (4:3)": lift.py `find_default_resolution` hooks the five pushes of that literal
(0x401264, 0x431f14, 0x43251c, 0x4325e7, 0x4335e0) and hooks.c gives the game `SIMS_GAME_RES` instead. The launch window
edits a saved label only when the shape differs (never creating the file: an empty `UserData` is where the game copies
its template town, so a file put there first leaves the neighbourhood empty). The game pads `Optn` to an even size and
may write `rsmp` before the filler chunk; the header's pointer to `rsmp` (offset 60) moves with it.

**Interface size and zoom.** The game draws at its screen's size but lays out its interface and lot at screen / dpi,
dpi an integer from its `-dpi:<n>` switch (one of 26 allowed: `0xa51ef8`; also `maxaspect`, `monitor`, `w`), by
default and at most height / 600 (0x6f2b77). Interface and lot scale together; `sims_screen()` (sims_mac.m, also used
by the launch window for the label) turns `SIMS_UI` (percent of the game's own size) into a screen of
(layout height x k) with `-dpi:k`, scaled to the display by the layer. The three zoom levels are separate sprite sets
drawn at native size (crisp at the closest), so zoom between or beyond them would need the engine to scale sprites and
picking: not done. The game zooms with the mouse wheel (a notch away from you zooms in); a trackpad pinch sends the
same notches (`SIMS_PINCH=0` turns it off). Frame structure (`VKM_TRACE_ON=<file>`): the lot into a full-size target,
a 220x183 target, a composite of those and the interface, then the screen.

**Edge scrolling.** The game scrolls with the cursor in its outermost 3 pixels (measured zoomed in: x >= 1021 of 1024;
with the whole lot on screen it doesn't scroll at all). Within `SIMS_EDGE` points of an edge (8 by default, 0 = the
game's own) the host puts the cursor on the edge.

**Graphics settings** (single bytes of `Optn` version 8, found by changing each in the game and diffing): Shadows +92,
Lighting +93, Terrain Detail +94 (0 Low, 1 Medium, 2 High), Interface Effects +103. The launch window reads them (a
change in the game wins) and writes them in place; before the game has written a version-8 file there is nothing to edit.

**Launch window settings** (passed to the game process as environment): `SIMS_RESOLUTION` = retina (the display's
pixels, default) | display (its points) | WxH; `SIMS_UI`; `SIMS_WINDOWED=1`; `SIMS_NOTCH=below`; `SIMS_FPS=<n>` (a cap
in `vkm_QueuePresentKHR`; otherwise the display's rate); `SIMS_GAME_RES` (the label above); `SIMS_EDGE`; `SIMS_PINCH`.
Measured in test mode, steady state: 117 fps uncapped (120 Hz display), 60 / 29 with the caps, 123 fps at 3456x2234.

**Testing.** `DS_TEST=1` (1024x768 test window; `DS_RESOLUTION=WxH` for others), `DS_CMDFILE` lines `move`, `click`,
`rclick`, `key`, `type`, `wheel`, `close`, `shot`; `VKM_LOG=1` (Metal backend: render targets and unknown commands);
`W32_REGLOG=1` (registry misses and writes); `DS_LAUNCHER_SHOT=<png>` (the launch window as an image;
`DS_LAUNCHER_OPEN=display`, `DS_LAUNCHER_PICK=4:3|wide` or `Row Title=value,...`, `DS_LAUNCHER_APPLY=1` to do what
Play does); `DS_ARGS` (extra command-line switches).

## Not done / next steps

1. The Mac: compare a full session with the reference host's capture (36 screenshots, after the launch-window work).
2. The game's own animated cursors (`LoadCursorFromFileA` of `.ani` files) show as the system arrow.
3. Drag-and-drop of the game's window between displays (the screen is chosen at start-up).
4. **Remaining imports** (`python3 recomp/tools/import_gap.py recomp/work/sims/Sims.exe`): 58, none reached in
   what's been played (threadpool timers/waits, named pipes, MSVFW32 video codecs, OLEAUT32 variants, font
   enumeration). Each stops with its name if reached.
5. **Lifter gaps** (stop with their address if reached): SSSE3/SSE4.1 and AVX in CPU-dispatched paths (the runtime
   reports an SSE2 CPU, so they aren't taken), `enter` with nesting, segment registers in junk decodes.
6. Not yet tried: build mode walls and floors, Downtown / Vacation / Studio Town and the other expansion
   destinations, pets, a whole Sim life (jobs, skills, ageing via the expansions).
7. The marked Newbie house's roof (700,338 in the test window) doesn't open its lot; other lots do.

## Ground rules

Own copy only: the build reads the player's Steam files and unwraps the Steam DRM locally, in the build folder; Josh
confirmed (2026-10-07) that the guides' "no DRM removal" means no building around copies people don't own. Nothing
derived from the game is committed (`recomp/work/` is ignored; stage explicit paths). No Wine or emulation at run time.
