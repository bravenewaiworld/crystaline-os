#!/bin/sh
# Build an SD card image for a mainline board that runs one version of our system (build-system.sh's
# output for the mainline family). Laid out like the Brick's card (two boot slots switched by
# U-Boot's settings), in 512-byte sectors, then MiB:
#   0-33        protective MBR, GPT header and entries
#   64-32767    the loader (tools/mainline/build-loader.sh), where the RK3566's boot ROM looks for it
#   16 MiB      "env", "env-redund": U-Boot's settings, two copies of 128 KiB, at the places the
#               board's U-Boot configuration names (CONFIG_ENV_OFFSET, CONFIG_ENV_OFFSET_REDUND)
#   17 MiB      "boot_a": this version's boot.img (a FAT image U-Boot starts from: parts-mainline.sh)
#   81 MiB      "boot_b": the second boot slot, written by the first update
#   145 MiB     "system": ext4, 1 GiB, as on the Brick (tools/system/build-sd-card.sh):
#                 images/<version>/   that version's files (boot.img, rootfs.squashfs, manifest)
#                 state/  logs/       empty (see system/common/initramfs/init)
# U-Boot's settings start from its own built-in ones (it uses the card's whole), plus
# boot_partition=boot_a and mmc_root, the system partition's filesystem UUID, which boot.img's
# extlinux.conf passes on (root=, crystaline.boot=). The games partition is added over the rest of
# the card on first start (system/common/rootfs-overlay/usr/libexec/crystaline/mount-card).
# Usage: build-card.sh <system-version-dir> <board's DTB, as in its board.mk> <loader-dir> <out.img>
#   loader-dir: build-loader.sh's output (u-boot-rockchip.bin, u-boot-initial-env)
set -eu
V=$1 DTB=$2 LOADER=$3 OUT=$4
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
VERSION=$(basename "$(readlink -f "$V")")
MiB=2048	# sectors
ENV_AT=16 ENV_KiB=128 BOOTA_AT=17 BOOTB_AT=81 BOOT_MiB=64 SYSTEM_AT=145
ENV_SECTORS=$((ENV_KiB * 2))

[ -f "$V/boot.img" ] || { echo "$V has no boot.img" >&2; exit 1; }
MTOOLS_SKIP_CHECK=1 mdir -i "$V/boot.img" "::dtbs/$DTB" >/dev/null 2>&1 ||
	{ echo "$V/boot.img has no device tree $DTB" >&2; exit 1; }
[ "$(stat -c%s "$V/boot.img")" -le $((BOOT_MiB * 1048576)) ] ||
	{ echo "$V/boot.img is bigger than a boot slot ($BOOT_MiB MiB)" >&2; exit 1; }
for f in u-boot-rockchip.bin u-boot-initial-env; do
	[ -f "$LOADER/$f" ] || { echo "no $LOADER/$f (make DEVICE=<board> loader)" >&2; exit 1; }
done
[ "$(stat -c%s "$LOADER/u-boot-rockchip.bin")" -le $(( (ENV_AT * MiB - 64) * 512 )) ] ||
	{ echo "$LOADER/u-boot-rockchip.bin doesn't fit before U-Boot's settings at $ENV_AT MiB" >&2; exit 1; }
# U-Boot's configuration must put its settings where this layout does.
for o in "CONFIG_ENV_OFFSET=$(printf 0x%x $((ENV_AT * 1048576)))" \
	"CONFIG_ENV_OFFSET_REDUND=$(printf 0x%x $((ENV_AT * 1048576 + ENV_KiB * 1024)))" \
	"CONFIG_ENV_SIZE=$(printf 0x%x $((ENV_KiB * 1024)))"; do
	grep -qx "$o" "$LOADER/u-boot/.config" ||
		{ echo "the loader's U-Boot hasn't $o (this card's layout)" >&2; exit 1; }
done

# The system partition, with this version in images/.
mkdir -p "$TMP/tree/images" "$TMP/tree/state" "$TMP/tree/logs"
cp -R "$(readlink -f "$V")" "$TMP/tree/images/$VERSION"
UUID=$(python3 -I -c 'import uuid; print(uuid.uuid4())')
LABEL=crystaline-sys "$ROOT/tools/system/mkfs-system.sh" "$TMP/system.ext4" "$UUID" "$TMP/tree" 1024M
SYSTEM_MiB=$(( ($(stat -c%s "$TMP/system.ext4") + 1048575) / 1048576 + 16 ))	# +16 MiB headroom

# U-Boot's settings; both copies alike (U-Boot then uses env).
python3 -I "$ROOT/tools/sdboot/mkenv.py" "text:$LOADER/u-boot-initial-env" "$TMP/env" $((ENV_KiB * 1024)) \
	"mmc_root=UUID=$UUID" boot_partition=boot_a >/dev/null

# The card: loader, partition table, then everything in place.
rm -f "$OUT"; truncate -s $((SYSTEM_AT + SYSTEM_MiB + 1))M "$OUT"	# +1 MiB for the backup GPT
put() { dd if="$1" of="$OUT" bs=512 seek="$2" conv=notrunc status=none; }
put "$LOADER/u-boot-rockchip.bin" 64
sfdisk --quiet --no-reread --no-tell-kernel "$OUT" <<EOF
label: gpt
first-lba: $((ENV_AT * MiB))
start=$((ENV_AT * MiB)), size=$ENV_SECTORS, name=env
start=$((ENV_AT * MiB + ENV_SECTORS)), size=$ENV_SECTORS, name=env-redund
start=$((BOOTA_AT * MiB)), size=$((BOOT_MiB * MiB)), name=boot_a
start=$((BOOTB_AT * MiB)), size=$((BOOT_MiB * MiB)), name=boot_b
start=$((SYSTEM_AT * MiB)), size=$((SYSTEM_MiB * MiB)), name=system
EOF
put "$TMP/env" $((ENV_AT * MiB))
put "$TMP/env" $((ENV_AT * MiB + ENV_SECTORS))
put "$V/boot.img" $((BOOTA_AT * MiB))
dd if="$TMP/system.ext4" of="$OUT" bs=1M seek=$SYSTEM_AT conv=notrunc status=none
echo "$OUT: version $VERSION, system partition UUID $UUID"
