#!/usr/bin/env bash
# Push shell-plugin/ to the widget's own repository.
#
# The marketplace clones a repo and reads manifest.json at its root, so the
# widget cannot live in a subdirectory of this one. `git subtree split` rebuilds
# that repo's history from the plugin's commits here, so there is one place to
# edit and no copy to keep level by hand.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE="${1:-https://github.com/delarosa1312/omarchy-sony-xm5.git}"
cd "$ROOT"

[ -z "$(git status --porcelain)" ] || { echo "commit your changes first" >&2; exit 1; }

echo "== checking the plugin before it goes out =="
"$ROOT/scripts/test"

git branch -D plugin-export >/dev/null 2>&1 || true
git subtree split --prefix=shell-plugin -b plugin-export >/dev/null
git push "$REMOTE" plugin-export:main
git branch -D plugin-export >/dev/null

echo
echo "pushed. installed copies update with:  omarchy plugin update io.github.delarosa1312.sony-xm5"
