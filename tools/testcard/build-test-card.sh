#!/bin/sh
# Build an SD card image that runs TrimUI's stock bootloader and system entirely from the card,
# with either TrimUI's kernel or ours, plus markers proving it: an "SD CARD BOOT" boot logo
# (sd-logo.bmp, same byte size as the stock bootlogo.bmp), red LEDs ~30 s after boot,
# /etc/sd-boot-marker, and boot logs saved to sd-boot-log/ on the card's FAT "bootloader"
# partition (boot-resource.fex: the boot logo and other images U-Boot reads).
# With our kernel the card also: mounts a user-data partition (sdcard) and starts Specular
# (specular/; see frontend) instead of TrimUI's UI, saves the early kernel log (sdinit), offers
# adb and SSH over USB (sdusb), WiFi (wifi), file transfer (webdav) and Bluetooth (bluetooth),
# applies system/board/brick/dt-tweaks.sh, and adds the device tools (tools/device/, including status, the
# placeholder frontend Specular falls back to) and, if they've been built, the GPU modules
# (tools/build-gpu.sh).
# Usage: build-test-card.sh <unpacked-firmware-dir> <out.img> [kernel-build-dir [kernel-args]]
#   unpacked-firmware-dir: output of tools/sdboot/awimg_unpack.py on trimui_tg3040.awimg
#   kernel-build-dir: our kernel's build output (tools/kmake.sh); omit for TrimUI's kernel
#   kernel-args: extra kernel command-line arguments (e.g. brick_trace=8 for a debug kernel)
set -eu
FW=$1 OUT=$2 KBUILD=${3:-} KARGS=${4:-}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/../..
. "$ROOT/tools/env.sh"
TOOLS=$ROOT/tools/sdboot
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Boot logo: the "SD CARD BOOT" marker in place of TrimUI's.
python3 -I "$TOOLS/replace-bootlogo.py" "$FW/boot-resource.fex" "$HERE/sd-logo.bmp" "$TMP/bootres.fat"

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
	# Development login key: the card authorizes it for root, so tools can log in over WiFi or
	# USB without a password (ssh -i build/ssh-host-keys/dev_key root@<address>). Kept with the
	# host keys in build/ssh-host-keys/, which `make clean` preserves.
	[ -f "$KEYS/dev_key" ] || ssh-keygen -q -N '' -t ed25519 -C brick-dev -f "$KEYS/dev_key"
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
		# Device tools: every binary built into build/tools/ (including status, the placeholder
		# frontend that `service frontend` below falls back to), plus the powertest, sleepnow and
		# emmc scripts.
		# status calls sleepnow to put the device to sleep.
		for f in "$ROOT"/build/tools/* "$ROOT/tools/device/powertest" "$ROOT/tools/device/sleepnow" \
			"$ROOT/tools/device/emmc"
		do
			put "$f" "/usr/bin/${f##*/}" 755
		done
		# TrimUI's UI expects TrimUI's own drivers and interfaces, so remove the boot link that
		# starts it (runtrimui) and start ours instead.
		echo "rm /etc/rc.d/S99runtrimui"
		echo "rm /etc/rc.local"		# debugfs can't overwrite a file
		put "$HERE/rc.local" /etc/rc.local 644
		service sdcard
		# Stock automounting would mount USB drives (and some other disks) over /mnt/SDCARD, hiding
		# the card's user-data partition, which sdcard mounts: remove its hotplug script and boot-time
		# mounts. USB drives aren't mounted automatically.
		echo "rm /etc/hotplug.d/block/10-mount"
		echo "rm /etc/rc.d/S40fstab"
		# WiFi (see wifi), replacing the stock WiFi start-up, which runs before the driver is
		# loaded and uses a configuration under /etc.
		echo "rm /etc/rc.d/S96wpa_supplicant"
		service wifi
		put "$DUFS" /usr/bin/dufs 755	# required (see DUFS in tools/env.sh)
		service webdav
		echo "rm /etc/rc.d/S80hciattach"	# replaced by our bluetooth service
		service bluetooth
		# Bluetooth address file and BlueZ's storage directory: links into the state area (see
		# bluetooth). debugfs removes only empty directories, so first delete the storage
		# directory's files, which are for BlueZ's mesh daemon (unused).
		echo "symlink /etc/bluetooth/xr_bt.conf /tmp/state/bluetooth/xr_bt.conf"
		for f in local_node.json prov_db.json; do echo "rm /etc/lib/bluetooth/mesh/$f"; done
		echo "rmdir /etc/lib/bluetooth/mesh"; echo "rmdir /etc/lib/bluetooth"
		echo "symlink /etc/lib/bluetooth /tmp/state/bluetooth"
		# Specular, the frontend (make specular), with its cores (make cores) in cores/ next to it.
		echo "mkdir /usr/lib/specular"
		echo "mkdir /usr/lib/specular/cores"
		put "$ROOT/build/specular/aarch64-unknown-linux-gnu/release/specular" /usr/lib/specular/specular 755
		for core in "$ROOT"/build/cores/aarch64/*.so; do put "$core" "/usr/lib/specular/cores/${core##*/}" 644; done
		put "$HERE/frontend-run" /usr/bin/frontend-run 755
		service frontend
		put "$HERE/sdinit" /sbin/sdinit 755     # run via init= below
		service sdusb
		echo "mkdir /root/.ssh"
		put "$KEYS/dev_key.pub" /root/.ssh/authorized_keys 600
		for t in rsa ecdsa ed25519; do
			put "$KEYS/ssh_host_${t}_key" /etc/ssh/ssh_host_${t}_key 600
			put "$KEYS/ssh_host_${t}_key.pub" /etc/ssh/ssh_host_${t}_key.pub 644
		done
	} | dbg

	# Device-tree changes for our kernel, in the boot package.
	PKG=$TMP/boot_package.fex
	"$TOOLS/patch-boot-package.sh" "$FW/boot_package.fex" "$PKG"

	# Appended to U-Boot's boot arguments (for these, the last occurrence wins; checked in
	# /proc/sys/kernel/printk and /proc/cmdline):
	# - a 1 MiB kernel log buffer (TrimUI's config has 16 KiB, which loses early messages);
	# - only warnings and worse on the serial console (U-Boot asks for everything, loglevel=8):
	#   at 115200 baud each line holds a CPU and the console lock for about 5 ms, which the GPU's
	#   display module needs on every flip, so log bursts dropped frames. dmesg still has it all;
	# - sdinit as the first program.
	BOOTIMG=$TMP/boot.img
	python3 -I "$TOOLS/mkbootimg.py" "$FW/boot.fex" "$KBUILD/arch/arm64/boot/Image" "$BOOTIMG" \
		"log_buf_len=1M loglevel=4 init=/sbin/sdinit $KARGS" >/dev/null
fi

"$TOOLS/build_sd_image.sh" "$OUT" "$FW/boot0_sdcard.fex" "$PKG" "$FW/env.fex" \
	"$BOOTIMG" "$TMP/bootres.fat" "$TMP/rootfs.ext4"
