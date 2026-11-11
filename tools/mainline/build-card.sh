#!/bin/sh
# Build an SD card image for a mainline board that runs one version of our system (build-system.sh's
# output for the mainline family). Layout, in 512-byte sectors:
#   0-33        protective MBR, GPT header and entries
#   64-32767    the first-stage loader and U-Boot (RK3566_UBOOT, tools/env.sh), where the RK3566's
#               boot ROM and that loader look for them
#   16 MiB      "bootloader": FAT32, 256 MiB, the partition U-Boot reads (marked legacy-BIOS-
#               bootable, which U-Boot's distro boot looks for): extlinux/extlinux.conf and a/ (this
#               version's kernel, initramfs and device trees); b/, the second boot slot, is made
#               by the first update
#   then        "system": ext4, 1 GiB, as on the Brick (tools/system/build-sd-card.sh):
#                 images/<version>/   that version's files (boot files, rootfs.squashfs, manifest)
#                 state/  logs/       empty (see system/common/initramfs/init)
# The initramfs finds the system partition by the filesystem UUID extlinux.conf passes it
# (root=UUID=...). The games partition is added over the rest of the card on first start
# (system/common/rootfs-overlay/usr/libexec/crystaline/mount-card), as on the Brick.
# Usage: build-card.sh <system-version-dir> <board's DTB, as in its board.mk> <out.img>
set -eu
V=$1 DTB=$2 OUT=$3
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/tools/env.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
VERSION=$(basename "$(readlink -f "$V")")
MiB=2048	# sectors
BOOT_AT=16 BOOT_MiB=256

[ -f "$V/dtbs/$DTB" ] || { echo "$V has no device tree $DTB" >&2; exit 1; }
[ -f "$RK3566_UBOOT" ] || { echo "no U-Boot: $RK3566_UBOOT (tools/env.sh, RK3566_UBOOT)" >&2; exit 1; }

# The system partition, with this version in images/.
mkdir -p "$TMP/tree/images" "$TMP/tree/state" "$TMP/tree/logs"
cp -R "$(readlink -f "$V")" "$TMP/tree/images/$VERSION"
UUID=$(python3 -I -c 'import uuid; print(uuid.uuid4())')
LABEL=crystaline-sys "$ROOT/tools/system/mkfs-system.sh" "$TMP/system.ext4" "$UUID" "$TMP/tree" 1024M
SYSTEM_MiB=$(( ($(stat -c%s "$TMP/system.ext4") + 1048575) / 1048576 + 16 ))	# +16 MiB headroom

# The boot partition. In APPEND:
# - crystaline.boot=a: the slot, for the initramfs's log and the installer;
# - the serial console (1,500,000 baud on the RK3566) and the screen; the screen is last, so it is
#   /dev/console;
# - a 1 MiB kernel log buffer, and only warnings and worse on the consoles, as on the Brick;
# - panic=10: restart 10 s after a panic; the kernel's log of it survives in RAM (ramoops) and the
#   next start saves it in /system/logs/crash-*/.
mkdir -p "$TMP/boot/extlinux" "$TMP/boot/a"
cp "$V/Image" "$V/initramfs.cpio.gz" "$TMP/boot/a/"
cp -R "$V/dtbs" "$TMP/boot/a/"
cat >"$TMP/boot/extlinux/extlinux.conf" <<EOF
# Written by tools/mainline/build-card.sh; an update switches DEFAULT between the slots a and b.
DEFAULT a
LABEL a
  LINUX /a/Image
  INITRD /a/initramfs.cpio.gz
  FDT /a/dtbs/$DTB
  APPEND root=UUID=$UUID crystaline.boot=a console=ttyS2,1500000 console=tty0 log_buf_len=1M loglevel=4 panic=10
EOF
mkfs.vfat -C -F 32 -n BOOT "$TMP/boot.fat" $((BOOT_MiB * 1024)) >/dev/null
MTOOLS_SKIP_CHECK=1 mcopy -s -i "$TMP/boot.fat" "$TMP/boot/extlinux" "$TMP/boot/a" ::/

# The card: loader, partition table, then both filesystems in place.
SYSTEM_AT=$((BOOT_AT + BOOT_MiB))
rm -f "$OUT"; truncate -s $((SYSTEM_AT + SYSTEM_MiB + 1))M "$OUT"	# +1 MiB for the backup GPT
dd if="$RK3566_UBOOT" of="$OUT" bs=512 skip=64 seek=64 count=$((BOOT_AT * MiB - 64)) conv=notrunc status=none
sfdisk --quiet --no-reread --no-tell-kernel "$OUT" <<EOF
label: gpt
first-lba: $((BOOT_AT * MiB))
start=$((BOOT_AT * MiB)), size=$((BOOT_MiB * MiB)), type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name=bootloader, attrs=LegacyBIOSBootable
start=$((SYSTEM_AT * MiB)), size=$((SYSTEM_MiB * MiB)), name=system
EOF
dd if="$TMP/boot.fat" of="$OUT" bs=1M seek=$BOOT_AT conv=notrunc status=none
dd if="$TMP/system.ext4" of="$OUT" bs=1M seek=$SYSTEM_AT conv=notrunc status=none
echo "$OUT: version $VERSION, system partition UUID $UUID"
