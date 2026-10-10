#!/usr/bin/env bash
# macOS, no game files required. SANITIZE=thread runs the same checks under TSan.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/sims-fences.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
CXX=${CXX:-clang++}
SANITIZE=${SANITIZE:-address,undefined}
PIDS=()
for name in spirv_cfg spirv_cross spirv_cross_parsed_ir spirv_glsl spirv_msl spirv_parser; do
    "$CXX" -std=c++17 -O1 -c "$ROOT/recomp/third_party/spirv-cross/$name.cpp" -o "$OUT/$name.o" &
    PIDS+=($!)
done
FAIL=0
for pid in "${PIDS[@]}"; do wait "$pid" || FAIL=1; done
[[ $FAIL == 0 ]] || exit 1
"$CXX" -std=c++17 -O1 -g -fobjc-arc "-fsanitize=$SANITIZE" \
    -I "$ROOT/recomp/third_party/vulkan/include" -I "$ROOT/recomp/third_party/spirv-cross" \
    "$ROOT/recomp/tests/vk_fence_test.mm" "$OUT"/*.o \
    -framework Metal -framework QuartzCore -framework Foundation -o "$OUT/fences"
"$OUT/fences"
