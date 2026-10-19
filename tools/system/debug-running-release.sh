#!/bin/sh
# Copy the debugging tools a release image leaves out (system/board/brick/debug-tools.list) to a
# Brick running a release image, over SSH, into /run/debug (in memory), so they are gone at the
# next restart and nothing on the device's storage changes. They come from where build-system.sh
# takes them (this checkout's Buildroot build, and our device tools) and use the device's C library
# rather than one of their own, so the device's dynamic loader checks each program without running
# it (ld.so --list): it names any library or symbol version the device lacks, and then all of
# /run/debug is removed again.
# Logs in with the checkout's key, which only development images accept, and otherwise with the
# user's own key, the only kind a release image accepts (imported on the device with brick-ssh):
# SSH_KEY=<private key file> (then the checkout's isn't tried), or else the keys ssh offers by
# default (agent, ~/.ssh/id_*). BRICK: as in ssh.sh.
# Usage: [SSH_KEY=<key>] debug-running-release.sh
set -eu
. "$(dirname "$0")/ssh.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$ROOT/build/buildroot/target
READELF=$ROOT/build/buildroot/host/bin/aarch64-buildroot-linux-gnu-readelf
D=/run/debug

if [ -n "${SSH_KEY:-}" ] || ! on_brick true 2>/dev/null; then
	SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5${SSH_KEY:+ -i $SSH_KEY -o IdentitiesOnly=yes}"
	on_brick true || {
		cat >&2 <<EOF
can't log in to root@$BRICK over SSH (ssh's message above; BRICK=<address> for another address).
On a release image, SSH is off until it is switched on on the device, with your own key:
  1. put your public key in authorized_keys at the root of the SD card's data partition;
  2. on the device, run brick-ssh import, then brick-ssh on (Specular's developer settings will;
     until they do, a release image can't be reached over SSH);
  3. give your private key here with SSH_KEY=<file>, unless ssh offers it by itself.
Release images make host keys of their own: if ssh says the host key has changed (the address
was a development image's), remove the old one with ssh-keygen -R $BRICK.
EOF
		exit 1
	}
fi
# brick-ssh prints image=release on a release image; systems from before it are all development ones.
if [ "$(on_brick 'brick-ssh 2>/dev/null' | sed -n 's/^image=//p')" != release ]; then
	echo "$BRICK runs a development image, which has the debugging tools already"
	exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Our device tools, laid out as build-system.sh installs them.
mkdir -p "$TMP/ours/usr/bin"
cp "$ROOT"/build/tools/* "$ROOT/tools/device/powertest" "$TMP/ours/usr/bin/"
# match DIR PATTERN: the paths under DIR that PATTERN matches.
match() { (cd "$1" && for f in $2; do if [ -e "$f" ]; then echo "$f"; fi; done); }
# tar_args: "-C <source> <its files>" for each line of the list; checks: the loader's check of
# each program, as commands for the device, where check fails, showing the loader's output, if the
# loader fails or misses a library or symbol version ("not found").
tar_args= checks=
CHECK='check() { out=$("$@" 2>&1) && ! echo "$out" | grep -q "not found" || { echo "$out"; exit 1; }; }'
grep -v -e '^#' -e '^$' "$ROOT/system/board/brick/debug-tools.list" >"$TMP/list"
while read -r p; do
	f=
	for src in "$T" "$TMP/ours"; do
		f=$(match "$src" "$p")
		[ -z "$f" ] || break
	done
	[ -n "$f" ] || { echo "nothing matches $p in $T or our device tools (make buildroot device-tools)" >&2; exit 1; }
	tar_args="$tar_args -C $src $f"
	for x in $f; do
		interp=$("$READELF" -l "$src/$x" 2>/dev/null | sed -n 's/.*interpreter: \(.*\)\]/\1/p')
		[ -z "$interp" ] || checks="$checks check $interp --list $D/$x;"
	done
done <"$TMP/list"
[ -n "$checks" ] || { echo "no programs in debug-tools.list (does $READELF run?)" >&2; exit 1; }
tar --owner=0 --group=0 -cf - $tar_args |
	on_brick "rm -rf $D && mkdir -p $D && tar -xf - -C $D &&
		echo 'export PATH=$D/usr/bin:\$PATH LD_LIBRARY_PATH=$D/usr/lib' >$D/env"
if ! on_brick "export LD_LIBRARY_PATH=$D/usr/lib; $CHECK; $checks"; then
	on_brick "rm -rf $D"
	cat >&2 <<EOF
This checkout's debugging tools don't suit $BRICK's system (the loader's message above), so they
are removed again. Check out the commit its version ends with ($(on_brick cat /etc/brick-version),
<date>-<time>-<commit>[-dirty]), and try again.
EOF
	exit 1
fi
cat <<EOF
The debugging tools are in $D on $BRICK until it restarts. In an SSH session there:
  . $D/env    puts them on PATH, and their libraries where the loader looks
then use them as in DEVELOPMENT.md ("Debugging programs", "On-device tools"). Unlike the tools,
SSH stays on across restarts until it is switched off on the device (brick-ssh off).
EOF
