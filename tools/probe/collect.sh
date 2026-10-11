#!/bin/sh
# Run the read-only probe (probe.sh) on a TrimUI Brick over SSH and unpack the
# results locally. The Brick must run stock firmware with SSH enabled.
# Usage: collect.sh [user@]host        e.g. collect.sh root@192.168.2.253
# Results land in .scratch/research/device/<timestamp>/.
set -e
HOST=${1:?usage: collect.sh [user@]host}
case $HOST in *@*) ;; *) HOST=root@$HOST ;; esac
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BUILD=$ROOT/build/probe
SRC=$ROOT/tools/probe/memdump.c

if [ ! "$BUILD/memdump" -nt "$SRC" ]; then
	# Static, so it doesn't depend on the device's libraries; the -lgcc_eh group is needed
	# because this toolchain's static glibc references the unwinder.
	. "$ROOT/tools/env.sh"
	mkdir -p "$BUILD"
	"${CROSS_COMPILE}gcc" -O2 -static -s -o "$BUILD/memdump" "$SRC" \
		-Wl,--start-group -lgcc -lgcc_eh -lc -Wl,--end-group
fi

DEST=$ROOT/.scratch/research/device/$(date +%Y%m%d-%H%M%S)
mkdir -p "$DEST"
# One connection: ship the script and helper in, stream the result tarball out.
tar cf - -C "$ROOT/tools/probe" probe.sh -C "$BUILD" memdump |
	ssh "$HOST" 'D=/tmp/brick-probe-tools; rm -rf $D; mkdir -p $D && cd $D && tar xf - && sh probe.sh; rm -rf $D' |
	tar xzf - -C "$DEST" --strip-components=1 || true
# Only the last stage of a pipeline sets the exit status, so check the result.
if [ -z "$(ls -A "$DEST")" ]; then
	rmdir "$DEST"
	echo "probe failed: no results received" >&2
	exit 1
fi
echo "saved to $DEST"
