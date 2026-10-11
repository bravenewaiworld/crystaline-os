#!/bin/sh
# Build the PowerVR GE8300 kernel modules (pvrsrvkm.ko, dc_sunxi.ko) for our kernel.
# Usage: build-gpu.sh [extra make args, e.g. V=1]
#
# Source: $GPU_SRC (github.com/pocketforge-os/gpu-km-tsp; see env.sh): the kernel half of Imagination's
# driver kit (DDK) 1.19@6345021, retargeted to the Allwinner A133, for the GPU core whose ID
# ("BVNC") is 22.102.54.38. Its root Makefile is the Kbuild file; PVR_SYSTEM=sunxi_a133 selects
# config_kernel_sunxi_a133.{mk,h} and build/pvr-buildopts.mk. Those pin the build-options bitmask,
# which TrimUI's closed userspace libraries compare with the module's when they connect; if it
# differs, they refuse to run.
#
# The 4.9 kernel writes external-module objects next to the sources, so the tree is mirrored into
# build/gpu/src (without .git) and built there; the source tree stays clean.
# The kernel at build/kernel must already be built (Module.symvers is needed to resolve symbols).
# Results: build/gpu/pvrsrvkm.ko and build/gpu/dc_sunxi.ko (load pvrsrvkm first; dc_sunxi depends on it).
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/env.sh"
OUT=$ROOT/build/gpu
SRC=$OUT/src

mkdir -p "$SRC"
# Build outputs are excluded so --delete keeps them and reruns stay incremental.
rsync -a --delete --exclude=.git \
	--exclude='*.o' --exclude='*.ko' --exclude='*.cmd' --exclude='*.mod.c' \
	--exclude=modules.order --exclude=Module.symvers --exclude=.tmp_versions \
	"$GPU_SRC/" "$SRC/"

# CONFIG_DRM_IMG_ROGUE=m: the Kbuild file adds its modules to obj-$(CONFIG_DRM_IMG_ROGUE).
"$ROOT/tools/kmake.sh" "$ROOT/build/kernel" M="$SRC" \
	CONFIG_DRM_IMG_ROGUE=m PVR_SYSTEM=sunxi_a133 modules "$@"

cp "$SRC/pvrsrvkm.ko" "$SRC/dc_sunxi.ko" "$OUT/"
