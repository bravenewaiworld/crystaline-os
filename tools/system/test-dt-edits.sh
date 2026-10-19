#!/bin/bash
# Tests the kernel's built-in device-tree edits on the PC: generates the table from dt-tweaks.sh
# (dt-edits.sh), builds dt-edits-apply with the kernel's own fdt_edits.c and libfdt, and checks
# that applying it to TrimUI's tree gives what dt-tweaks.sh gives, that it is idempotent, that values
# set before the kernel are kept or reported, that a failed edit leaves the tree unchanged, and that
# the recorder refuses what the kernel can't redo. Trees captured from devices in build/dt-samples/
# (dt-check.sh) are applied too, and their log lines printed for review.
# Needs build/stock-fw (make stock-fw), dtc and a C compiler. Prints PASS or the first failure.
# Usage: test-dt-edits.sh          KERNEL_SRC overrides the kernel source tree (default linux/).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PKG=$ROOT/build/stock-fw/boot_package.fex
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { { echo "FAIL: $*"; [ ! -s $T/log ] || sed 's/^/  | /' $T/log; } >&2; exit 1; }

"$ROOT/tools/system/build-dt-edits-apply.sh" $T
python3 -I "$ROOT/tools/sdboot/toc1.py" "$PKG" 0 $T/pkg >/dev/null
cp $T/pkg/dtb.bin $T/stock.dtb
cp $T/stock.dtb $T/tweaked.dtb && "$ROOT/system/board/brick/dt-tweaks.sh" $T/tweaked.dtb

# apply IN OUT [EXIT]: runs the edits (log in $T/log), expecting exit EXIT (default 0).
apply() {
	local rc=0
	$T/dt-edits-apply "$1" "$2" >$T/log || rc=$?
	[ $rc = "${3:-0}" ] || fail "applying to ${1##*/} exited $rc"
}
logged() { grep -q -- "$1" $T/log || fail "log has no '$1'"; }
status() { fdtget "$1" /chosen crystaline,dt-edits; }
# dts TREE: the tree as sorted source, without the edits' status. -f: dtc otherwise refuses U-Boot's
# /dram property names (dram_para[NN]: '[' isn't valid in a name).
dts() { dtc -q -f -s -I dtb -O dts "$1" 2>/dev/null | grep -v '^\s*crystaline,dt-edits = '; }
same() { diff <(dts "$1") <(dts "$2") >$T/diff || fail "${1##*/} and ${2##*/} differ: $(head -20 $T/diff)"; }

echo "1. applied to TrimUI's tree: the same as dt-tweaks.sh, status ok"
apply $T/stock.dtb $T/out1.dtb
same $T/out1.dtb $T/tweaked.dtb
case $(status $T/out1.dtb) in "ok dt-tweaks "*" 0 kept, 0 replaced") ;; *) fail "status: $(status $T/out1.dtb)" ;; esac
logged " 0 kept, 0 replaced"

echo "2. applied again: nothing changes"
apply $T/out1.dtb $T/out2.dtb
same $T/out2.dtb $T/out1.dtb
logged ": 0 applied, [0-9]* in place, 0 kept, 0 replaced"
logged "already had these edits"

echo "3. applied to a boot package's tree patched by dt-tweaks.sh: everything in place"
apply $T/tweaked.dtb $T/out3.dtb
same $T/out3.dtb $T/tweaked.dtb
logged ": 0 applied, [0-9]* in place, 0 kept, 0 replaced"

echo "4. values set before the kernel: eMMC tuning kept, others replaced and logged"
SDC2=/soc@03000000/sdmmc@04022000 LEDC=/soc@03000000/ledc@0x05018000
cp $T/stock.dtb $T/uboot.dtb
fdtput -t x $T/uboot.dtb $SDC2 sdc_tm4_sm1_freq0 ff16ffff
fdtput -t u $T/uboot.dtb $LEDC led_count 5
apply $T/uboot.dtb $T/out4.dtb
logged "kept $SDC2 sdc_tm4_sm1_freq0"
logged "replaced $LEDC led_count"
logged " 1 kept, 1 replaced"
[ "$(fdtget -t x $T/out4.dtb $SDC2 sdc_tm4_sm1_freq0)" = ff16ffff ] || fail "tuning not kept"
[ "$(fdtget $T/out4.dtb $LEDC led_count)" = 14 ] || fail "led_count not replaced"

echo "5. a value read by dt-tweaks.sh differs (other firmware): nothing applied, failure recorded"
cp $T/stock.dtb $T/other.dtb
# dt-tweaks.sh reads this phandle with fdtget, so the table expects it.
fdtput -t u $T/other.dtb /soc@03000000/pinctrl@0300b000 phandle 4242
fdtput -t u $T/other.dtb /soc@03000000/pinctrl@0300b000 linux,phandle 4242
apply $T/other.dtb $T/out5.dtb 1
logged "failed: edit [0-9]* (expect /soc@03000000/pinctrl@0300b000 phandle): FDT_ERR_BADVALUE"
same $T/out5.dtb $T/other.dtb
case $(status $T/out5.dtb) in "failed: edit "*) ;; *) fail "status: $(status $T/out5.dtb)" ;; esac

echo "6. the recorder refuses what the kernel can't redo"
# refused 'COMMANDS': a dt-tweaks.sh of COMMANDS must not make a table.
refused() {
	printf '#!/bin/sh\nset -eu\nDTB=$1\n%s\n' "$1" >$T/bad-tweaks.sh && chmod +x $T/bad-tweaks.sh
	! DT_TWEAKS=$T/bad-tweaks.sh "$ROOT/tools/system/dt-edits.sh" "$PKG" $T/bad.c 2>$T/log ||
		fail "not refused: $1"
	[ ! -e $T/bad.c ] || fail "table written for: $1"
}
refused 'fdtput -t s "$DTB" /chosen bootargs x'
refused 'fdtput -t u "$DTB" /memory reg 0 0'
refused 'fdtput -r "$DTB" /brick-keys'
refused 'fdtput -t u "$DTB" /cpus/cpu@0 x "$(fdtget -l "$DTB" /cpus)"'

echo "7. trees captured from devices (build/dt-samples) apply"
for s in "$ROOT"/build/dt-samples/*.dtb; do
	[ -e "$s" ] || continue
	apply "$s" $T/sample.dtb
	sed "s|^|  ${s##*/}: |" $T/log
done
echo PASS
