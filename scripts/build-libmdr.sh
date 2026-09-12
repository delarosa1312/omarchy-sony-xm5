#!/usr/bin/env bash
# Fetch and build the upstream MDR library, bound to one commit and nothing
# else. Produces the two shared objects mdrctl loads. Nothing here is modified,
# so there is no fork to keep up with -- only a commit to move.
set -euo pipefail

UPSTREAM="https://github.com/mos9527/SonyHeadphonesClient"
COMMIT="965c458116d40827494726447de5f07eb50efcb8"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/SonyHeadphonesClient"

# A branch or a tag can move after somebody reviewed it; a full SHA cannot.
# Refuse anything shorter rather than building whatever the default branch
# happens to be today.
[[ $COMMIT =~ ^[0-9a-f]{40}$ ]] \
  || { echo "COMMIT must be a full 40-character commit SHA" >&2; exit 1; }

command -v cmake >/dev/null || { echo "need cmake" >&2; exit 1; }
command -v ninja >/dev/null || { echo "need ninja" >&2; exit 1; }

# init and fetch the commit, rather than clone: a clone takes the default
# branch first, which is exactly the unpinned source this is avoiding. GitHub
# serves a reachable SHA directly, so the branch never has to be named.
mkdir -p "$SRC"
[[ -d $SRC/.git ]] || git -C "$SRC" init -q
git -C "$SRC" remote get-url origin >/dev/null 2>&1 \
  || git -C "$SRC" remote add origin "$UPSTREAM"
git -C "$SRC" fetch --depth 1 origin "$COMMIT"
git -C "$SRC" checkout -q --detach "$COMMIT"

# A build is about to run out of this directory, so prove what is in it.
head=$(git -C "$SRC" rev-parse HEAD)
[[ $head == "$COMMIT" ]] \
  || { echo "checked out $head, wanted $COMMIT" >&2; exit 1; }

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
