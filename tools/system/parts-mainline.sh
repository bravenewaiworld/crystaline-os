# The mainline family's part of build-system.sh, sourced by it (its variables: ROOT, B, R, TMP, V,
# KBUILD, KERNEL_RELEASE; put). Each family's parts file defines the same names.

# kmake ARG...: make for this family's kernel, in $KBUILD.
kmake() { "$ROOT/tools/mainline/kmake.sh" "$KBUILD" "$@"; }

# add_parts: what this family adds to the root filesystem besides the kernel's modules and the
# parts every family has. Nothing yet: the WiFi and Bluetooth firmware come from Buildroot
# (linux-firmware), and Specular, the installer and the device tools aren't built for it yet
# (until Specular is, the family's overlay keeps the frontend service down: etc/sv/frontend/down).
add_parts() { :; }

# The initramfs's programs besides BusyBox and e2fsck: none yet. Without the status screen its
# messages go only to the kernel log, and there is no recovery menu.
INITRAMFS_PROGRAMS=

# make_boot INITRAMFS: this version's boot files in $V, named in BOOT_FILES for the manifest: the
# kernel, INITRAMFS, and the device tree of each board of the family. A card's boot partition holds
# them in a slot folder (a/ or b/) that its extlinux.conf names (tools/mainline/build-card.sh).
make_boot() {
	cp "$KBUILD/arch/arm64/boot/Image" "$V/Image"
	cp "$1" "$V/initramfs.cpio.gz"
	BOOT_FILES="Image initramfs.cpio.gz"
	for mk in "$ROOT"/system/board/*/board.mk; do
		grep -qx 'FAMILY := mainline' "$mk" || continue
		dtb=dtbs/$(sed -n 's/^DTB := //p' "$mk")
		install -D -m 644 "$KBUILD/arch/arm64/boot/dts/${dtb#dtbs/}" "$V/$dtb"
		BOOT_FILES="$BOOT_FILES $dtb"
	done
}

# manifest_extra: this family's fields in manifest.json: its name, so that the other family's
# installer can tell an update file isn't for it.
manifest_extra() { printf '"family": "mainline"'; }
