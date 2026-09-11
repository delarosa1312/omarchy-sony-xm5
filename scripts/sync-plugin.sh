#!/usr/bin/env bash
# The Omarchy shell hot-reloads plugin code under ~/.config/omarchy/plugins/,
# so that is where the widget is actually edited. This keeps the copy in the
# repo level with it. Same shape as the dotfiles sync: pull = live -> repo
# (default), push = repo -> live.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID=io.github.delarosa1312.sony-xm5
LIVE="$HOME/.config/omarchy/plugins/$ID"
REPO="$ROOT/shell-plugin"

# Everything the plugin folder holds, not a list of extensions. A named list
# silently left Model.js behind, and a panel missing its logic does not fail
# loudly -- the bar widget simply stops appearing.
sync() {
  rsync -a --delete --exclude ".git" "$1"/ "$2"/
}

if [ "${1:-pull}" = push ]; then
  mkdir -p "$LIVE"
  sync "$REPO" "$LIVE"
  # Saving under the plugin dir is supposed to reload it, but the QML engine
  # keeps serving the component it already compiled; only a restart reliably
  # picks changes up.
  omarchy restart shell
  echo "pushed to $LIVE"
else
  mkdir -p "$REPO"
  sync "$LIVE" "$REPO"
  echo "pulled from $LIVE"
fi
