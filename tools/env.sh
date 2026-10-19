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
# The OpenWrt gcc wrapper warns when this is unset; its value is unused.
: "${STAGING_DIR:=/tmp}"
export CROSS_COMPILE GPU_SRC DUFS STOCK_FW STAGING_DIR
