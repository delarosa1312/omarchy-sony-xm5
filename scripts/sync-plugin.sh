#!/usr/bin/env bash
# The Omarchy shell hot-reloads plugin code under ~/.config/omarchy/plugins/,
# so that is where the widget is actually edited. This keeps the copy in the
# repo level with it. Same shape as the dotfiles sync: pull = live -> repo
# (default), push = repo -> live.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID=delarosa.headphones
LIVE="$HOME/.config/omarchy/plugins/$ID"
REPO="$ROOT/shell-plugin"

if [ "${1:-pull}" = push ]; then
  mkdir -p "$LIVE"
  cp "$REPO"/*.json "$REPO"/*.qml "$LIVE/"
  # Saving under the plugin dir is supposed to reload it, but the QML engine
  # keeps serving the component it already compiled; only a restart reliably
  # picks changes up.
  omarchy restart shell
  echo "pushed to $LIVE"
else
  mkdir -p "$REPO"
  cp "$LIVE"/*.json "$LIVE"/*.qml "$REPO/"
  echo "pulled from $LIVE"
fi
