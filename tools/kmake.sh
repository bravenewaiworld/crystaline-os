#!/bin/sh
# Run make for our 4.9 kernel (Allwinner's vendor kernel, linux/) with the right cross compiler.
# Usage: kmake.sh <build-dir> [make args...]     KERNEL_SRC overrides the source tree.
# Host flags for building the 2019-era host tools (dtc, kconfig) with a modern GCC:
# -fcommon accepts dtc's duplicate global definitions; -std=gnu11 avoids the newer C23 default.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/env.sh"
SRC=${KERNEL_SRC:-$ROOT/linux}
mkdir -p "$1"; OUT=$(realpath "$1"); shift
exec make -C "$SRC" O="$OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" HOSTCFLAGS="-fcommon -std=gnu11" -j"$(nproc)" "$@"
