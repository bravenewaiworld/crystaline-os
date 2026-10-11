#!/bin/sh
# Build an SD card image that runs TrimUI's stock bootloader and system entirely from the card,
# with either TrimUI's kernel or ours, plus markers proving it: an "SD CARD BOOT" boot logo
# (sd-logo.bmp, same byte size as the stock bootlogo.bmp), red LEDs ~30 s after boot,
# /etc/sd-boot-marker, and boot logs saved to sd-boot-log/ on the card's FAT "bootloader"
# partition (boot-resource.fex: the boot logo and other images U-Boot reads).
# With our kernel the card also: mounts a user-data partition (sdcard) and starts our placeholder
# frontend (frontend/status) instead of TrimUI's UI, buzzes the rumble
# motor when the system starts (sdinit), offers adb and SSH over USB (sdusb), applies
# dt-tweaks.sh, and adds the GPU modules and test tools if they've been built
# (tools/build-gpu.sh, tools/device/).
# Usage: build-test-card.sh <unpacked-firmware-dir> <out.img> [kernel-build-dir [kernel-args]]
#   unpacked-firmware-dir: output of tools/sdboot/awimg_unpack.py on trimui_tg3040.awimg
#   kernel-build-dir: our kernel's build output (tools/kmake.sh); omit for TrimUI's kernel
#   kernel-args: extra kernel command-line arguments (e.g. brick_trace=8 for a debug kernel)
set -eu
FW=$1 OUT=$2 KBUILD=${3:-} KARGS=${4:-}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/../..
TOOLS=$ROOT/tools/sdboot
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Boot logo: overwrite bootlogo.bmp's bytes inside the FAT image. This script runs without root
# (no loop mount) or mtools, so the new logo must be the same size as the stock one and the
# stock one's clusters must be contiguous in the image.
python3 -I - "$FW/boot-resource.fex" "$HERE/sd-logo.bmp" "$TMP/bootres.fat" <<'PY'
import sys, subprocess
fat = bytearray(open(sys.argv[1], 'rb').read())
new = open(sys.argv[2], 'rb').read()
old = subprocess.run(['7z', 'e', '-so', sys.argv[1], 'bootlogo.bmp'], capture_output=True).stdout
# 7z exits non-zero on this image (it is shorter than the FAT claims) but still extracts.
assert old, '7z could not extract bootlogo.bmp'
assert len(old) == len(new), 'logo size differs from stock bootlogo.bmp'
at = fat.find(old)
assert at > 0, 'stock bootlogo.bmp not stored contiguously'
fat[at:at + len(new)] = new
open(sys.argv[3], 'wb').write(fat)
PY

# dbg: run debugfs commands from stdin against the root filesystem copy. debugfs exits 0 even
# when a command fails, so treat anything on stderr besides its version banner as failure.
cp "$FW/rootfs.fex" "$TMP/rootfs.ext4"
dbg() {
	err=$(debugfs -w "$TMP/rootfs.ext4" 2>&1 >/dev/null | grep -v '^debugfs [0-9]' || true)
	[ -z "$err" ] || { echo "debugfs failed: $err" >&2; exit 1; }
}
# put SRC DEST MODE: print debugfs commands copying host file SRC to DEST with octal MODE.
put() { printf 'write "%s" %s\nsif %s mode 0100%s\n' "$1" "$2" "$2" "$3"; }
# service NAME [FILE]: print debugfs commands installing OpenWrt init script FILE (default: NAME
# in this directory) as /etc/init.d/NAME. OpenWrt's "/etc/init.d/NAME enable" (which creates the
# rc.d/S<START>NAME link) can't run on an offline image, so make the link here from the script's
# own START.
service() {
	f=${2:-$HERE/$1}
	put "$f" /etc/init.d/$1 755
	echo "symlink /etc/rc.d/S$(sed -n 's/^START=//p' "$f")$1 ../init.d/$1"
}

{ put "$HERE/sd-boot-marker" /etc/sd-boot-marker 644; service sdmarker; } | dbg

