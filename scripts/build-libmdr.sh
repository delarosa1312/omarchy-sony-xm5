#!/usr/bin/env bash
# Fetch and build the upstream MDR library, pinned. Produces the two shared
# objects mdrctl loads. Nothing here is modified, so there is no fork to keep up.
set -euo pipefail

UPSTREAM="https://github.com/mos9527/SonyHeadphonesClient"
COMMIT="965c458116d40827494726447de5f07eb50efcb8"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/SonyHeadphonesClient"

command -v cmake >/dev/null || { echo "need cmake" >&2; exit 1; }
command -v ninja >/dev/null || { echo "need ninja" >&2; exit 1; }

if [[ ! -d $SRC/.git ]]; then
  mkdir -p "$ROOT/vendor"
  git clone "$UPSTREAM" "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$COMMIT" 2>/dev/null || true
git -C "$SRC" checkout -q "$COMMIT"

# MDR_BUILD_CLIENT=OFF skips the GLFW/ImGui GUI: we only want the protocol and
# the Bluetooth transport, as shared objects so ctypes can load them.
cmake -S "$SRC" -B "$SRC/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DMDR_BUILD_CLIENT=OFF \
  -DBUILD_SHARED_LIBS=ON
cmake --build "$SRC/build"

echo
echo "built:"
ls -1 "$SRC/build/libmdr/src/libmdr-shared.so" "$SRC/build/libmdr-bt/src/libmdr-bt-shared.so"
