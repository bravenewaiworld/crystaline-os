#!/bin/bash
# Tests board-env (system/common/rootfs-overlay/usr/libexec/crystaline/board-env) on the PC against
# fake device trees, and checks that every board's description (system/board/*/rootfs-overlay/
# usr/share/crystaline/boards/*.env) names everything the scripts read. Prints PASS or each failure.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CMD=$ROOT/system/common/rootfs-overlay/usr/libexec/crystaline/board-env
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
failed=0
fail() { echo "FAIL: $*"; failed=1; }

# dt STRING...: a fake device tree whose compatible property holds STRINGs (NUL-separated, as the
# kernel shows it).
dt() { mkdir -p $T/dt; printf '%s\0' "$@" >$T/dt/compatible; }
# pick: board-env's output for the fake device tree and $T/boards.
pick() { BOARDS=$T/boards DT=$T/dt sh "$CMD" 2>$T/err; }

mkdir $T/boards
printf 'BOARD_COMPATIBLE=powkiddy,rgb20-pro\n' >$T/boards/rgb20pro.env
printf 'BOARD_COMPATIBLE=rockchip,rk3566\n' >$T/boards/generic-rk3566.env
printf 'BOARD_COMPATIBLE=allwinner,a133\n' >$T/boards/brick.env

dt powkiddy,rgb20-pro rockchip,rk3566
[ "$(pick)" = $T/boards/rgb20pro.env ] || fail "the device's most specific string should win: got '$(pick)'"
dt allwinner,a133 arm,sun50iw10p1
[ "$(pick)" = $T/boards/brick.env ] || fail "Brick: got '$(pick)'"
dt powkiddy,rgb20-pro-max rockchip,rk3566-x	# no prefix or substring matches
if pick >/dev/null; then fail "a near-miss string matched: $(pick)"; fi
grep -q 'rockchip,rk3566-x' $T/err || fail "no match: stderr should list the device's strings: $(cat $T/err)"
rm $T/dt/compatible
if pick >/dev/null; then fail "no compatible property: should fail"; fi

# Every real board description: the names the scripts read, and a FAT label mkfs.fat accepts.
for f in "$ROOT"/system/board/*/rootfs-overlay/usr/share/crystaline/boards/*.env; do
	(
		set +eu	# report every problem with this file, not stop at the first
		. "$f" 2>$T/source.err
		[ ! -s $T/source.err ] || echo "FAIL: ${f#$ROOT/}: sourcing it printed: $(cat $T/source.err)"
		for v in BOARD_COMPATIBLE BOARD_NAME BOARD_CARD_CONTROLLER BOARD_CARD_LABEL BOARD_BATTERY; do
			[ -n "${!v}" ] || echo "FAIL: ${f#$ROOT/}: $v is empty"
		done
		[ ${#BOARD_CARD_LABEL} -le 11 ] || echo "FAIL: ${f#$ROOT/}: BOARD_CARD_LABEL is over 11 characters"
		grep -qx "BOARD_COMPATIBLE=$BOARD_COMPATIBLE" "$f" ||
			echo "FAIL: ${f#$ROOT/}: BOARD_COMPATIBLE must be written unquoted (board-env greps for it)"
	) | tee -a $T/board-fails
done
[ ! -s $T/board-fails ] || failed=1

[ $failed = 0 ] && echo PASS
exit $failed
