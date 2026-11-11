#!/bin/sh
# Install one version of the system (build-system.sh's output) on a Brick running our system and
# restart into it, over SSH (see ssh.sh for ADDR), the way Settings installs an update: signs it
# as an update file (sign-update.sh; with UPDATE_KEY, or this checkout's development key), copies
# that to /tmp on the device (in memory, so it takes no room on the system partition beside
# crystaline-install's copy) and runs `crystaline-install update`. The device keeps this version and the
# one it was running.
# Usage: [UPDATE_KEY=<key.pem>] update-device.sh <system-version-dir>
set -eu
. "$(dirname "$0")/ssh.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
V=$(readlink -f "$1")
VERSION=$(basename "$V")
on_device true || { echo "can't reach $ADDR over SSH (asleep? USB cable? set ADDR=<address>)" >&2; exit 1; }
on_device 'test -f /etc/crystaline-version' ||
	{ echo "$ADDR doesn't run our system (TrimUI's system? write an SD card with make sd-card)" >&2; exit 1; }
on_device 'crystaline-install slots' >/dev/null || {
	echo "crystaline-install slots failed on $ADDR (above). A system from before the two boot slots can't be updated" >&2
	echo "this way: write an SD card (make sd-card), and install from it to update the internal storage." >&2
	exit 1
}
"$ROOT/tools/system/dev-keys.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
NAME=crystaline-$VERSION.update
"$ROOT/tools/system/sign-update.sh" "$V" "${UPDATE_KEY:-$ROOT/build/ssh-host-keys/update_key.pem}" "$TMP/$NAME" >/dev/null
to_device "$TMP/$NAME" "root@$ADDR:/tmp/"
on_device "crystaline-install update /tmp/$NAME >/tmp/update.out; s=\$?; rm -f /tmp/$NAME
	grep -v '^PROGRESS' /tmp/update.out; [ \$s = 0 ] && reboot" ||
	{ echo "the update failed; $ADDR still runs what it ran" >&2; exit 1; }
echo "$ADDR is restarting into $VERSION"
