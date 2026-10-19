#!/bin/sh
# Install one version of the system (build-system.sh's output) on a Brick running our system and
# restart into it, over SSH (see ssh.sh for BRICK), the way Settings installs an update: signs it
# as an update file (sign-update.sh; with UPDATE_KEY, or this checkout's development key), copies
# that to /tmp on the device (in memory, so it takes no room on the system partition beside
# brick-install's copy) and runs `brick-install update`. The device keeps this version and the
# one it was running.
# Usage: [UPDATE_KEY=<key.pem>] update-device.sh <system-version-dir>
set -eu
. "$(dirname "$0")/ssh.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
V=$(readlink -f "$1")
VERSION=$(basename "$V")
on_brick true || { echo "can't reach $BRICK over SSH (asleep? USB cable? set BRICK=<address>)" >&2; exit 1; }
on_brick 'test -f /etc/brick-version' ||
	{ echo "$BRICK doesn't run our system (TrimUI's system? write an SD card with make sd-card)" >&2; exit 1; }
on_brick 'brick-install slots' >/dev/null || {
	echo "brick-install slots failed on $BRICK (above). A system from before the two boot slots can't be updated" >&2
	echo "this way: write an SD card (make sd-card), and install from it to update the internal storage." >&2
	exit 1
}
"$ROOT/tools/system/dev-keys.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
NAME=crystaline-$VERSION.update
"$ROOT/tools/system/sign-update.sh" "$V" "${UPDATE_KEY:-$ROOT/build/ssh-host-keys/update_key.pem}" "$TMP/$NAME" >/dev/null
to_brick "$TMP/$NAME" "root@$BRICK:/tmp/"
on_brick "brick-install update /tmp/$NAME >/tmp/update.out; s=\$?; rm -f /tmp/$NAME
	grep -v '^PROGRESS' /tmp/update.out; [ \$s = 0 ] && reboot" ||
	{ echo "the update failed; $BRICK still runs what it ran" >&2; exit 1; }
echo "$BRICK is restarting into $VERSION"
