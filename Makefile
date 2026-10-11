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

.PHONY: help all kernel gpu userspace frontend device-tools test-card update-card live-image \
	install-image clean

help:
	@echo 'Images:'
	@echo '  live-image     SD card that runs our system (not available yet)'
	@echo '  install-image  SD card that installs our system to internal storage (not available yet)'
	@echo '  test-card      development SD card: our kernel and services on TrimUI'"'"'s stock system'
	@echo '  update-card    build test-card, then write its kernel and boot files to the card in a'
	@echo '                 running Brick (adb)'
	@echo 'Parts:'
	@echo '  kernel  gpu  userspace  frontend  device-tools'
	@echo '  clean          remove build/ (keeps the test card'"'"'s SSH keys)'

all: test-card

live-image install-image:
	@echo '$@: not available yet; it needs our own system image (see ROADMAP.md)'; exit 1

# --- Kernel and GPU driver ------------------------------------------------------------------
# Always run: the kernel's own build decides what is out of date.
kernel:
	@[ -f $(B)/kernel/.config ] || tools/kmake.sh $(B)/kernel trimui_brick_defconfig
	tools/kmake.sh $(B)/kernel Image modules

gpu: kernel
	tools/build-gpu.sh

# --- Userspace services -------------------------------------------------------------------
userspace: $(B)/userspace/padbridge

$(B)/userspace/padbridge: userspace/padbridge/padbridge.c
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -o $@ $< $(STATIC)

# --- Frontend ----------------------------------------------------------------------------------
frontend: $(B)/frontend/status

# The placeholder frontend draws text with the kernel's 8x16 console font.
$(B)/frontend/font8x16.h: linux/lib/fonts/font_8x16.c
	@mkdir -p $(@D)
	sed -n '/^static const unsigned char fontdata_8x16/,/^};/p' $< | \
		sed '1s/.*/static const unsigned char font8x16[4096] = {/' > $@

$(B)/frontend/status: frontend/status/status.c $(B)/frontend/font8x16.h
	$(CC) $(CFLAGS) -I$(B)/frontend -o $@ $< $(STATIC)

# --- Development tools that run on the device -----------------------------------------------
device-tools: $(B)/tools/dispctl $(B)/tools/glspin $(B)/tools/rumble

$(B)/tools/dispctl $(B)/tools/rumble: $(B)/tools/%: tools/device/%.c
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

# --- Development test card ------------------------------------------------------------------
test-card: kernel gpu userspace frontend device-tools $(B)/stock-fw/rootfs.fex
	tools/testcard/build-test-card.sh $(B)/stock-fw $(B)/test-card.img $(B)/kernel

update-card: test-card
	tools/testcard/update-card.sh $(B)/test-card.img

clean:
	@[ ! -d $(B) ] || find $(B) -mindepth 1 -maxdepth 1 ! -name ssh-host-keys -exec rm -rf {} +
