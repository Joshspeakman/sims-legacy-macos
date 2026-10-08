#!/bin/bash
# install.sh [--game-dir <The Sims Legacy Collection folder>] [--app-dir DIR] [--data-dir DIR]
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
# Needs an Apple Silicon Mac, the Xcode command line tools (xcode-select --install), python3 and MoltenVK
# (brew install molten-vk): the game draws with Vulkan, and MoltenVK runs Vulkan on Metal. The build checks Sims.exe
# (Steam build 17905164), undoes the Steam wrapper on a copy (recomp/tools/steamstub.py) and recompiles it (a few
# minutes); SIMS_ANY_BUILD=1 accepts a newer Steam build.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GAME=""; APPS="$HOME/Applications"; DATA="$HOME/Games/SimsNative"; STEAMUSER=""
APP_NAME="The Sims Legacy Native"; APP_SHOWN="The Sims"; APP_LOG=SimsNative
while [ $# -gt 0 ]; do
  case "$1" in
    --game-dir) GAME="$2"; shift 2;; --app-dir) APPS="$2"; shift 2;; --data-dir) DATA="$2"; shift 2;;
    --steamcmd) STEAMUSER="$2"; shift 2;;
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
MVK=""
for d in "${SIMS_MOLTENVK:-}" "$(brew --prefix molten-vk 2>/dev/null)/lib/libMoltenVK.dylib" /opt/homebrew/lib/libMoltenVK.dylib /usr/local/lib/libMoltenVK.dylib; do
  [ -n "$d" ] && [ -f "$d" ] && { MVK="$d"; break; }
done
[ -n "$MVK" ] || { echo "MoltenVK is missing: brew install molten-vk (or SIMS_MOLTENVK=<path to libMoltenVK.dylib>)"; exit 1; }

echo "== recompiling $GAME/Sims.exe (a few minutes)"
"$HERE/recomp/build_sims.sh" "$GAME/Sims.exe"
W="$HERE/recomp/work/sims"; [ -x "$W/app/SimsNative" ] || { echo "the build made no app (see the messages above)"; exit 1; }

A="$APPS/$APP_NAME.app"; echo "== installing $A"
mkdir -p "$APPS"; rm -rf "$A"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources" "$A/Contents/Frameworks"
cp "$W/app/SimsNative" "$A/Contents/MacOS/"
cp "$W/Sims.exe" "$A/Contents/Resources/Sims.exe"            # the unwrapped copy the app maps (never leaves this Mac)
cp "$MVK" "$A/Contents/Frameworks/libMoltenVK.dylib"
P="$A/Contents/Resources/launch.plist"; plutil -create xml1 "$P"
plutil -insert game -string "$GAME" "$P"; plutil -insert data -string "$DATA" "$P"; plutil -insert log -string "$APP_LOG" "$P"
Q_GAME=$(printf '%q' "$GAME"); Q_DATA=$(printf '%q' "$DATA")
cat > "$A/Contents/MacOS/launcher" <<LAUNCH
#!/bin/bash
# $APP_NAME from the terminal (generated by install.sh); opening the app runs SimsNative with launch.plist instead
B="\$(cd "\$(dirname "\$0")" && pwd)"
exec "\$B/SimsNative" --exe "\$B/../Resources/Sims.exe" --game "\${SIMS_GAME_DIR:-$Q_GAME}" --data "\${SIMS_NATIVE_DATA:-$Q_DATA}"
LAUNCH
chmod +x "$A/Contents/MacOS/launcher"
cat > "$A/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_SHOWN</string>
  <key>CFBundleIdentifier</key><string>io.github.sims-legacy-macos.native</string>
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
I="$(mktemp -d)"                                              # the icon: the game's own, from Sims.exe
if python3 "$HERE/recomp/tools/extract_icon.py" "$GAME/Sims.exe" "$I/sims.ico" 2>/dev/null && sips -s format png "$I/sims.ico" --out "$I/sims.png" >/dev/null 2>&1; then
  sips -z 512 512 "$I/sims.png" --out "$I/sims512.png" >/dev/null && sips -s format icns "$I/sims512.png" --out "$A/Contents/Resources/icon.icns" >/dev/null 2>&1 || true
fi
rm -rf "$I"
codesign --force --sign - "$A/Contents/Frameworks/libMoltenVK.dylib" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$A" >/dev/null 2>&1 || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$A" 2>/dev/null || true
touch "$A"
echo "== done: $A (data in $DATA)"
