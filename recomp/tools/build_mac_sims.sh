#!/usr/bin/env bash
# build_mac_sims.sh <recomp output directory>: the Win32 runtime (with Vulkan for MoltenVK) and the macOS host
# (host/sims_mac.m), linked with the lifted game objects into <out>/app/SimsNative. Called by build_runtime.sh on macOS
# when the output folder holds The Sims (build_sims.sh). Needs the Xcode command line tools; MoltenVK is loaded at run
# time (brew install molten-vk; install.sh copies it into the app).
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); ROOT=$(cd "$HERE/.." && pwd)
OUT=$(cd "${1:?usage: build_mac_sims.sh <recomp output directory>}" && pwd)
CC=${CC:-clang}
FLAGS=(); [[ -f "$OUT/compiler-flags.txt" ]] && read -ra FLAGS < "$OUT/compiler-flags.txt"
mkdir -p "$OUT/obj/rt/mojo" "$OUT/obj/host" "$OUT/app"; PIDS=()
rm -f "$OUT"/obj/rt/*.o "$OUT"/obj/rt/mojo/*.o                     # no stale runtime objects if one fails
python3 "$HERE/tools/gen_imptab.py" "$OUT/imptab.c" "$HERE"/runtime/win32/*.c
# MojoShader: only so d3d9_shader.c links (The Sims draws with Vulkan; the Direct3D 9 path is Fallout NV's)
MOJO=(-DSUPPORT_PROFILE_D3D=0 -DSUPPORT_PROFILE_BYTECODE=0 -DSUPPORT_PROFILE_HLSL=0 -DSUPPORT_PROFILE_ARB1=0 -DSUPPORT_PROFILE_ARB1_NV=0
      -DSUPPORT_PROFILE_SPIRV=0 -DSUPPORT_PROFILE_GLSPIRV=0 -DSUPPORT_PROFILE_GLSLES=0 -DSUPPORT_PROFILE_GLSLES3=0 -DSUPPORT_PROFILE_METAL=0
      -DMOJOSHADER_FLIP_RENDERTARGET -DMOJOSHADER_DEPTH_CLIPPING -I "$HERE/third_party/mojoshader")
for f in "$HERE"/third_party/mojoshader/mojoshader.c "$HERE"/third_party/mojoshader/mojoshader_common.c "$HERE"/third_party/mojoshader/profiles/*.c; do
  "$CC" ${FLAGS[@]+"${FLAGS[@]}"} -c -O2 -w "${MOJO[@]}" -o "$OUT/obj/rt/mojo/$(basename "$f" .c).o" "$f" & PIDS+=($!)
done
for f in "$HERE/runtime/rt.c" "$HERE"/runtime/win32/*.c "$OUT/imptab.c"; do
  OPT=-O1; [[ $(basename "$f") == native.c ]] && OPT=-O3
  "$CC" ${FLAGS[@]+"${FLAGS[@]}"} -DSIMS_EDITION -c "$OPT" -g -ffp-contract=off -fno-strict-aliasing -Wall -Wno-unused-function \
    -I "$HERE/runtime" -I "$HERE/runtime/win32" -I "$HERE/third_party/mojoshader" -I "$HERE/third_party/minimp3" \
    -I "$HERE/third_party/vulkan/include" -o "$OUT/obj/rt/$(basename "$f" .c).o" "$f" & PIDS+=($!)
done
FAIL=0; for p in "${PIDS[@]}"; do wait "$p" || FAIL=1; done        # (bash 3.2: a bare wait hides failures)
[[ $FAIL == 0 ]] || { echo "build_mac_sims.sh: a runtime file failed to compile (above)"; exit 1; }
BUILD="$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo unknown)"
"$CC" -c -O2 -fobjc-arc -Wall -Wno-unused-function -DSIMS_EDITION -DDS_BUILD="\"$BUILD\"" -I "$HERE/runtime" \
  -I "$HERE/third_party/vulkan/include" -o "$OUT/obj/host/sims_mac.o" "$HERE/host/sims_mac.m"
"$CC" -o "$OUT/app/SimsNative" "$OUT"/obj/*.o "$OUT"/obj/rt/*.o "$OUT"/obj/rt/mojo/*.o "$OUT/obj/host/sims_mac.o" \
  -framework AppKit -framework Metal -framework QuartzCore -framework CoreText -framework CoreGraphics -framework CoreFoundation \
  -framework AudioToolbox -lz
echo "$OUT/app/SimsNative"
