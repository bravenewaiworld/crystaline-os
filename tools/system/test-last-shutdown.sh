#!/bin/bash
# Tests last-shutdown (system/board/brick/rootfs-overlay/usr/libexec/brick/last-shutdown) on the PC,
# against a fake root (LAST_SHUTDOWN_ROOT): what each way a run can end leaves in
# /run/brick/last-shutdown at the next start. Uses BusyBox's shell if busybox is on the PATH (make
# test-last-shutdown puts the PC build of the device's BusyBox there), else the PC's. Prints PASS or the first failure.
# Usage: test-last-shutdown.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CMD=$ROOT/system/board/brick/rootfs-overlay/usr/libexec/brick/last-shutdown
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SH=sh; command -v busybox >/dev/null && SH="busybox sh"
export LAST_SHUTDOWN_ROOT=$T
run() { $SH "$CMD" "$@"; }
fail() { echo "FAIL ($CASE): $*" >&2; cat $T/dev/kmsg >&2; exit 1; }
# boot EXPECTED: a start, after which /run/brick/last-shutdown holds EXPECTED (empty: no file).
boot() {
	rm -rf $T/run; mkdir -p $T/dev; : >$T/dev/kmsg
	run start
	got=$(cat $T/run/brick/last-shutdown 2>/dev/null || true)
	[ "$got" = "$1" ] || fail "last-shutdown '$got', expected '$1'"
	[ -e $T/system/state/running ] || fail "not marked running"
	[ ! -e $T/system/state/shutdown-reason ] || fail "reason left behind"
	grep -q '^<5>last-shutdown: the last run ended' $T/dev/kmsg || fail "not logged"
}
CASE="first start"; boot ""
CASE="after an orderly shutdown"; run stop; boot ""
CASE="after a crash or power cut"; boot unexpected
CASE="after the battery guard's power-off"; run reason battery-empty; run stop; boot battery-empty
CASE="battery guard's power-off cut short"; run reason battery-empty; boot battery-empty
CASE="usage"; ! run bogus 2>/dev/null || fail "accepted a bad argument"
echo PASS
