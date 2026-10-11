#!/bin/sh
# Update the SD test card inside a running Brick over adb, instead of rewriting the card in a PC.
# Copies three areas from a freshly built card image (build-test-card.sh), then reboots at once:
# - the boot package (Allwinner's TOC1 container with U-Boot, firmware and the device tree, at
#   sector 32800 where the first-stage loader looks for it);
# - the "boot" partition (kernel);
# - the "rootfs" partition, so the system (including kernel modules, which must match the kernel)
#   is exactly what was built.
# The card's partition table and user-data partition (with the system-state image,
# .system-state.img, on it) are left alone; the
# areas are staged on the user-data partition (they don't fit in RAM).
# Usage: update-card.sh <card.img>
set -eu
IMG=$1
PKG_SECTOR=32800
PKG_SECTORS=8160       # up to the first partition at sector 40960
STAGE=/mnt/SDCARD/.card-update
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# part NAME: print the start and size (in sectors) of the image's partition NAME.
part() {
	sfdisk -d "$IMG" | sed -n "s/.*start= *\([0-9]*\), size= *\([0-9]*\),.*name=\"$1\".*/\1 \2/p"
}
BOOT=$(part boot) ROOTFS=$(part rootfs)
[ -n "$BOOT" ] && [ -n "$ROOTFS" ] || { echo "no boot or rootfs partition in $IMG" >&2; exit 1; }
set -- $BOOT $ROOTFS			# $1 $2: boot start, size; $3 $4: rootfs start, size
dd if="$IMG" of="$TMP/pkg" bs=512 skip=$PKG_SECTOR count=$PKG_SECTORS status=none
dd if="$IMG" of="$TMP/boot" bs=512 skip="$1" count="$2" status=none
dd if="$IMG" of="$TMP/rootfs" bs=512 skip="$3" count="$4" status=none
# Check the boot package first: U-Boot's work_mode setting in it must be 0 (normal boot); any
# other value starts the vendor's flasher instead of booting.
python3 -I "$(dirname "$0")/../sdboot/toc1.py" "$TMP/pkg" >/dev/null ||
	{ echo "refusing: the image's boot package is invalid or not in normal-boot mode" >&2; exit 1; }

# The on-device part. Writes only if: exactly one partition each is named "boot" and "rootfs"
# (the test kernel doesn't enable the internal eMMC, which has them too, so two means something
# unexpected); the system runs from that rootfs partition, mounted read-only (it is replaced while
# mounted, then the device reboots at once); and the card's layout fits the image. Prints UPDATED
# only if it wrote: adb doesn't pass the exit status back.
cat >"$TMP/apply" <<'EOF'
set -u
D=$1 BOOT_SECTORS=$2 ROOT_SECTORS=$3 PKG_SECTOR=$4 PKG_END=$5
trap 'rm -rf $D' EXIT		# the staged copies, whether or not they get written
only() { set -- $(grep -l "^PARTNAME=$1\$" /sys/class/block/*/uevent); [ $# -eq 1 ] &&
	basename "$(dirname "$1")"; }
boot=$(only boot) && root=$(only rootfs) ||
	{ echo "refusing: not exactly one boot and one rootfs partition"; exit 1; }
disk=${boot%p*}				# mmcblk0p4 -> mmcblk0
# the root filesystem's device number (major:minor) must be the rootfs partition's
[ "$(awk '$5 == "/" {print $3}' /proc/self/mountinfo)" = "$(cat /sys/class/block/$root/dev)" ] ||
	{ echo "refusing: the system isn't running from $root"; exit 1; }
grep -q ' / ext4 ro[, ]' /proc/mounts || mount -o remount,ro / 2>/dev/null ||
	{ echo "refusing: root filesystem is read-write and can't be made read-only"; exit 1; }
[ "$(cat /sys/class/block/$boot/size)" -ge "$BOOT_SECTORS" ] &&
	[ "$(cat /sys/class/block/$root/size)" -ge "$ROOT_SECTORS" ] ||
	{ echo "refusing: boot or rootfs partition too small"; exit 1; }
[ "$(cat /sys/class/block/${disk}p1/start)" -ge "$PKG_END" ] ||
	{ echo "refusing: first partition overlaps the boot package area"; exit 1; }
dd if=$D/pkg of=/dev/$disk bs=512 seek=$PKG_SECTOR 2>/dev/null &&
	dd if=$D/boot of=/dev/$boot bs=1M 2>/dev/null &&
	dd if=$D/rootfs of=/dev/$root bs=1M 2>/dev/null || { echo "write failed"; exit 1; }
rm -rf $D
sync
echo "UPDATED $disk (boot package), $boot (kernel) and $root (system); rebooting"
echo b >/proc/sysrq-trigger	# reboot now: the mounted root filesystem was just replaced
reboot -f			# in case the kernel has the sysrq trigger disabled
EOF

adb shell "grep -q ' /mnt/SDCARD ' /proc/mounts && mkdir -p $STAGE && echo ready" | grep -q ready ||
	{ echo "no adb device, or the user-data partition isn't mounted (with several adb devices," \
		"set ANDROID_SERIAL)" >&2; exit 1; }
for f in pkg boot rootfs apply; do adb push "$TMP/$f" "$STAGE/$f" >/dev/null; done
OUT=$(adb shell "sh $STAGE/apply $STAGE $2 $4 $PKG_SECTOR $((PKG_SECTOR + PKG_SECTORS))" | tr -d '\r')
echo "$OUT"
case $OUT in *UPDATED*) ;; *) exit 1 ;; esac
