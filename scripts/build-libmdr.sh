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

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/SonyHeadphonesClient"

command -v cmake >/dev/null || { echo "need cmake" >&2; exit 1; }
command -v ninja >/dev/null || { echo "need ninja" >&2; exit 1; }

# The URL and the commit are both written out, in full, on the line that
# fetches them. Earlier versions pinned the commit but reached it through a
# remote named "origin" whose URL came from a variable -- so the commit was
# fixed and the *source* was not, at least to anything reading this file
# without running it. "Which repository" deserves the same treatment as
# "which commit"; git fetches a URL directly, so no remote is needed at all.
# vendor/ is a build artifact directory, disposable and gitignored, so the only
# thing that matters is that it ends up holding exactly this commit. An
# interrupted earlier run leaves untracked files that make checkout refuse;
# rather than abort on somebody's half-finished build, take it from the top.
fetch_upstream() {
  mkdir -p "$SRC"
  [[ -d $SRC/.git ]] || git -C "$SRC" init -q
  git -C "$SRC" fetch --depth 1 https://github.com/mos9527/SonyHeadphonesClient 965c458116d40827494726447de5f07eb50efcb8
  git -C "$SRC" checkout --detach 965c458116d40827494726447de5f07eb50efcb8
}
if ! fetch_upstream 2>/dev/null; then
  echo "== clearing a half-finished checkout and refetching =="
  rm -rf "$SRC"
  fetch_upstream
fi

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
