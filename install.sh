#!/bin/bash
# install.sh [--game-dir <The Sims Legacy Collection folder>] [--app-dir DIR] [--data-dir DIR] [--nightly]
# install.sh --steamcmd <Steam user name> [--game-dir DIR]
#
# Builds the natively recompiled The Sims Legacy Collection from your own Steam copy and installs
# "The Sims Legacy Native.app" (no Wine, no Rosetta). The game is Windows-only on Steam, so its files come from:
#   - a folder you copied from a Windows PC, or a CrossOver/Whisky bottle's Steam library (--game-dir, or found in the
#     usual places), or
#   - Steam itself through SteamCMD (--steamcmd <user>): it logs in as you (password, Steam Guard) and downloads the
#     Windows build you own into --game-dir (default ~/Games/The Sims Legacy Collection).
# The game folder is only read. Settings, saves and logs go to the data folder (default ~/Games/SimsNative; the
# neighbourhoods in drive_c/Users/player/Saved Games/Electronic Arts/The Sims 25). With no game option, the folder of
# an app already installed is used again (reinstall or update).
#
# The app opens with a launch window (screen shape, resolution, window or full screen, frame rate, saves, updates); its
# art comes from the game's Steam store page, downloaded here into the data folder's art/. --nightly installs
# "The Sims Legacy Nightly.app", which updates from the nightly branch (the same game folder and data).
#
# Needs an Apple Silicon Mac, the Xcode command line tools (xcode-select --install) and python3. The game draws with
# Vulkan, which the app runs on Metal itself (recomp/host/vk_metal.mm; no MoltenVK). The build checks Sims.exe
# (Steam build 17905164), undoes the Steam wrapper on a copy (recomp/tools/steamstub.py) and recompiles it (a few
# minutes); SIMS_ANY_BUILD=1 accepts a newer Steam build.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GAME=""; APPS="$HOME/Applications"; DATA="$HOME/Games/SimsNative"; STEAMUSER=""
APP_NAME="The Sims Legacy Native"; APP_SHOWN="The Sims"; APP_LOG=SimsNative; U_BRANCH=main; APP_ID=native
while [ $# -gt 0 ]; do
  case "$1" in
    --game-dir) GAME="$2"; shift 2;; --app-dir) APPS="$2"; shift 2;; --data-dir) DATA="$2"; shift 2;;
    --steamcmd) STEAMUSER="$2"; shift 2;;
    --nightly) APP_NAME="The Sims Legacy Nightly"; APP_SHOWN="The Sims Nightly"; U_BRANCH=nightly; APP_ID=nightly; shift;;
    *) echo "unknown option $1"; exit 1;;
  esac
done
installed_game() {     # the game folder an installed app was set up with
  local P="$APPS/$APP_NAME.app/Contents/Resources/launch.plist"
  [ -f "$P" ] && plutil -extract game raw -o - "$P" 2>/dev/null || true
}
found_game() {         # The Sims Legacy Collection in the usual places (a folder with Sims.exe and GameData)
  local d
  for d in "$HOME/Games/The Sims Legacy Collection" \
           "$HOME/Library/Application Support/CrossOver/Bottles"/*/drive_c/"Program Files"*/Steam/steamapps/common/"The Sims Legacy Collection" \
           "$HOME/Library/Containers/com.isaacmarovitz.Whisky/Bottles"/*/drive_c/"Program Files"*/Steam/steamapps/common/"The Sims Legacy Collection" \
           /Volumes/*/SteamLibrary/steamapps/common/"The Sims Legacy Collection" \
           /Volumes/*/"Program Files"*/Steam/steamapps/common/"The Sims Legacy Collection"; do
    [ -f "$d/Sims.exe" ] && [ -d "$d/GameData" ] && { printf '%s\n' "$d"; return 0; }
  done; return 0
}
for tool in clang python3 plutil; do command -v $tool >/dev/null || { echo "$tool is missing: install the Xcode command line tools (xcode-select --install)"; exit 1; }; done
[ "$(uname -m)" = arm64 ] || { echo "the native build is for Apple Silicon Macs"; exit 1; }

if [ -n "$STEAMUSER" ]; then                                  # download the Windows build with SteamCMD
  command -v steamcmd >/dev/null || { echo "steamcmd is missing: see https://developer.valvesoftware.com/wiki/SteamCMD#macOS (or brew install --cask steamcmd)"; exit 1; }
  [ -n "$GAME" ] || GAME="$HOME/Games/The Sims Legacy Collection"
  mkdir -p "$GAME"; echo "== downloading The Sims Legacy Collection (Steam app 3314060, Windows) into $GAME"
  steamcmd +@sSteamCmdForcePlatformType windows +force_install_dir "$GAME" +login "$STEAMUSER" +app_update 3314060 validate +quit
fi
[ -n "$GAME" ] || GAME="$(installed_game)"
[ -n "$GAME" ] || { GAME="$(found_game)"; [ -n "$GAME" ] && echo "== found The Sims Legacy Collection in $GAME"; }
[ -n "$GAME" ] || { echo "usage: install.sh --game-dir <The Sims Legacy Collection folder> (Sims.exe, GameData, ...), or --steamcmd <Steam user>"; exit 1; }
GAME="$(cd "$GAME" && pwd)"
for f in Sims.exe gimex.dll ijl10.dll GameData UIGraphics; do
  [ -e "$GAME/$f" ] || { echo "the game folder has no $f: point --game-dir at a complete installation of The Sims Legacy Collection"; exit 1; }
