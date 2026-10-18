#!/bin/sh
# Copy one version of the system (build-system.sh's output) to a Brick running our system, make it
# the one that starts (brick-activate), and reboot into it. Over SSH (see ssh.sh for BRICK).
# The device keeps this version and the one it was running.
# Usage: update-device.sh <system-version-dir>
set -eu
. "$(dirname "$0")/ssh.sh"
V=$(readlink -f "$1")
VERSION=$(basename "$V")
on_brick true || { echo "can't reach $BRICK over SSH (asleep? USB cable? set BRICK=<address>)" >&2; exit 1; }
on_brick 'test -f /etc/brick-version' ||
	{ echo "$BRICK doesn't run our system (TrimUI's system? write an SD card with make sd-card)" >&2; exit 1; }
on_brick "rm -rf /system/images/$VERSION.part && mkdir -p /system/images/$VERSION.part"
to_brick "$V/boot.img" "$V/rootfs.squashfs" "$V/manifest.json" "root@$BRICK:/system/images/$VERSION.part/"
on_brick "mv /system/images/$VERSION.part /system/images/$VERSION && brick-activate $VERSION && reboot"
echo "$BRICK is restarting into $VERSION"
