#!/usr/bin/env bash
# Fetch and build the upstream MDR library, bound to one commit and nothing
# else. Produces the two shared objects mdrctl loads. Nothing here is modified,
# so there is no fork to keep up with -- only a commit to move.
#
# The commit is written out in full on every line that uses it rather than
# passed through a variable, because anything reading this file statically --
# a reviewer skimming it, the marketplace's security baseline -- cannot resolve
# a variable, and a pin that cannot be verified reads the same as no pin at
# all. scripts/test asserts that all of them, and the PKGBUILD's _mdrcommit,
# say the same thing.
set -euo pipefail

UPSTREAM="https://github.com/mos9527/SonyHeadphonesClient"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/SonyHeadphonesClient"

command -v cmake >/dev/null || { echo "need cmake" >&2; exit 1; }
command -v ninja >/dev/null || { echo "need ninja" >&2; exit 1; }

# init and fetch that one commit, rather than clone: a clone takes the default
# branch first, and a branch can move after somebody reviewed it. GitHub serves
# a reachable SHA directly, so no branch is ever named here.
mkdir -p "$SRC"
[[ -d $SRC/.git ]] || git -C "$SRC" init -q
git -C "$SRC" remote get-url origin >/dev/null 2>&1 \
  || git -C "$SRC" remote add origin "$UPSTREAM"
git -C "$SRC" fetch --depth 1 origin 965c458116d40827494726447de5f07eb50efcb8
git -C "$SRC" checkout -q --detach 965c458116d40827494726447de5f07eb50efcb8

# A compiler is about to run over this directory, so prove what is in it.
head=$(git -C "$SRC" rev-parse HEAD)
[[ $head == 965c458116d40827494726447de5f07eb50efcb8 ]] \
  || { echo "checked out $head, wanted 965c458116d40827494726447de5f07eb50efcb8" >&2; exit 1; }

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
