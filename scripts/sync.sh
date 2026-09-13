#!/usr/bin/env bash
# Copy the widget into the live plugin directory and reload the shell.
#
# The repository root is the plugin -- manifest.json sits beside the daemon, so
# `omarchy plugin add` can clone one repository and get both. Only the files
# the shell actually loads are copied here; the daemon comes from the mdrctl
# package, not from a plugins folder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID=$(python3 -c "import json;print(json.load(open('$ROOT/manifest.json'))['id'])")
LIVE="$HOME/.config/omarchy/plugins/$ID"
FILES=(manifest.json BarWidget.qml Panel.qml Model.js preview.png README.md LICENSE)

if [ "${1:-push}" = push ]; then
  mkdir -p "$LIVE"
  for f in "${FILES[@]}"; do cp "$ROOT/$f" "$LIVE/$f"; done
  # Saving under the plugin directory is supposed to reload it, but the QML
  # engine keeps serving the component it already compiled.
  omarchy restart shell
  echo "pushed $ID"
else
  for f in "${FILES[@]}"; do cp "$LIVE/$f" "$ROOT/$f"; done
  echo "pulled $ID"
fi
