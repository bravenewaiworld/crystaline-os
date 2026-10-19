#!/bin/bash
# Tests brick-timezone (system/board/brick/rootfs-overlay/usr/sbin/brick-timezone) on the PC: the
# real script runs against a fake root (BRICK_ROOT) whose zoneinfo is the PC's, with stubs for
# hwclock (records its calls and the offset the real one would give the kernel) and logger. With
# BusyBox on the PATH (make test-timezone builds the device's, tools/system/pc-busybox.sh), the
# script sees only BusyBox's applets and the stubs, as on the device; without it, the PC's shell
# and tools. Prints PASS or the first failure.
# Usage: test-timezone.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CMD=$ROOT/system/board/brick/rootfs-overlay/usr/sbin/brick-timezone
[ -f /usr/share/zoneinfo/zone.tab ] || { echo "needs the PC's time zone data (tzdata)" >&2; exit 1; }
DATE=$(command -v date)	# the PC's, for glibc's reading of a zone file
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export BRICK_ROOT=$T/root TEST_DIR=$T/test
fail() { { echo "FAIL: $*"; [ ! -s $TEST_DIR/log ] || { echo "log:"; cat $TEST_DIR/log; }; } >&2; exit 1; }

# --- Stubs, and BusyBox's applets if there is BusyBox ---
mkdir -p $T/bin
cat >$T/bin/hwclock <<EOF
#!/bin/sh
echo "hwclock \$* \$(TZ=:\$BRICK_ROOT/var/state/time/localtime $DATE +%z)" >>\$TEST_DIR/hwclock
[ ! -e \$TEST_DIR/hwclock-fails ] || { echo "hwclock: settimeofday: Operation not permitted" >&2; exit 1; }
EOF
# logger [-s] [-t TAG] MSG: MSG to $TEST_DIR/log (shown on a failure) and stderr.
printf '#!/bin/sh\n[ "$1" = -s ] && shift; [ "$1" = -t ] && shift 2; echo "$*" >>$TEST_DIR/log; echo "$*" >&2\n' >$T/bin/logger
chmod +x $T/bin/*
if command -v busybox >/dev/null; then
	SH="$(command -v busybox) sh" P=$T/bin:$T/bb
	mkdir $T/bb
	for a in cat cut date grep head ln mkdir mv readlink rm sort; do ln -s "$(command -v busybox)" $T/bb/$a; done
else
	echo "no BusyBox on the PATH: testing with the PC's shell and tools" >&2
	SH=sh P=$T/bin:$PATH
fi

# bt ARG...: runs brick-timezone; its stderr goes to $TEST_DIR/stderr.
bt() { PATH=$P $SH "$CMD" "$@" 2>$TEST_DIR/stderr; }
# reset: a fresh fake root, as on a new device (no zone set, nothing given to the kernel).
reset() {
	rm -rf $BRICK_ROOT $TEST_DIR
	mkdir -p $BRICK_ROOT/usr/share $BRICK_ROOT/run $TEST_DIR
	ln -s /usr/share/zoneinfo $BRICK_ROOT/usr/share/zoneinfo
	: >$TEST_DIR/hwclock
}
# expect NAME GOT WANT
expect() { [ "$2" = "$3" ] || fail "$1: got \"$2\", expected \"$3\""; }
hwclock_calls() { wc -l <$TEST_DIR/hwclock | tr -d ' '; }

# --- get, list ---
reset
expect "get without a zone" "$(bt get)" UTC
list=$(bt list)
expect "list starts with UTC" "$(head -1 <<<"$list")" UTC
expect "list has America/Toronto once" "$(grep -c '^America/Toronto$' <<<"$list")" 1
[ "$(grep -c . <<<"$list")" -gt 300 ] || fail "list: only $(grep -c . <<<"$list") zones"
expect "list has no comments or blank lines" "$(grep -c -e '^#' -e '^$' <<<"$list" || true)" 0

# --- set ---
for z in '' ../etc/passwd /etc/passwd zone.tab iso3166.tab Europe Europe/ 'Europe/Paris ' \
	'Europe/Paris;x' Nowhere/City posix/Europe/Paris right/UTC; do
	if bt set "$z" >/dev/null; then fail "set accepted \"$z\""; fi
	expect "set \"$z\" leaves the zone" "$(bt get)" UTC
	expect "set \"$z\" leaves the kernel alone" "$(hwclock_calls)" 0
done
bt set Nowhere/City >/dev/null || grep -q 'no time zone "Nowhere/City"' $TEST_DIR/stderr ||
	fail "set's error: $(cat $TEST_DIR/stderr)"
expect "set Europe/Paris" "$(bt set Europe/Paris)" Europe/Paris
expect "the link" "$(readlink $BRICK_ROOT/var/state/time/localtime)" /usr/share/zoneinfo/Europe/Paris
expect "glibc reads the zone through the link" \
	"$(TZ=:$BRICK_ROOT/var/state/time/localtime $DATE -d @0 +%H:%M%Z)" 01:00CET
expect "set gives the kernel the new offset, with -u" "$(tail -1 $TEST_DIR/hwclock)" \
	"hwclock -u --systz $(TZ=Europe/Paris $DATE +%z)"
grep -q 'time zone UTC -> Europe/Paris' $TEST_DIR/log || fail "set isn't logged"
for z in UTC Etc/GMT+5 US/Eastern America/Argentina/Buenos_Aires; do
	expect "set $z" "$(bt set $z)" $z
done

# --- kernel: hwclock only when the offset changes; a failure is retried ---
reset
bt kernel; bt kernel
expect "kernel twice at one offset" "$(hwclock_calls)" 1
echo +9999 >$BRICK_ROOT/run/brick-timezone.offset	# as if the offset had changed since
bt kernel
expect "kernel after a change" "$(hwclock_calls)" 2
echo +9999 >$BRICK_ROOT/run/brick-timezone.offset; touch $TEST_DIR/hwclock-fails
if bt kernel; then fail "kernel succeeded with hwclock failing"; fi
grep -q "can't give the kernel the offset .*Operation not permitted" $TEST_DIR/log ||
	fail "hwclock's failure isn't logged"
expect "a failure isn't remembered" "$(cat $BRICK_ROOT/run/brick-timezone.offset)" +9999
rm $TEST_DIR/hwclock-fails
expect "set succeeds when only the kernel fails" "$(touch $TEST_DIR/hwclock-fails; bt set Asia/Tokyo)" Asia/Tokyo
rm $TEST_DIR/hwclock-fails

# --- A zone whose file is gone (e.g. dropped from a later tzdata) reads as UTC, as glibc uses ---
ln -sfn /usr/share/zoneinfo/Gone/Zone $BRICK_ROOT/var/state/time/localtime
expect "get with a broken link" "$(bt get)" UTC

if bt bogus; then fail "an unknown command succeeded"; fi
echo PASS
