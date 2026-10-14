# Top-level build for the TrimUI Brick firmware. `make help` lists the targets.
# Everything is built into build/. Third-party inputs (cross compiler, GPU driver source, TrimUI's
# stock firmware) are set in tools/env.sh.

ROOT := $(CURDIR)
B := $(ROOT)/build
# $(call env,NAME): NAME's value from tools/env.sh (which keeps any value set in the environment).
env = $(shell ROOT='$(ROOT)' && . '$(ROOT)/tools/env.sh' && echo "$$$(1)")
CROSS_COMPILE := $(call env,CROSS_COMPILE)
STOCK_FW := $(call env,STOCK_FW)
export STAGING_DIR := $(call env,STAGING_DIR)

CC := $(CROSS_COMPILE)gcc
CFLAGS := -O2 -Wall -Wextra
# Static, so on-device tools don't depend on the device's libraries. This toolchain's static
# glibc also needs the unwinder (-lgcc_eh).
STATIC := -static -s -Wl,--start-group -lgcc -lgcc_eh -lc -Wl,--end-group

.PHONY: help all kernel gpu userspace specular cores device-tools buildroot system sd-card \
	update-device deploy-specular run-specular test-card update-card install-image clean

help:
	@echo 'Our system:'
	@echo '  system           one version of the system: build/system/<version>/ (boot.img,'
	@echo '                   rootfs.squashfs, manifest.json), also build/system/latest'
	@echo '  sd-card          build/sd-card.img: an SD card that runs the latest version'
	@echo '  update-device    build system, copy it to a Brick running our system, switch, reboot'
	@echo '                   (SSH; BRICK=<address>, default 192.168.7.2 over USB)'
	@echo '  deploy-specular  build Specular, replace it on the Brick and restart it (kept across'
	@echo '                   restarts until the next update-device)'
	@echo '  run-specular     build Specular and run it once in the foreground on the Brick'
	@echo 'Test card (TrimUI'"'"'s system with our kernel; being replaced by the above):'
	@echo '  test-card      development SD card: our kernel and services on TrimUI'"'"'s stock system'
	@echo '  update-card    build test-card, then write its kernel and boot files to the card in a'
	@echo '                 running Brick (adb)'
	@echo 'Parts:'
	@echo '  kernel  gpu  userspace  specular  cores  device-tools'
	@echo '  buildroot      the base system (C library, BusyBox, daemons) with Buildroot'
	@echo '  clean          remove build/ (keeps the test card'"'"'s SSH keys)'

all: test-card

install-image:
	@echo '$@: not available yet (see ROADMAP.md)'; exit 1

# --- Kernel and GPU driver ------------------------------------------------------------------
# Always run: the kernel's own build decides what is out of date.
kernel:
	@[ -f $(B)/kernel/.config ] || tools/kmake.sh $(B)/kernel trimui_brick_defconfig
	tools/kmake.sh $(B)/kernel Image modules

gpu: kernel
	tools/build-gpu.sh

# --- Base system (Buildroot) ------------------------------------------------------------------
# Buildroot, pinned to a long-term release and checked against the checksum it publishes. Our
# configuration and additions are in system/ (BR2_EXTERNAL); its output in $(B)/buildroot and
# downloads in $(B)/downloads/buildroot, both kept across `make clean` of Buildroot's own tree.
# Always run: Buildroot decides what is out of date.
BUILDROOT_VERSION := 2026.02.3
BUILDROOT_SHA256 := 5a59e7501b0b4ec52c41f4bfa79412320e0b37eae5f719605a258e8d0c6fc7fb
BUILDROOT_SRC := $(B)/buildroot-$(BUILDROOT_VERSION)
BR := $(MAKE) -C $(BUILDROOT_SRC) O=$(B)/buildroot BR2_EXTERNAL=$(ROOT)/system \
	BR2_DL_DIR=$(B)/downloads/buildroot

$(BUILDROOT_SRC)/.done:
	@mkdir -p $(B)/downloads
	curl -sSfL -o $(B)/downloads/buildroot-$(BUILDROOT_VERSION).tar.xz \
		https://buildroot.org/downloads/buildroot-$(BUILDROOT_VERSION).tar.xz
	echo '$(BUILDROOT_SHA256)  $(B)/downloads/buildroot-$(BUILDROOT_VERSION).tar.xz' | sha256sum -c --quiet
	tar xf $(B)/downloads/buildroot-$(BUILDROOT_VERSION).tar.xz -C $(B)
	@touch $@

