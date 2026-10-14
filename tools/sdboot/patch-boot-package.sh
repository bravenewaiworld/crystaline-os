#!/bin/sh
# Apply our device-tree changes (system/board/brick/dt-tweaks.sh) to a boot package. The kernel
# receives the device tree inside the boot package (boot_package.fex: Allwinner's container for
# U-Boot, firmware and the device tree; see toc1.py), so it is patched there.
# Usage: patch-boot-package.sh <boot_package.fex> <out>
set -eu
IN=$1 OUT=$2
TOOLS=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
python3 -I "$TOOLS/toc1.py" "$IN" 0 "$TMP/pkg" >/dev/null   # 0 = byte offset in the file
"$TOOLS/../../system/board/brick/dt-tweaks.sh" "$TMP/pkg/dtb.bin"
# fdtput drops the spare space U-Boot needs for its boot-time additions; dtc -p puts it back.
dtc -q -I dtb -O dtb -p 16384 -o "$TMP/dtb.padded" "$TMP/pkg/dtb.bin"
python3 -I "$TOOLS/toc1.py" repack "$IN" "$OUT" dtb="$TMP/dtb.padded"
