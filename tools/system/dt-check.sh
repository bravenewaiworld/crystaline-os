#!/bin/bash
# Check the kernel's device-tree edits on a Brick running our system (only reads from it): shows
# their outcome (/chosen/crystaline,dt-edits) and the kernel's dt-edits lines, and checks that the
# tree the kernel used (/sys/firmware/fdt) is what this checkout's edits make of the tree U-Boot
# handed over (/sys/firmware/fdt-bootloader); the status names the table, so a device running
# another table's edits shows as different. Saves both in build/dt-samples/ (not in git: they hold
# the device's serial number), where make test-dt-edits applies them too. On a kernel without the
# edits, /sys/firmware/fdt is U-Boot's tree: it is saved as the -bootloader sample, and the log of
# this checkout's edits on it is printed.
# Usage: dt-check.sh          BRICK as for ssh.sh. Exits 1 if anything doesn't match, or the kernel
#                             has no edits.
set -euo pipefail
. "$(dirname "$0")/ssh.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ok=1

status=$(on_brick 'tr -d "\0" </proc/device-tree/chosen/crystaline,dt-edits' 2>/dev/null) ||
	status="(none: the running kernel has no built-in edits, or couldn't copy the tree)"
echo "status: $status"
on_brick 'dmesg | grep dt-edits' || echo "(no dt-edits lines in the kernel log)"
on_brick 'cat /sys/firmware/fdt' >$T/kernel.dtb
"$ROOT/tools/system/build-dt-edits-apply.sh" $T/tool
mkdir -p "$ROOT/build/dt-samples"
name=$ROOT/build/dt-samples/$(date +%Y%m%d-%H%M%S)
if ! on_brick 'cat /sys/firmware/fdt-bootloader' >$T/bootloader.dtb 2>/dev/null; then
	cp $T/kernel.dtb "$name-bootloader.dtb"
	echo "no /sys/firmware/fdt-bootloader: saved U-Boot's tree as $name-bootloader.dtb; this checkout's edits on it:"
	$T/tool/dt-edits-apply $T/kernel.dtb $T/expected.dtb || true
	exit 1
fi
# Exit 1 (the edits failed) still writes the tree the kernel would use, so that is compared too.
rc=0; $T/tool/dt-edits-apply $T/bootloader.dtb $T/expected.dtb >/dev/null || rc=$?
if [ $rc = 2 ]; then
	echo "MISMATCH: this checkout's edits can't be applied to the bootloader's tree"; ok=
elif cmp -s $T/expected.dtb $T/kernel.dtb; then
	echo "the kernel's tree is what this checkout's edits make of the bootloader's"
else
	echo "MISMATCH: the kernel's tree differs from this checkout's edits applied to the bootloader's:"
	diff <(dtc -q -f -s -I dtb -O dts $T/expected.dtb 2>/dev/null) \
		<(dtc -q -f -s -I dtb -O dts $T/kernel.dtb 2>/dev/null) | head -40 || true
	ok=
fi

cp $T/bootloader.dtb "$name-bootloader.dtb"
cp $T/kernel.dtb "$name-kernel.dtb"
echo "saved $name-bootloader.dtb and -kernel.dtb"
[ -n "$ok" ]
