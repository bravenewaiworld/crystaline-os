#!/usr/bin/env bash
# Build a TrimUI Brick (TG3040, A133P) SD-card image that boots the vendor boot0 + vendor
# U-Boot 2018.05 from the card. U-Boot doesn't touch the internal eMMC when booting from the card;
# whether the kernel sees it is up to the device tree (system/board/brick/dt-tweaks.sh enables it).
#
# Usage: build_sd_image.sh OUT.img BOOT0 BOOT_PACKAGE BASE_ENV BOOT_IMG BOOTLOADER_FAT [ROOTFS_IMG]
#   BOOT0          vendor boot0_sdcard.fex (Allwinner "eGON" first-stage loader, unmodified)
#   BOOT_PACKAGE   vendor boot_package.fex (see toc1.py); must be in normal-boot mode
#   BASE_ENV       vendor env.fex; rewritten here (root=, see below)
#   BOOT_IMG       Android v0 boot image, loaded by `sunxi_flash read 45000000 boot; bootm`
#   BOOTLOADER_FAT vendor boot-resource.fex (boot logo / battery images U-Boot reads by name)
#   ROOTFS_IMG     optional filesystem image for the "rootfs" partition
# Environment (both optional; for our system image, whose initramfs looks up root=UUID=... itself
# instead of the kernel mounting root=):
#   ROOT_NAME      the last partition's GPT name instead of "rootfs"
#   ROOT_REF       what U-Boot's settings pass the kernel as root= (default: PARTUUID=<that
#                  partition's random GPT UUID>)
#
# Layout, in 512-byte sectors:
#   0, 1, 2-5   protective MBR, GPT header, GPT entries (only 16 entries, so they end before boot0)
#   16          boot0 (byte offset 8 KiB: where the boot ROM looks first)
#   256         boot0 copy (byte offset 128 KiB: where it looks if the first copy is bad)
#   32800       boot package: fixed location hard-coded in vendor boot0 and U-Boot
#   40960+      GPT partitions. Vendor U-Boot adds 40960 sectors (20 MiB) to by-name partition
#               offsets, so anything below 20 MiB is unreachable.
set -euo pipefail
OUT=$1 BOOT0=$2 PKG=$3 BASE_ENV=$4 BOOTIMG=$5 BLFAT=$6 ROOTFS=${7:-}
TOOLS=$(dirname "$(readlink -f "$0")")
MiB=2048              # sectors
ENV_SIZE=0x20000      # vendor U-Boot's env size (mkenv.py checks it against BASE_ENV's CRC)

# Partition starts and sizes in MiB.
BL_AT=20   BL_MiB=24
ENV_AT=44  ENV_MiB=1
ENV2_AT=45
BOOT_AT=46 BOOT_MiB=64
ROOT_AT=110
ROOT_MiB=256          # default when no rootfs image is given
[ -n "$ROOTFS" ] && ROOT_MiB=$(( ($(stat -c%s "$ROOTFS") + 1048575) / 1048576 + 16 ))   # +16 MiB headroom

python3 -I "$TOOLS/toc1.py" "$PKG" >/dev/null || { echo "refusing: unsafe boot package $PKG" >&2; exit 1; }

rm -f "$OUT"; truncate -s $((ROOT_AT + ROOT_MiB + 1))M "$OUT"   # +1 MiB for the backup GPT
ROOT_UUID=$(python3 -I -c 'import uuid; print(uuid.uuid4())')
ROOT_NAME=${ROOT_NAME:-rootfs}
ROOT_REF=${ROOT_REF:-PARTUUID=$ROOT_UUID}
sfdisk --quiet --no-reread --no-tell-kernel "$OUT" <<GPT
label: gpt
table-length: 16
first-lba: 40960
start=$((BL_AT*MiB)),   size=$((BL_MiB*MiB)),   name=bootloader
start=$((ENV_AT*MiB)),  size=$((ENV_MiB*MiB)),  name=env
start=$((ENV2_AT*MiB)), size=$((ENV_MiB*MiB)),  name=env-redund
start=$((BOOT_AT*MiB)), size=$((BOOT_MiB*MiB)), name=boot
start=$((ROOT_AT*MiB)), size=$((ROOT_MiB*MiB)), name=$ROOT_NAME, uuid=$ROOT_UUID
GPT

# put FILE SECTOR MAX_SECTORS: write FILE at SECTOR, failing if it would spill past MAX_SECTORS.
put() {
	local size; size=$(stat -c%s "$1")
	(( size <= $3 * 512 )) || { echo "$1 is too big for its slot ($size > $(($3 * 512)) bytes)" >&2; exit 1; }
	dd if="$1" of="$OUT" bs=512 seek="$2" conv=notrunc status=none
}
put "$BOOT0" 16 240
put "$BOOT0" 256 32544
put "$PKG" 32800 8160
put "$BLFAT" $((BL_AT*MiB)) $((BL_MiB*MiB))
# root= set explicitly (ROOT_REF): U-Boot otherwise derives "root=/dev/mmcblk0pN", which assumes a device
# numbering our kernel may not share and could point at an eMMC partition. blkoops_partition
# names the eMMC crash-log partition, which doesn't exist on the card.
ENV=$(mktemp); trap 'rm -f "$ENV"' EXIT
python3 -I "$TOOLS/mkenv.py" "$BASE_ENV" "$ENV" $ENV_SIZE -root_partition -blkoops_partition \
	"mmc_root=$ROOT_REF" >/dev/null
# U-Boot keeps two copies and falls back to the second if the first fails its CRC.
put "$ENV" $((ENV_AT*MiB)) $((ENV_MiB*MiB))
put "$ENV" $((ENV2_AT*MiB)) $((ENV_MiB*MiB))
put "$BOOTIMG" $((BOOT_AT*MiB)) $((BOOT_MiB*MiB))
[ -n "$ROOTFS" ] && put "$ROOTFS" $((ROOT_AT*MiB)) $((ROOT_MiB*MiB))
echo "built $OUT ($ROOT_NAME: root=$ROOT_REF)"
