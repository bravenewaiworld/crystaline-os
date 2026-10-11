# Settings shared by the build scripts and the Makefile. Sourced (not run), with ROOT set to the
# project root. Each can be overridden from the environment.
# The third-party inputs still live in .scratch/ until the build fetches them itself.

# Cross compiler: the one in Creality's Sonic Pad SDK (github.com/CrealityTech/sonic_pad_os),
# which targets the same chip family and vendor kernel.
: "${CROSS_COMPILE:=$ROOT/.scratch/src/sonic_pad_os/prebuilt/gcc/linux-x86/aarch64/toolchain-sunxi-glibc/toolchain/bin/aarch64-openwrt-linux-gnu-}"
# GPU kernel driver source (github.com/pocketforge-os/gpu-km-tsp; see build-gpu.sh).
: "${GPU_SRC:=$ROOT/.scratch/src/gpu-km-tsp}"
# TrimUI's stock firmware: the bootloaders, and (for the test card) the stock system.
: "${DUFS:=$ROOT/.scratch/src/dufs-v0.46.0/dufs}"	# WebDAV/web file server, static aarch64 build
: "${STOCK_FW:=$ROOT/.scratch/TG3040_Brick_firmware_v1.1.1/trimui_tg3040.awimg}"
# The OpenWrt gcc wrapper warns when this is unset; its value is unused.
: "${STAGING_DIR:=/tmp}"
export CROSS_COMPILE GPU_SRC DUFS STOCK_FW STAGING_DIR
