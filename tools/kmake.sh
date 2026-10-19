#!/bin/sh
# Run make for our 4.9 kernel (Allwinner's vendor kernel, linux/) with the right cross compiler.
# Usage: kmake.sh <build-dir> [make args...]     KERNEL_SRC overrides the source tree.
# Host flags for building the 2019-era host tools (dtc, kconfig) with a modern GCC:
# -fcommon accepts dtc's duplicate global definitions; -std=gnu11 avoids the newer C23 default.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/env.sh"
SRC=${KERNEL_SRC:-$ROOT/linux}
mkdir -p "$1"; OUT=$(realpath "$1"); shift
# The device-tree edits the kernel applies at boot, made from dt-tweaks.sh and the device tree in
# TrimUI's boot package, as <build-dir>/dt-edits.c (trimui_brick_defconfig's CONFIG_OF_EDITS_TABLE).
# Made for every call, so every call needs build/stock-fw.
PKG=$ROOT/build/stock-fw/boot_package.fex
[ -f "$PKG" ] || { echo "kmake.sh: $PKG is missing; 'make stock-fw' unpacks it" >&2; exit 1; }
"$ROOT/tools/system/dt-edits.sh" "$PKG" "$OUT/dt-edits.c" || exit 1
exec make -C "$SRC" O="$OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" HOSTCFLAGS="-fcommon -std=gnu11" -j"$(nproc)" "$@"
