#!/bin/sh
# Build ARM's Mali kernel driver (mali_kbase.ko) for the mainline kernel: the optional alternative
# to Panfrost, needed by ARM's own GL ES and Vulkan libraries (libmali). Only one of the two can
# drive the GPU; the device's setting picks which loads at start-up.
# Source: $MALI_KBASE_SRC (tools/env.sh). It is mirrored into build/mainline/mali/src and built
# there, so the source tree stays clean. CONFIG_MALI_PLATFORM_NAME=devicetree: clocks, regulators
# and power domains come from the device tree's GPU node, as ROCKNIX builds it for Rockchip boards.
# The kernel at build/mainline/kernel must already be built (make DEVICE=<board> kernel).
# Result: build/mainline/mali/mali_kbase.ko.
# Usage: build-mali.sh [extra make args, e.g. V=1]
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/tools/env.sh"
OUT=$ROOT/build/mainline/mali
SRC=$OUT/src
mkdir -p "$SRC"
rsync -a --delete --exclude='*.o' --exclude='*.ko' --exclude='*.cmd' --exclude='*.mod*' \
	--exclude=modules.order --exclude=Module.symvers "$MALI_KBASE_SRC/" "$SRC/"
"$ROOT/tools/mainline/kmake.sh" "$ROOT/build/mainline/kernel" M="$SRC/drivers/gpu/arm/midgard" \
	CONFIG_MALI_MIDGARD=m CONFIG_MALI_PLATFORM_NAME=devicetree CONFIG_MALI_REAL_HW=y modules "$@"
cp "$SRC/drivers/gpu/arm/midgard/mali_kbase.ko" "$OUT/"
