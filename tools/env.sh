# Settings shared by the build scripts and the Makefile. Sourced (not run), with ROOT set to the
# project root. Each can be overridden from the environment.
# The third-party inputs live in third-party/ (not in git); tools/fetch-third-party.sh fetches them.

# Cross compiler: the one in Creality's Sonic Pad SDK (github.com/CrealityTech/sonic_pad_os,
# prebuilt/gcc/linux-x86/aarch64/toolchain-sunxi-glibc), which targets the same chip family and
# vendor kernel.
: "${CROSS_COMPILE:=$ROOT/third-party/sonic-pad-toolchain/toolchain/bin/aarch64-openwrt-linux-gnu-}"
# GPU kernel driver source (github.com/pocketforge-os/gpu-km-tsp; see build-gpu.sh).
: "${GPU_SRC:=$ROOT/third-party/gpu-km-tsp}"
# TrimUI's stock firmware: the bootloaders, the GPU libraries, and the WiFi/Bluetooth firmware.
: "${STOCK_FW:=$ROOT/third-party/trimui-firmware-v1.1.1/trimui_tg3040.awimg}"
# dufs (github.com/sigoden/dufs), the WebDAV/web file server: the static aarch64 binary of its
# v0.46.0 release.
: "${DUFS:=$ROOT/third-party/dufs-v0.46.0/dufs}"
# Mainline boards' loaders (tools/mainline/build-loader.sh): U-Boot; open TF-A, at a commit after
# v2.15 for its fix to the RK3566's GPU after sleep (a934036098); and the device tree compiler TF-A
# builds its libfdt from (its contrib/dtc submodule, at the commit TF-A names).
: "${UBOOT_SRC:=$ROOT/third-party/u-boot-v2026.10}"
: "${TFA_SRC:=$ROOT/third-party/tf-a-d70b52de}"
: "${TFA_DTC_SRC:=$ROOT/third-party/dtc-8f48565e}"
# The RK3566's DDR init, the one closed part of its loader: Rockchip's binary
# (github.com/rockchip-linux/rkbin), the one ROCKNIX's 20260601 cards carry.
: "${RK3566_DDR:=$ROOT/third-party/rkbin/rk3566_ddr_1056MHz_v1.23.bin}"
# Empty: the RK3566 loader runs open TF-A. Set to a BL31 file to use that instead, e.g. Rockchip's
# closed one that ROCKNIX's cards carry: $ROOT/third-party/rkbin/rk3568_bl31_v1.45.elf.
: "${RK3566_BL31:=}"
# ARM's kernel driver for Mali Bifrost GPUs (mali_kbase), ROCKNIX's copy with its fixes for newer
# kernels (github.com/rocknix/mali_kbase): the optional alternative to Panfrost on mainline boards,
# for ARM's own GL ES and Vulkan libraries (tools/mainline/build-mali.sh).
: "${MALI_KBASE_SRC:=$ROOT/third-party/mali-kbase}"
# The OpenWrt gcc wrapper warns when this is unset; its value is unused.
: "${STAGING_DIR:=/tmp}"
export CROSS_COMPILE GPU_SRC DUFS STOCK_FW UBOOT_SRC TFA_SRC TFA_DTC_SRC RK3566_DDR RK3566_BL31 MALI_KBASE_SRC STAGING_DIR