done
echo "== recompiling $GAME/Sims.exe (a few minutes)"
"$HERE/recomp/build_sims.sh" "$GAME/Sims.exe"
W="$HERE/recomp/work/sims"; [ -x "$W/app/SimsNative" ] || { echo "the build made no app (see the messages above)"; exit 1; }

A="$APPS/$APP_NAME.app"; echo "== installing $A"
mkdir -p "$DATA"
mkdir -p "$APPS"; rm -rf "$A"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cp "$W/app/SimsNative" "$A/Contents/MacOS/"
cp "$W/Sims.exe" "$A/Contents/Resources/Sims.exe"            # the unwrapped copy the app maps (never leaves this Mac)
Q_GAME=$(printf '%q' "$GAME"); Q_DATA=$(printf '%q' "$DATA")
# updates from the launch window: the commit this app was built from and the checkout it was installed from; its
# updater fetches the branch from GitHub into a worktree there (build/stable or build/nightly) and rebuilds the app
U_REPO="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"; U_REPO="${U_REPO%/.git}"
U_BUILT="$(git -C "$HERE" rev-parse HEAD 2>/dev/null || true)"
U_WT=stable; [ "$U_BRANCH" = nightly ] && U_WT=nightly
U_ARGS=""; [ "$U_BRANCH" = nightly ] && U_ARGS="--nightly"
if [ -n "$U_REPO" ] && [ -n "$U_BUILT" ] && git -C "$U_REPO" remote get-url origin >/dev/null 2>&1; then
  cat > "$A/Contents/MacOS/update" <<UPDATE
#!/bin/bash
# $APP_NAME updater (generated by install.sh): "update --check" prints the newest commit of $U_BRANCH on GitHub;
# "update" fetches it into a worktree of the checkout this app was installed from and rebuilds the app from it
set -euo pipefail
REPO=$(printf '%q' "$U_REPO"); BRANCH=$U_BRANCH; W="\$REPO/build/$U_WT"
export GIT_TERMINAL_PROMPT=0                              # never wait for a password prompt
if [ "\${1:-}" = --check ]; then                          # GitHub's newest, unless this app already has it: a build
  R="\$(git -C "\$REPO" ls-remote origin "refs/heads/\$BRANCH" | cut -f1)"   # from a newer local commit is never offered an older one
  if [ -n "\$R" ] && git -C "\$REPO" merge-base --is-ancestor "\$R" $U_BUILT 2>/dev/null; then echo $U_BUILT; else echo "\$R"; fi
  exit 0
fi
echo "== fetching \$BRANCH from GitHub"
git -C "\$REPO" fetch -q origin "\$BRANCH"
git -C "\$REPO" worktree prune
if [ -e "\$W/.git" ]; then git -C "\$W" checkout -q -f --detach "origin/\$BRANCH"
else mkdir -p "\$REPO/build"; git -C "\$REPO" worktree add -q -f --detach "\$W" "origin/\$BRANCH"; fi
echo "== \$BRANCH: \$(git -C "\$W" log -1 --format='%h %s')"
exec "\$W/install.sh" --game-dir $Q_GAME --data-dir $Q_DATA --app-dir $(printf '%q' "$APPS") $U_ARGS
UPDATE
  chmod +x "$A/Contents/MacOS/update"
fi
P="$A/Contents/Resources/launch.plist"; plutil -create xml1 "$P"
plutil -insert game -string "$GAME" "$P"; plutil -insert data -string "$DATA" "$P"; plutil -insert log -string "$APP_LOG" "$P"
plutil -insert branch -string "$U_BRANCH" "$P"; plutil -insert built -string "$U_BUILT" "$P"
cat > "$A/Contents/MacOS/launcher" <<LAUNCH
#!/bin/bash
# $APP_NAME from the terminal (generated by install.sh); opening the app runs SimsNative with launch.plist instead
DEF_GAME=$Q_GAME
DEF_DATA=$Q_DATA
B="\$(cd "\$(dirname "\$0")" && pwd)"
exec "\$B/SimsNative" --exe "\$B/../Resources/Sims.exe" --game "\${SIMS_GAME_DIR:-\$DEF_GAME}" --data "\${SIMS_NATIVE_DATA:-\$DEF_DATA}"
LAUNCH
chmod +x "$A/Contents/MacOS/launcher"
cat > "$A/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_SHOWN</string>
  <key>CFBundleIdentifier</key><string>io.github.sims-legacy-macos.$APP_ID</string>
  <key>CFBundleExecutable</key><string>SimsNative</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.simulation-games</string>
  <key>GCSupportsGameMode</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# the launch window's art (recomp/tools/sims_art.py): the game's logo, background and banner from its Steam store page
if python3 "$HERE/recomp/tools/sims_art.py" "$DATA/art" && [ -n "$(ls "$DATA/art" 2>/dev/null)" ]; then cp -R "$DATA/art" "$A/Contents/Resources/art"; fi
I="$(mktemp -d)"                                              # the icon: the game's own, from Sims.exe
if python3 "$HERE/recomp/tools/extract_icon.py" "$GAME/Sims.exe" "$I/sims.ico" 2>/dev/null && sips -s format png "$I/sims.ico" --out "$I/sims.png" >/dev/null 2>&1; then
  sips -z 512 512 "$I/sims.png" --out "$I/sims512.png" >/dev/null && sips -s format icns "$I/sims512.png" --out "$A/Contents/Resources/icon.icns" >/dev/null 2>&1 || true
fi
rm -rf "$I"
codesign --force --deep --sign - "$A" >/dev/null 2>&1 || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$A" 2>/dev/null || true
touch "$A"
echo "== done: $A (data in $DATA)"
