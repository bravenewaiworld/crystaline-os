#!/bin/sh
# Run a Specular build (or a spike example) on a running Brick over SSH (see
# tools/system/ssh.sh for BRICK), for quick iteration without changing the device's system. Stops
# the frontend service so the binary has the screen and buttons to itself, runs it in the
# foreground with its output here, then restarts the service, also when interrupted with Ctrl-C.
# Works on our system and on the test card.
# Usage: run-specular.sh <binary> [args...] (arguments must not contain spaces)
set -eu
. "$(dirname "$0")/system/ssh.sh"
BIN=$1; shift
NAME=${BIN##*/}
# frontend start|stop: under our system's supervisor (runit's sv) or the test card's (procd).
FRONTEND='frontend() { if [ -d /etc/sv ]; then sv $1 frontend >/dev/null; else /etc/init.d/frontend $1; fi; }'
to_brick "$BIN" "root@$BRICK:/tmp/$NAME"
restore() { on_brick "killall $NAME 2>/dev/null; $FRONTEND; frontend start"; }
trap restore EXIT
trap 'exit 130' INT TERM
on_brick -t "$FRONTEND; frontend stop; cd /tmp && ./$NAME $*"
