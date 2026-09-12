#!/usr/bin/env bash
# Install the daemon as a user service, for machines without the Arch package.
#
# This installs a *copy* and points the unit at that. It used to point the unit
# straight at the checkout, which meant a long-lived service executed whatever
# was in a directory you edit, rebase and pull -- an ordinary `git checkout` of
# a branch changed the code the daemon would run on its next restart. The copy
# is published by rename, so an interrupted install cannot leave the unit
# pointing at a half-written tree.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
LIBDIR="${XDG_DATA_HOME:-$HOME/.local/share}/mdrctl"
BUILD="$ROOT/vendor/SonyHeadphonesClient/build"

# An absolute interpreter, resolved once here rather than through the PATH the
# service happens to inherit.
PYTHON="$(command -v python3)"
PYTHON="$(readlink -f "$PYTHON")"
[ -x "$PYTHON" ] || { echo "no python3 found" >&2; exit 1; }

if [ ! -f "$BUILD/libmdr/src/libmdr-shared.so" ]; then
  echo "== building libmdr =="
  "$ROOT/scripts/build-libmdr.sh"
fi

echo "== installing to $LIBDIR =="
stage="$LIBDIR.new"
rm -rf "$stage"
install -Dm755 "$ROOT/daemon/bin/mdrctld" "$stage/bin/mdrctld"
install -Dm755 "$ROOT/daemon/bin/mdrctl"  "$stage/bin/mdrctl"
install -Dm644 "$ROOT/daemon/lib/mdr.py"  "$stage/lib/mdr.py"
install -Dm755 "$BUILD/libmdr/src/libmdr-shared.so"       "$stage/lib/libmdr-shared.so"
install -Dm755 "$BUILD/libmdr-bt/src/libmdr-bt-shared.so" "$stage/lib/libmdr-bt-shared.so"
chmod 0755 "$stage"

# Publish by rename so the unit never sees a partial tree.
if [ -d "$LIBDIR" ]; then
  rm -rf "$LIBDIR.old"
  mv "$LIBDIR" "$LIBDIR.old"
fi
mv "$stage" "$LIBDIR"
rm -rf "$LIBDIR.old"

mkdir -p "$UNITS"
sed -e "s|@PYTHON@|$PYTHON|" \
    -e "s|@MDRCTLD@|$LIBDIR/bin/mdrctld|" \
    -e "s|@ARGS@|--build-dir $LIBDIR/lib|" \
    "$ROOT/daemon/systemd-user/mdrctld.service" > "$UNITS/mdrctld.service"
install -Dm644 "$ROOT/daemon/systemd-user/mpris-proxy.service" "$UNITS/mpris-proxy.service"

systemctl --user daemon-reload
systemctl --user enable mdrctld.service
# restart, not `enable --now`: --now does nothing to a unit that is already
# running, so an upgrade would leave the previous build serving until the next
# reboot and report success either way.
systemctl --user restart mdrctld.service

# Headphone play/pause and pause-on-removal travel over AVRCP, not MDR, so they
# need this bridge running or they reach nothing at all.
if command -v mpris-proxy >/dev/null; then
  systemctl --user enable mpris-proxy.service
  systemctl --user restart mpris-proxy.service
else
  echo "mpris-proxy not found (bluez-utils): pause-on-removal will not work" >&2
fi

echo
echo "installed. check it with:  $LIBDIR/bin/mdrctl status"
echo "the checkout is no longer what runs -- re-run this after changing it."
