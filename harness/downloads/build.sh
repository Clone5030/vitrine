#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
mkdir -p "$HERE/build"
xcrun --sdk macosx clang -fobjc-arc -O0 -g -Wno-unused-parameter \
    -I"$HERE/include" -I"$ROOT/extension/Downloads/src" \
    "$HERE/main.m" "$ROOT/extension/Downloads/src/WireProto.m" \
    "$ROOT/tweak/Sources/Shared/AdBlock/Premium.m" "$ROOT/tweak/Sources/Shared/AdBlock/Protobuf.m" \
    -framework Foundation -o "$HERE/build/downloadstest"
"$HERE/build/downloadstest"
xcrun --sdk macosx clang -fobjc-arc -O0 -g -Wno-unused-parameter \
    -I"$HERE/include" -I"$ROOT/tweak/Sources" \
    "$HERE/bridge_test.m" "$ROOT/tweak/Sources/Shared/Downloads/DownloadsBridge.m" \
    -framework Foundation -o "$HERE/build/bridgetest"
"$HERE/build/bridgetest"
