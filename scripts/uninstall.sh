#!/usr/bin/env bash
# Undo scripts/install.sh: stop the user services and take the units back out.
#
# Only touches what install.sh wrote. The build under vendor/ is left alone --
# it belongs to the checkout, and deleting the checkout takes it with it.
set -euo pipefail
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
LIBDIR="${XDG_DATA_HOME:-$HOME/.local/share}/mdrctl"

# --now so the daemon lets go of the headset's control session rather than
# holding it until the next logout, which would leave the device refusing the
# next client with EBUSY.
systemctl --user disable --now mdrctld.service 2>/dev/null || true
systemctl --user disable --now mpris-proxy.service 2>/dev/null || true

rm -f "$UNITS/mdrctld.service" "$UNITS/mpris-proxy.service"
systemctl --user daemon-reload

# The installed copy, which is what the unit actually ran.
rm -rf "$LIBDIR" "$LIBDIR.new" "$LIBDIR.old"

echo "removed. the widget is separate:"
echo "  omarchy plugin remove io.github.delarosa1312.sony-xm5"
