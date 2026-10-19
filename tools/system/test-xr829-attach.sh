#!/bin/bash
# Tests xr829-attach (userspace/xr829-attach) on the development PC. A PC build with every path
# under a fake root (TEST_ROOT: rfkill switches, chip ID, sleep driver files, firmware, address
# file) runs against a fake XR829 on a pty (test-xr829-attach.py), which checks the boot ROM
# protocol, the port's settings at each stage, the uploaded firmware and the HCI commands. Cases:
# the address (derived, kept, replaced), a boot ROM that answers late, errs or never answers,
# unexpected and refusing HCI events, the 20 s time limit, and a missing chip ID or rfkill switch.
# Attaching itself (line discipline N_HCI) can't work on a pty, so a good run ends there.
# Takes about 40 s. Prints PASS or the first failure.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R=$T/root
fail() { echo "FAIL: $*" >&2; exit 1; }

gcc -O2 -Wall -Wextra -DTEST_ROOT="\"$R\"" -o "$T/xr829-attach" \
	"$ROOT/userspace/xr829-attach/xr829-attach.c"
# An odd size, so that the last chunk is short and has an odd length.
head -c 10241 /dev/urandom >"$T/firmware"
# The chip ID of the Brick in docs/wireless.md, then the rest of the fuses.
CHIP_ID='\x00\x80\x40\x54\x14\x48\x00\x6c\x50\x9c\xc8\x00\xdd\x1f\x86\x1c'
DERIVED=0e:e5:71:99:0b:9f

# fresh: a new fake root. rfkill0 is hci0's switch, which must be left alone.
fresh() {
	rm -rf "$R"
	mkdir -p "$R/dev" "$R/lib/firmware" "$R/var/state/bluetooth" "$R/proc/bluetooth/sleep" \
		"$R/sys/bus/nvmem/devices/sunxi-sid0" "$R/sys/class/rfkill/rfkill0" "$R/sys/class/rfkill/rfkill1"
	cp "$T/firmware" "$R/lib/firmware/fw_xr829_bt.bin"
	{ printf "$CHIP_ID"; head -c 240 /dev/zero; } >"$R/sys/bus/nvmem/devices/sunxi-sid0/nvmem"
	echo hci0 >"$R/sys/class/rfkill/rfkill0/name"
	echo untouched >"$R/sys/class/rfkill/rfkill0/state"
	echo sunxi-bt >"$R/sys/class/rfkill/rfkill1/name"
	: >"$R/sys/class/rfkill/rfkill1/state"
	: >"$R/proc/bluetooth/sleep/btwake"
	: >"$R/proc/bluetooth/sleep/lpm"
}
# run CASE MODE: a run against the fake chip in MODE; prints its output. The fake must have found
# no problems.
run() {
	local out
	out=$(python3 -I "$ROOT/tools/system/test-xr829-attach.py" "$T/xr829-attach" "$R" "$2" 2>&1)
	! grep -q '^fake: FAIL' <<<"$out" || fail "$1:"$'\n'"$out"
	echo "$out"
}
# expect CASE PATTERN OUTPUT [COUNT]: OUTPUT has COUNT (default 1) lines matching PATTERN.
expect() {
	[ "$(grep -c -- "$2" <<<"$3")" = "${4:-1}" ] ||
		fail "$1: expected ${4:-1} line(s) \"$2\" in:"$'\n'"$3"
}
# holds CASE PATH TEXT: the file holds exactly TEXT.
holds() { [ "$(cat "$2")" = "$3" ] || fail "$1: $2 holds \"$(cat "$2")\", expected \"$3\""; }

