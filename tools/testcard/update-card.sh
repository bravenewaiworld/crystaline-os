#!/bin/sh
# Update the SD test card inside a running Brick over adb, instead of rewriting the card in a PC.
# Copies two areas from a freshly built card image (build-test-card.sh): the boot package
# (Allwinner's TOC1 container with U-Boot, firmware and the device tree, at sector 32800 where the
# first-stage loader looks for it) and the "boot" partition (kernel), then reboots. The root filesystem isn't touched: it's mounted on the Brick while running.
# Usage: update-card.sh <card.img>
set -eu
IMG=$1
PKG_SECTOR=32800
PKG_SECTORS=8160       # up to the first partition at sector 40960
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Boot partition location in the image, from its partition table.
BOOT=$(sfdisk -d "$IMG" | sed -n 's/.*start= *\([0-9]*\), size= *\([0-9]*\),.*name="boot".*/\1 \2/p')
[ -n "$BOOT" ] || { echo "no boot partition in $IMG" >&2; exit 1; }
set -- $BOOT
dd if="$IMG" of="$TMP/pkg" bs=512 skip=$PKG_SECTOR count=$PKG_SECTORS status=none
dd if="$IMG" of="$TMP/boot" bs=512 skip="$1" count="$2" status=none
# Its U-Boot work_mode must be 0: anything else starts the vendor flasher.
python3 -I "$(dirname "$0")/../sdboot/toc1.py" "$TMP/pkg" >/dev/null ||
	{ echo "refusing: the image's boot package is invalid or not in normal-boot mode" >&2; exit 1; }

adb push "$TMP/pkg" /tmp/card-pkg >/dev/null
adb push "$TMP/boot" /tmp/card-boot >/dev/null
# On the Brick: write only if exactly one partition is named "boot" (the test kernel doesn't
# enable the internal eMMC, which has one too, so two means something unexpected), it is on the
# disk we booted from, and the card's layout matches the image's (boot partition big enough,
# first partition after the boot package). The device prints UPDATED only if it wrote; adb doesn't
# pass the exit status back.
OUT=$(adb shell "
	trap 'rm -f /tmp/card-pkg /tmp/card-boot' EXIT
	set -- \$(grep -l '^PARTNAME=boot\$' /sys/class/block/*/uevent)
	[ \$# -eq 1 ] || { echo 'refusing: not exactly one boot partition'; exit 1; }
	part=\$(basename \$(dirname \$1)); disk=\${part%p*}   # mmcblkNpM -> mmcblkN
	# The root filesystem's device number must be one of this disk's partitions.
	root=\$(awk '\$5 == \"/\" {print \$3}' /proc/self/mountinfo)
	grep -qx \"\$root\" /sys/class/block/\${disk}p*/dev ||
		{ echo \"refusing: \$disk is not the card the system runs from\"; exit 1; }
	[ \$(cat /sys/class/block/\$part/size) -ge $2 ] || { echo 'refusing: boot partition too small'; exit 1; }
	[ \$(cat /sys/class/block/\${disk}p1/start) -ge $((PKG_SECTOR + PKG_SECTORS)) ] ||
		{ echo 'refusing: first partition overlaps the boot package area'; exit 1; }
	dd if=/tmp/card-pkg of=/dev/\$disk bs=512 seek=$PKG_SECTOR || exit 1
	dd if=/tmp/card-boot of=/dev/\$part bs=512 || exit 1
	sync
	echo \"UPDATED \$disk (boot package) and \$part (kernel); rebooting\"
	reboot
" | tr -d '\r')
echo "$OUT"
case $OUT in *UPDATED*) ;; *) exit 1 ;; esac
