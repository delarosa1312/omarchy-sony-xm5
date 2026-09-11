#!/usr/bin/env bash
# Install the daemon as a user service, wherever this happens to be cloned.
#
# The unit carries @MDRCTLD@ rather than a path, because a path baked into a
# repository is right for exactly one machine.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

if [ ! -f "$ROOT/vendor/SonyHeadphonesClient/build/libmdr/src/libmdr-shared.so" ]; then
  echo "== building libmdr =="
  "$ROOT/scripts/build-libmdr.sh"
fi

mkdir -p "$UNITS"
sed "s|@MDRCTLD@|$ROOT/bin/mdrctld|" "$ROOT/systemd-user/mdrctld.service" \
  > "$UNITS/mdrctld.service"
install -Dm644 "$ROOT/systemd-user/mpris-proxy.service" "$UNITS/mpris-proxy.service"

systemctl --user daemon-reload
systemctl --user enable --now mdrctld.service

# Headphone play/pause and pause-on-removal travel over AVRCP, not MDR, so they
# need this bridge running or they reach nothing at all.
if command -v mpris-proxy >/dev/null; then
  systemctl --user enable --now mpris-proxy.service
else
  echo "mpris-proxy not found (bluez-utils): pause-on-removal will not work" >&2
fi

echo
echo "installed. check it with:  $ROOT/bin/mdrctl status"
