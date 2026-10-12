#!/bin/sh
# Run a Specular build (or a spike example) on a running Brick over adb, for quick iteration
# without re-flashing the test card. Stops the test card's frontend service so the binary has the
# screen and buttons to itself, runs it in the foreground with its output here, then restarts the
# service, also when interrupted with Ctrl-C. With several adb devices, set ANDROID_SERIAL.
# Usage: run-specular.sh <binary> [args...] (arguments must not contain spaces)
set -eu
BIN=$1; shift
NAME=${BIN##*/}
adb push "$BIN" "/tmp/$NAME" >/dev/null
restore() { adb shell "killall $NAME 2>/dev/null; /etc/init.d/frontend start"; }
trap restore EXIT
trap 'exit 130' INT TERM
adb shell "/etc/init.d/frontend stop; cd /tmp && ./$NAME $*"
