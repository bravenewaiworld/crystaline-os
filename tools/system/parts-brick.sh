# The Brick family's part of build-system.sh, sourced by it (its variables: ROOT, B, R, TMP, V,
# KBUILD, KERNEL_RELEASE; put). Each family's parts file defines the same names.

# kmake ARG...: make for this family's kernel, in $KBUILD.
kmake() { "$ROOT/tools/kmake.sh" "$KBUILD" "$@"; }

# add_parts: what this family adds to the root filesystem besides the kernel's modules and the
# parts every family has. The GPU driver's modules (extra/, before depmod), padbridge, xr829-attach,
# the installer and the device tools. TrimUI's binaries come from its firmware: the GPU libraries
# (with their NULL window system, loaded by name) and firmware, and the XR829's firmware. The Vulkan
# driver (libVK_IMG, which needs libufwriter, 36 MB) is the ICD of Buildroot's Vulkan loader
# (docs/gpu.md); TrimUI's own minimal libvulkan is left out.
add_parts() {
	for ko in "$B"/gpu/*.ko; do put "$ko" "/lib/modules/$KERNEL_RELEASE/extra/${ko##*/}" 644; done
	put "$B/userspace/padbridge" /usr/bin/padbridge 755
	put "$B/userspace/xr829-attach" /usr/bin/xr829-attach 755
	put "$B/installer/aarch64-unknown-linux-gnu/release/crystaline-install" /usr/sbin/crystaline-install 755
	for f in "$B"/tools/* "$ROOT/tools/device/powertest" "$ROOT/tools/device/sleepnow"; do
		put "$f" "/usr/bin/${f##*/}" 755
	done
	# Specular, its cores and fonts, as its own Makefile installed them (SPECULAR_STAGE in the Makefile).
	cp -R "$B/specular-install/." "$R/"
	for l in libEGL.so libEGL.so.1 libGLESv2.so libGLESv2.so.2 libIMGegl.so libsrv_um.so \
		libglslcompiler.so libusc.so libpvrNULL_WSEGL.so libVK_IMG.so libVK_IMG.so.1 libufwriter.so; do
		cp -P "$B/stock-root/usr/lib/$l" "$R/usr/lib/$l"
	done
	mkdir -p "$TMP/stock"
	debugfs -R "rdump /lib/firmware $TMP/stock" "$B/stock-fw/rootfs.fex" 2>/dev/null
	mkdir -p "$R/lib/firmware"
	cp "$TMP"/stock/firmware/*xr829* "$TMP"/stock/firmware/rgx.* "$R/lib/firmware/"
}

# The initramfs's programs besides BusyBox and e2fsck: the status screen (messages, recovery menu)
# and the installer (the recovery menu's actions).
INITRAMFS_PROGRAMS="/usr/bin/status /usr/sbin/crystaline-install"

# make_boot INITRAMFS: this version's boot files in $V, named in BOOT_FILES for the manifest: an
# Android boot image (TrimUI's U-Boot loads it from a boot slot) of our kernel and INITRAMFS.
# Appended to U-Boot's boot arguments (for these, the last occurrence wins):
# - rdinit=/init: TrimUI's U-Boot settings pass rdinit=/rdinit; this runs our initramfs's /init;
# - a 1 MiB kernel log buffer (TrimUI's config has 16 KiB, which loses early messages);
# - only warnings and worse on the serial console: at 115200 baud each line holds a CPU and the
#   console lock for about 5 ms, which the GPU's display module needs on every flip.
make_boot() {
	python3 -I "$ROOT/tools/sdboot/mkbootimg.py" --ramdisk "$1" "$B/stock-fw/boot.fex" \
		"$KBUILD/arch/arm64/boot/Image" "$V/boot.img" "rdinit=/init log_buf_len=1M loglevel=4" >/dev/null
	BOOT_FILES=boot.img
}

# manifest_extra: this family's fields in manifest.json. dt_edits: the kernel makes our device-tree
# changes itself (CONFIG_OF_EDITS), so this version runs with TrimUI's boot package unchanged;
# crystaline-install refuses versions without it.
manifest_extra() {
	printf '"dt_edits": %s' "$(grep -q '^CONFIG_OF_EDITS=y' "$KBUILD/.config" && echo true || echo false)"
}
