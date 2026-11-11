# The mainline family's part of build-system.sh, sourced by it. Each family's parts file defines the
# same names; tools/system/parts-brick.sh says what build-system.sh gives them.

# kmake ARG...: make for this family's kernel, in $KBUILD.
kmake() { "$ROOT/tools/mainline/kmake.sh" "$KBUILD" "$@"; }

# add_parts: what this family adds to the root filesystem besides the kernel's modules and the
# parts every family has: ARM's GPU kernel driver, outside the module index so that mdev never loads
# it (the start-up hooks do, when it is chosen). The WiFi and Bluetooth firmware come from Buildroot
# (linux-firmware), and Specular, the installer and the device tools aren't built for it yet
# (until Specular is, the family's overlay keeps the frontend service and its log service, which
# needs cardlog, down: etc/sv/frontend/down, etc/sv/frontend/log/down).
add_parts() { put "$B/mali/mali_kbase.ko" /usr/lib/crystaline/mali_kbase.ko 644; }

# The initramfs's programs besides BusyBox and e2fsck: none yet. Without the status screen its
# messages go only to the kernel log, and there is no recovery menu.
INITRAMFS_PROGRAMS=

# make_boot INITRAMFS: this version's boot files in $V, named in BOOT_FILES for the manifest: the
# kernel, INITRAMFS, and the device tree of each board of the family. A card's boot partition holds
# them in a boot slot's folder (a/ or b/) that its extlinux.conf names (tools/mainline/build-card.sh).
make_boot() {
	cp "$KBUILD/arch/arm64/boot/Image" "$V/Image"
	cp "$1" "$V/initramfs.cpio.gz"
	BOOT_FILES="Image initramfs.cpio.gz"
	for b in $("$ROOT/tools/system/family-boards.sh" mainline); do
		dtb=$(sed -n 's/^DTB := //p' "$ROOT/system/board/$b/board.mk")
		install -D -m 644 "$KBUILD/arch/arm64/boot/dts/$dtb" "$V/dtbs/$dtb"
		BOOT_FILES="$BOOT_FILES dtbs/$dtb"
	done
}

# manifest_extra: this family's fields in manifest.json: none.
manifest_extra() { :; }
