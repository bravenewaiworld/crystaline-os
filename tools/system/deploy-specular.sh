#!/bin/sh
# Replace Specular on a Brick running our system and restart it, keeping it across restarts, for
# quick iteration without building a system image. The root filesystem is read-only, so the binary
# goes into the running version's developer layer (/system/overlay/<version>, see the initramfs).
# The first time, that layer doesn't exist yet: it is made and the device restarts to use it.
# Usage: deploy-specular.sh <specular binary>
set -eu
. "$(dirname "$0")/ssh.sh"
if ! on_brick 'grep -q "^overlay / overlay" /proc/mounts'; then
	on_brick 'mkdir -p /system/overlay/$(cat /etc/brick-version) && reboot'
	echo "made the developer layer; waiting for $BRICK to restart"
	sleep 10
	until on_brick true 2>/dev/null; do sleep 2; done
fi
to_brick "$1" root@$BRICK:/usr/lib/specular/specular.new
on_brick 'mv /usr/lib/specular/specular.new /usr/lib/specular/specular && sv restart frontend'
