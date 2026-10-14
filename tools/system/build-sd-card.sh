#!/bin/sh
# Build a live SD card image that runs one version of our system (build-system.sh's output).
# Layout as build_sd_image.sh describes, with the last partition "system": ext4, 1 GiB, holding
#   images/<version>/   that version's boot.img, rootfs.squashfs and manifest.json
#   state/  logs/       empty (see system/board/brick/initramfs/init)
# U-Boot's settings name it by filesystem UUID (root=UUID=...). The data partition is added over
# the rest of the card on first start (system/board/brick/rootfs-overlay/usr/libexec/brick/mount-card).
# Usage: build-sd-card.sh <system-version-dir> <out.img>
set -eu
V=$1 OUT=$2
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FW=$ROOT/build/stock-fw
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
VERSION=$(basename "$(readlink -f "$V")")

mkdir -p "$TMP/tree/images/$VERSION" "$TMP/tree/state" "$TMP/tree/logs"
cp "$V/boot.img" "$V/rootfs.squashfs" "$V/manifest.json" "$TMP/tree/images/$VERSION/"
UUID=$(python3 -I -c 'import uuid; print(uuid.uuid4())')
"$ROOT/tools/system/mkfs-system.sh" "$TMP/system.ext4" "$UUID" "$TMP/tree" 1024M

"$ROOT/tools/sdboot/patch-boot-package.sh" "$FW/boot_package.fex" "$TMP/boot_package.fex"
# Our boot logo (system/board/brick/logo) in place of TrimUI's.
python3 -I "$ROOT/tools/sdboot/replace-bootlogo.py" "$FW/boot-resource.fex" \
	"$ROOT/system/board/brick/logo/bootlogo.bmp" "$TMP/bootres.fat"
ROOT_NAME=system ROOT_REF=UUID=$UUID "$ROOT/tools/sdboot/build_sd_image.sh" "$OUT" \
	"$FW/boot0_sdcard.fex" "$TMP/boot_package.fex" "$FW/env.fex" "$V/boot.img" \
	"$TMP/bootres.fat" "$TMP/system.ext4"
