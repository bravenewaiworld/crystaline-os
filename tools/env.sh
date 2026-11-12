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
# The RK3566 boards' first-stage loader and U-Boot (Rockchip's DDR init, TF-A and ROCKNIX's
# "generic" U-Boot, which picks the board's device tree itself), until we build our own: the first
# 16 MiB of a ROCKNIX 20260601 card for these boards (dd if=<card> bs=1M count=16), whose sectors 64
# to 32767 hold them. No download address: put it in place by hand (it is checked).
: "${RK3566_UBOOT:=$ROOT/third-party/rocknix-uboot-20260601/first16M.img}"
# ARM's kernel driver for Mali Bifrost GPUs (mali_kbase), ROCKNIX's copy with its fixes for newer
# kernels (github.com/rocknix/mali_kbase): the optional alternative to Panfrost on mainline boards,
# for ARM's own GL ES and Vulkan libraries (tools/mainline/build-mali.sh).
: "${MALI_KBASE_SRC:=$ROOT/third-party/mali-kbase}"
# The RTL8723DS's Bluetooth firmware and its UART settings (rtl8723ds_fw.bin, rtl8723ds_config.bin),
# from Armbian's firmware collection (github.com/armbian/firmware, rtl_bt/): the RGB20 Pro's
# Bluetooth, which linux-firmware has no files for.
: "${RTL8723DS_BT:=$ROOT/third-party/rtl8723ds-bt}"
# The OpenWrt gcc wrapper warns when this is unset; its value is unused.
: "${STAGING_DIR:=/tmp}"
export CROSS_COMPILE GPU_SRC DUFS STOCK_FW RK3566_UBOOT MALI_KBASE_SRC RTL8723DS_BT STAGING_DIR
