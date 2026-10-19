#!/bin/bash
# Tests the kernel's exFAT driver on the PC: boots our 4.9 kernel in QEMU (the "virt" board, with
# lock checking) on an initramfs made from the device's root filesystem (build/buildroot/target),
# whose init is test-exfat-guest.sh, against a 1 GiB virtual disk. Runs the functional and options
# phases, then ROUNDS power cuts (default 10): a boot that writes and saves until a forced reset
# 3-14 s in, as if the power were cut, then a boot that runs fsck.exfat -n and, if it finds errors,
# repairs with fsck.exfat -p as mount-card does.
# Fails on any failed check, a kernel warning (lockdep, BUG, oops), a save missing or not whole
# after a cut, a repair that doesn't leave the disk clean, or a guest still running after 5 minutes.
# Builds QEMU once with Buildroot's host-qemu (build/qemu, about 15 minutes), and the test kernel
# (trimui_brick_defconfig plus test-exfat.config) in build/test-exfat/kernel; a run after that
# takes about 4 minutes. Needs `make buildroot` first. Logs of the last run are in
# build/test-exfat/logs. Prints PASS or the first failure.
# Usage: test-exfat.sh       KERNEL_SRC overrides the kernel source tree (default linux/).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
B=$ROOT/build
BR_SRC=$(ls -d $B/buildroot-*/ 2>/dev/null | head -1)	# unpacked by make buildroot; builds QEMU too
TARGET=$B/buildroot/target
QEMU=$B/qemu/host/bin/qemu-system-aarch64
W=$B/test-exfat
K=$W/kernel
L=$W/logs
ROUNDS=${ROUNDS:-10}
[ -d "$TARGET/usr/sbin" ] && [ -x "$TARGET/usr/sbin/fsck.exfat" ] && [ -n "$BR_SRC" ] ||
	{ echo "needs the device's root filesystem with exfatprogs: run make buildroot first" >&2; exit 1; }
fail() { echo "FAIL: $*" >&2; exit 1; }

if [ ! -x $QEMU ]; then
	echo "building QEMU (once, about 15 minutes; log in $B/qemu/build.log)"
	mkdir -p $B/qemu
	printf 'BR2_aarch64=y\nBR2_PACKAGE_HOST_QEMU=y\nBR2_PACKAGE_HOST_QEMU_SYSTEM_MODE=y\n' >$B/qemu/defconfig
	br() { make -C $BR_SRC O=$B/qemu BR2_DL_DIR=$B/downloads/buildroot "$@" >>$B/qemu/build.log 2>&1; }
	br BR2_DEFCONFIG=$B/qemu/defconfig defconfig && br host-qemu ||
		fail "building QEMU; see $B/qemu/build.log"
	rm -rf $B/qemu/build	# about 3.5 GB of build files; QEMU runs from build/qemu/host
fi

echo "building the test kernel"
mkdir -p $K
{ "$ROOT/tools/kmake.sh" $K trimui_brick_defconfig &&
	cat "$ROOT/tools/system/test-exfat.config" >>$K/.config &&
	"$ROOT/tools/kmake.sh" $K olddefconfig && "$ROOT/tools/kmake.sh" $K Image; } >$W/kernel.log 2>&1 ||
	fail "building the kernel; see $W/kernel.log"
# olddefconfig drops an option whose dependencies aren't met; without this one nothing is checked.
grep -q '^CONFIG_PROVE_LOCKING=y' $K/.config || fail "the test kernel has no lock checking"

# The initramfs: the root filesystem, then the test's files and /dev/console (which the kernel
# opens for init's output before devtmpfs is mounted) in a second archive.
rm -rf $L; mkdir -p $L
$B/buildroot/host/bin/aarch64-linux-gcc -O2 -Wall -Werror -o $W/test-exfat-io \
	"$ROOT/tools/system/test-exfat-io.c"
cat >$W/extra.list <<EOF
dir /dev 755 0 0
nod /dev/console 600 0 0 c 5 1
file /init $ROOT/tools/system/test-exfat-guest.sh 755 0 0
file /test-exfat-io $W/test-exfat-io 755 0 0
EOF
{ (cd $TARGET && find . | cpio -o -H newc --owner=0:0 --quiet); $K/usr/gen_init_cpio $W/extra.list; } |
	gzip -1 >$W/initrd.gz

# boot PHASE LOG: runs the guest's PHASE on $W/disk.img, its console to LOG; fails on a check
# that failed, a kernel warning, or a guest that didn't get to the end (except "cut", which ends in
# a reset).
boot() {
	local rc=0
	# -no-reboot: the guest's reset (the power cut) or power-off ends QEMU.
	timeout 300 $QEMU -M virt -cpu cortex-a53 -smp 4 -m 1024 -nographic -no-reboot \
		-kernel $K/arch/arm64/boot/Image -initrd $W/initrd.gz \
		-append "console=ttyAMA0 rdinit=/init test=$1 panic=-1" \
		-drive file=$W/disk.img,if=none,format=raw,id=d0,cache=unsafe \
		-device virtio-blk-device,drive=d0 </dev/null 2>&1 | tr -d '\r' >$2 || rc=$?
	[ $rc = 0 ] || fail "$1: QEMU exited $rc (124: still running after 5 minutes; log: $2)"
	! grep -E "^FAIL" $2 || fail "$1 (log: $2)"
	! grep -E "WARNING: |BUG: |Oops|Unable to handle|circular locking|INFO: possible|inconsistent lock" $2 ||
		fail "kernel warning in $1 (log: $2)"
	[ $1 = cut ] && { grep -q "cutting power" $2 || fail "cut didn't start (log: $2)"; return; }
	grep -q "^TEST: done" $2 || fail "$1 didn't finish (log: $2)"
}

rm -f $W/disk.img; truncate -s 1G $W/disk.img
echo "functional"; boot functional $L/functional.log
echo "options"; boot options $L/options.log
for i in $(seq $ROUNDS); do
	boot cut $L/cut$i.log
	boot after-cut $L/after-cut$i.log
	grep -q "^ok last save whole" $L/after-cut$i.log || fail "no save after cut $i (log: $L/after-cut$i.log)"
	echo "power cut $i/$ROUNDS: $(grep -h '^TEST: \(cutting\|fsck\)' $L/cut$i.log $L/after-cut$i.log |
		sed 's/^TEST: //' | paste -sd ';' | sed 's/;/; /g')"
	if grep -q "fsck.exfat -p exit" $L/after-cut$i.log; then
		grep -q "fsck.exfat -p exit [01]$" $L/after-cut$i.log || fail "repair after cut $i (log: $L/after-cut$i.log)"
	fi
done
echo PASS
