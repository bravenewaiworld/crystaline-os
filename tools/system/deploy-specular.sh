#!/bin/sh
# Replace Specular on a Brick running our system and restart it, keeping it across restarts, for
# quick iteration without building a system image. The root filesystem is read-only, so Specular's
# files go into the running version's developer layer (/system/overlay/<version>, see the
# initramfs). The first time, that layer doesn't exist yet: it is made and the device restarts to
# use it.
# Usage: deploy-specular.sh <staging-dir> <prefix>
#   Sends <staging-dir><prefix>/ (the Makefile's specular target installs there) to <prefix> on the
#   device. Files no longer built stay on the device until the next update-device.
set -eu
. "$(dirname "$0")/ssh.sh"
if ! on_brick 'grep -q "^overlay / overlay" /proc/mounts'; then
	on_brick 'mkdir -p /system/overlay/$(cat /etc/brick-version) && reboot'
	echo "made the developer layer; waiting for $BRICK to restart"
	sleep 10
	until on_brick true 2>/dev/null; do sleep 2; done
fi
# Specular is stopped while its files are replaced (a running program's file can't be written).
tar -C "$1$2" --owner=0 --group=0 -cf - . |
	on_brick "sv stop frontend >/dev/null; mkdir -p $2 && tar -xf - -C $2; r=\$?; sv start frontend >/dev/null; exit \$r"
