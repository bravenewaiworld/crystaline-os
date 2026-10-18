#!/bin/sh
# Run a Specular build (or a spike example) on a running Brick over SSH (see
# tools/system/ssh.sh for BRICK), for quick iteration without changing the device's system. Stops
# the frontend service so the binary has the screen and buttons to itself, runs it in the
# foreground with its output here, then restarts the service, also when interrupted with Ctrl-C.
# Usage: run-specular.sh <binary> [args...] (arguments must not contain spaces)
set -eu
. "$(dirname "$0")/system/ssh.sh"
BIN=$1; shift
NAME=${BIN##*/}
to_brick "$BIN" "root@$BRICK:/tmp/$NAME"
restore() { on_brick "killall $NAME 2>/dev/null; sv start frontend >/dev/null"; }
trap restore EXIT
trap 'exit 130' INT TERM
# Specular finds its cores and fonts next to its binary; from /tmp, it is pointed at the installed
# ones (SPECULAR_PREFIX in the Makefile).
on_brick -t "sv stop frontend >/dev/null; cd /tmp &&
	SPECULAR_CORES=/usr/lib/specular/cores SLINT_FONT_PATH=/usr/lib/specular/fonts ./$NAME $*"