c="no address file: derived from the chip ID"
fresh; out=$(run "$c" ok)
expect "$c" "address $DERIVED, from the chip ID$" "$out"
expect "$c" '^fake: firmware matches$' "$out"
expect "$c" 'firmware: 10241 bytes uploaded in' "$out"
expect "$c" '^fake: HCI 0x0c03 $' "$out" 2
expect "$c" '^fake: HCI 0xfc18 60e31600$' "$out"
expect "$c" '^fake: HCI 0xfc0a 0200069f0b9971e50e$' "$out"
expect "$c" 'controller: Bluetooth 4.1 (HCI version 7, revision 0x0e19), LMP version 7, subversion 0x1234, manufacturer 0x063d$' "$out"
expect "$c" 'attach: set line discipline N_HCI: ' "$out"
expect "$c" '^fake: exit 1$' "$out"
holds "$c" "$R/var/state/bluetooth/xr_bt.conf" "0e e5 71 99 0b 9f "
holds "$c" "$R/sys/class/rfkill/rfkill1/state" 1
holds "$c" "$R/sys/class/rfkill/rfkill0/state" untouched
holds "$c" "$R/proc/bluetooth/sleep/btwake" 1
holds "$c" "$R/proc/bluetooth/sleep/lpm" 0

c="a saved address is kept"
fresh; printf '22 22 e4 3c 65 50 ' >"$R/var/state/bluetooth/xr_bt.conf"
out=$(run "$c" ok)
expect "$c" 'address 22:22:e4:3c:65:50, from .*/xr_bt.conf$' "$out"
expect "$c" '^fake: HCI 0xfc0a 02000650653ce42222$' "$out"
holds "$c" "$R/var/state/bluetooth/xr_bt.conf" "22 22 e4 3c 65 50 "

for bad in 'zz' '22 22 e4 3c 65 50' '22 22 e4 3c 65 50 ff ' '00 00 00 00 00 00 ' '22 22 22 9e 8b 3f '; do
	c="an invalid address file (\"$bad\") is replaced"
	fresh; printf '%s' "$bad" >"$R/var/state/bluetooth/xr_bt.conf"
	out=$(run "$c" ok)
	expect "$c" 'holds no valid address .*: replacing it$' "$out"
	expect "$c" "address $DERIVED, from the chip ID$" "$out"
	holds "$c" "$R/var/state/bluetooth/xr_bt.conf" "0e e5 71 99 0b 9f "
done

c="a boot ROM that answers late: power-cycled and started again"
fresh; out=$(run "$c" late)
expect "$c" 'boot ROM sync at 115200 baud: no answer to 16 sync bytes$' "$out"
expect "$c" 'power-cycling and starting again (try 2 of 3)$' "$out"
expect "$c" '^fake: firmware matches$' "$out"

c="a boot ROM error: three tries, then exit"
fresh; out=$(run "$c" romerr)
expect "$c" 'firmware upload at byte 2048: boot ROM error 3 (bad checksum)$' "$out" 3
expect "$c" '^fake: exit 1$' "$out"

c="a boot ROM that never answers: three tries, then exit"
fresh; out=$(run "$c" mute)
expect "$c" 'no answer to 16 sync bytes$' "$out" 3
expect "$c" '^fake: exit 1$' "$out"

c="unexpected HCI events are skipped"
fresh; out=$(run "$c" event)
expect "$c" 'HCI reset: skipped HCI event 04 13 01 00$' "$out"
expect "$c" 'HCI reset after setting the address: skipped HCI event 04 13 01 00$' "$out"
expect "$c" 'controller: Bluetooth 4.1' "$out"

c="a refused HCI command"
fresh; out=$(run "$c" refuse)
expect "$c" 'set the address: command 0xfc0a refused: status 0x0c$' "$out"
expect "$c" '^fake: exit 1$' "$out"

c="the 20 s time limit"
fresh; out=$(run "$c" flood)
expect "$c" 'gave up: not attached within 20 s; last step: HCI reset$' "$out"
expect "$c" '^fake: exit 1$' "$out"

c="no chip ID and no address file"
fresh; rm "$R/sys/bus/nvmem/devices/sunxi-sid0/nvmem"
out=$(run "$c" ok)
expect "$c" 'address: read the chip ID from .*: No such file or directory$' "$out"
expect "$c" '^fake: exit 1$' "$out"

c="no rfkill switch for the chip"
fresh; echo other >"$R/sys/class/rfkill/rfkill1/name"
out=$(run "$c" ok)
expect "$c" 'power: no rfkill switch named "sunxi-bt"$' "$out"
holds "$c" "$R/sys/class/rfkill/rfkill0/state" untouched

echo PASS