# The configuration is regenerated from system/configs/brick_defconfig every time, so that file is
# the only place to change it. Buildroot doesn't rebuild a package whose options changed; that
# needs `make -C $(BUILDROOT_SRC) O=$(B)/buildroot <package>-dirclean` first.
buildroot: $(BUILDROOT_SRC)/.done
	$(BR) -s brick_defconfig
	$(BR)

# --- Userspace services -------------------------------------------------------------------
userspace: $(B)/userspace/padbridge

$(B)/userspace/padbridge: userspace/padbridge/padbridge.c
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -o $@ $< $(STATIC)

# --- Specular (the frontend) -----------------------------------------------------------------
# Always run: cargo decides what is out of date. Builds Specular for the Brick (the specular
# binary), the spike examples and the runtime's headless player (play) into $(B)/specular.
# Linked dynamically, unlike the tools: it loads TrimUI's GPU libraries and the emulator cores
# at runtime, which static glibc can't do. CC_aarch64_unknown_linux_gnu: the
# cross C compiler for crates that build C code (zstd), which would otherwise use the PC's.
specular:
	CARGO_TARGET_DIR=$(B)/specular CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=$(CC) CC_aarch64_unknown_linux_gnu=$(CC) \
		cargo build --release --target aarch64-unknown-linux-gnu \
		--manifest-path specular/Cargo.toml -p specular-brick -p specular-runtime --bins --examples

# The libretro cores Specular runs games with (mGBA), into $(B)/cores/aarch64. Always
# run: the cores' own builds decide what is out of date.
cores:
	tools/build-cores.sh

# --- Development tools that run on the device -----------------------------------------------
DEVICE_TOOLS := dispctl glspin rumble i2creg memreg status blkro
device-tools: $(addprefix $(B)/tools/,$(DEVICE_TOOLS))

# status: a stand-in frontend used on the test card until Specular is ready. It draws text with the
# kernel's 8x16 console font, extracted from the kernel source (linux/) into a header.
$(B)/include/font8x16.h: linux/lib/fonts/font_8x16.c
	@mkdir -p $(@D)
	sed -n '/^static const unsigned char fontdata_8x16/,/^};/p' $< | \
		sed '1s/.*/static const unsigned char font8x16[4096] = {/' > $@

$(B)/tools/status: tools/device/status.c $(B)/include/font8x16.h
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -I$(B)/include -o $@ $< $(STATIC)

$(B)/tools/%: tools/device/%.c
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -o $@ $< $(STATIC)

# glspin links TrimUI's GPU libraries, taken from the stock system. Their own dependencies are
# resolved on the device (--allow-shlib-undefined).
$(B)/tools/glspin: tools/device/glspin.c $(B)/stock-root/.done
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -o $@ $< -L$(B)/stock-root/usr/lib -lEGL -lGLESv2 -lm \
		-Wl,--allow-shlib-undefined -Wl,-rpath-link,$(B)/stock-root/usr/lib

# --- TrimUI's stock firmware, unpacked --------------------------------------------------------
$(B)/stock-fw/rootfs.fex: $(STOCK_FW)
	python3 -I tools/sdboot/awimg_unpack.py $< $(B)/stock-fw

# A marker file: the extracted files keep their original (older) dates, so make would otherwise
# see usr/lib as always out of date and extract again.
$(B)/stock-root/.done: $(B)/stock-fw/rootfs.fex
	@mkdir -p $(B)/stock-root/usr
	debugfs -R 'rdump /usr/lib $(B)/stock-root/usr' $< 2>/dev/null
	@touch $@

# --- Our system -----------------------------------------------------------------------------
# Always run: each build is a new version (named by time and git commit).
system: buildroot kernel gpu userspace device-tools specular cores $(B)/stock-root/.done
	tools/system/build-system.sh $(B)/system

sd-card: system
	tools/system/build-sd-card.sh $(B)/system/latest $(B)/sd-card.img

update-device: system
	tools/system/update-device.sh $(B)/system/latest

deploy-specular: specular
	tools/system/deploy-specular.sh $(B)/specular/aarch64-unknown-linux-gnu/release/specular

run-specular: specular
	tools/run-specular.sh $(B)/specular/aarch64-unknown-linux-gnu/release/specular

# --- Development test card ------------------------------------------------------------------
test-card: kernel gpu userspace device-tools specular cores $(B)/stock-fw/rootfs.fex
	tools/testcard/build-test-card.sh $(B)/stock-fw $(B)/test-card.img $(B)/kernel

update-card: test-card
	tools/testcard/update-card.sh $(B)/test-card.img

clean:
	@[ ! -d $(B) ] || find $(B) -mindepth 1 -maxdepth 1 ! -name ssh-host-keys -exec rm -rf {} +
