#!/bin/bash
# sims_session.sh start|cmd <line>...|shot <name>|stop : a long test-mode session driven from outside.
#   start: runs the game (hidden window) with DS_CMDFILE=work/session/cmd.txt; log in work/session/log.txt
#   cmd "click:400,300" "key:13": appends script lines (click, rclick, move, key, type, ...); they run from the next frame
#   shot NAME: requests a screenshot of the next presented frame -> work/session/NAME.png (waits for it)
cd "$(dirname "$0")/.."
S=work/session; mkdir -p $S
G="${SIMS_GAME:-/mnt/de23fa52-e674-44dc-b668-d5ca17db46cf/SteamLibrary/steamapps/common/The Sims Legacy Collection}"
case "$1" in
start)
  : > $S/cmd.txt
  DS_TEST=1 W32_AUDIO_MUTE=${W32_AUDIO_MUTE-1} DS_CMDFILE=$PWD/$S/cmd.txt setsid timeout "${T:-3600}" work/sims/app/SimsLinux --exe work/sims/Sims.exe \
    --game "$G" --data "${DATA:-$PWD/work/data}" > $S/log.txt 2>&1 < /dev/null &
  echo $! > $S/pid; echo "started $(cat $S/pid)";;
cmd) shift; for l in "$@"; do echo "$l" >> $S/cmd.txt; done;;
shot)
  f=$PWD/$S/$2.png; rm -f "$f"; echo "shot:$f" >> $S/cmd.txt
  for i in $(seq 1 100); do [ -s "$f" ] && { echo "$f"; exit 0; }; sleep 0.2; done; echo "no frame"; exit 1;;
stop) kill "$(cat $S/pid)" 2>/dev/null; pkill -f "SimsLinux --exe" ; echo stopped;;
esac