BOOTIMG=$FW/boot.fex
PKG=$FW/boot_package.fex
if [ -n "$KBUILD" ]; then
	# Our kernel reports itself as "4.9.191+" (the build adds "+" for a source tree that isn't
	# at a release tag), so its modules get their own directory and TrimUI's binary modules
	# (in /lib/modules/4.9.191) can't be loaded into it.
	RELEASE=$(cat "$KBUILD/include/config/kernel.release")
	[ "$RELEASE" != 4.9.191 ] || { echo "our kernel must not share TrimUI's version string" >&2; exit 1; }
	# DEPMOD=true skips depmod: OpenWrt's module loader reads dependencies from each .ko.
	"$ROOT/tools/kmake.sh" "$KBUILD" modules_install INSTALL_MOD_PATH="$TMP/mods" \
		INSTALL_MOD_STRIP=1 DEPMOD=true >/dev/null
	# SSH host keys: the SSH service creates them on first start, which fails on this read-only
	# root filesystem. Kept across rebuilds so the PC doesn't warn about a changed host key.
	KEYS=$ROOT/build/ssh-host-keys
	mkdir -p "$KEYS"
	for t in rsa ecdsa ed25519; do
		[ -f "$KEYS/ssh_host_${t}_key" ] || ssh-keygen -q -N '' -t $t -f "$KEYS/ssh_host_${t}_key"
	done
	{
		# Modules go straight into /lib/modules/<release>/ (no subdirectories), where OpenWrt's
		# module loader looks. Nothing lists them in /etc/modules.d, so none auto-load: a driver
		# crashing before the logs are saved would leave no trace.
		echo "mkdir /lib/modules/$RELEASE"
		find "$TMP/mods" -name '*.ko' | while read -r ko; do put "$ko" "/lib/modules/$RELEASE/${ko##*/}" 644; done
		# GPU driver (tools/build-gpu.sh), if built. Unlike the others these do auto-load: the
		# stock /etc/modules.d lists pvrsrvkm and dc_sunxi.
		for ko in "$ROOT"/build/gpu/*.ko; do
			[ -f "$ko" ] && put "$ko" "/lib/modules/$RELEASE/${ko##*/}" 644
		done
		# Gamepad bridge (userspace/padbridge): turns the buttons into the virtual gamepad games
		# expect, replacing TrimUI's trimui_inputd.
		put "$ROOT/build/userspace/padbridge" /usr/bin/padbridge 755
		service padbridge "$ROOT/userspace/padbridge/padbridge.init"
		# Test tools (tools/device/), if built.
		for t in dispctl glspin; do
			[ -f "$ROOT/build/tools/$t" ] && put "$ROOT/build/tools/$t" /usr/bin/$t 755
		done
		put "$ROOT/tools/device/sleeptest" /usr/bin/sleeptest 755
		# TrimUI's UI needs drivers our kernel doesn't have yet and can power the device off
		# (e.g. its battery monitor finds no battery), so remove the boot link that starts it
		# (runtrimui) and start our placeholder frontend instead.
		echo "rm /etc/rc.d/S99runtrimui"
		service sdcard
		# WiFi (see wifi), replacing the stock WiFi start-up, which runs before the driver is
		# loaded and uses a configuration under /etc.
		echo "rm /etc/rc.d/S96wpa_supplicant"
		service wifi
		put "$ROOT/build/frontend/status" /usr/bin/status 755
		service frontend
		put "$HERE/sdinit" /sbin/sdinit 755     # run via init= below
		service sdusb
		for t in rsa ecdsa ed25519; do
			put "$KEYS/ssh_host_${t}_key" /etc/ssh/ssh_host_${t}_key 600
			put "$KEYS/ssh_host_${t}_key.pub" /etc/ssh/ssh_host_${t}_key.pub 644
		done
	} | dbg

	# Device-tree changes for our kernel (see dt-tweaks.sh). The kernel receives the device tree
	# inside the boot package (boot_package.fex: Allwinner's container for U-Boot, firmware and
	# the device tree; see tools/sdboot/toc1.py), so patch it there and use the patched copy.
	# fdtput drops the spare space U-Boot needs for its boot-time additions; dtc -p puts it back.
	python3 -I "$TOOLS/toc1.py" "$PKG" 0 "$TMP/pkg" >/dev/null   # 0 = byte offset in the file
	"$HERE/dt-tweaks.sh" "$TMP/pkg/dtb.bin"
	dtc -q -I dtb -O dtb -p 16384 -o "$TMP/dtb.padded" "$TMP/pkg/dtb.bin"
	PKG=$TMP/boot_package.fex
	python3 -I "$TOOLS/toc1.py" repack "$FW/boot_package.fex" "$PKG" dtb="$TMP/dtb.padded"

	# Appended to U-Boot's boot arguments: a 1 MiB kernel log buffer (TrimUI's config has 16 KiB,
	# which loses early messages) and sdinit as the first program.
	BOOTIMG=$TMP/boot.img
	python3 -I "$TOOLS/mkbootimg.py" "$FW/boot.fex" "$KBUILD/arch/arm64/boot/Image" "$BOOTIMG" \
		"log_buf_len=1M init=/sbin/sdinit $KARGS" >/dev/null
fi

"$TOOLS/build_sd_image.sh" "$OUT" "$FW/boot0_sdcard.fex" "$PKG" "$FW/env.fex" \
	"$BOOTIMG" "$TMP/bootres.fat" "$TMP/rootfs.ext4"
