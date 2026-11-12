# The mainline family's part of build-system.sh, sourced by it. Each family's parts file defines the
# same names; tools/system/parts-brick.sh says what build-system.sh gives them.

# kmake ARG...: make for this family's kernel, in $KBUILD.
kmake() { "$ROOT/tools/mainline/kmake.sh" "$KBUILD" "$@"; }

# add_parts: what this family adds to the root filesystem besides the kernel's modules and the
# parts every family has: ARM's GPU kernel driver, outside the module index so that mdev never loads
# it (the start-up hooks do, when it is chosen), the installer, the device tools (status, cardlog,
# ...; the Makefile's DEVICE_TOOLS) and sleepnow, Specular, and the RTL8723DS's Bluetooth firmware
# (tools/env.sh). The other WiFi and Bluetooth firmware comes from Buildroot (linux-firmware).
add_parts() {
	put "$B/mali/mali_kbase.ko" /usr/lib/crystaline/mali_kbase.ko 644
	put "$B/installer/aarch64-unknown-linux-gnu/release/crystaline-install" /usr/sbin/crystaline-install 755
	for f in "$B"/tools/* "$ROOT/tools/device/sleepnow"; do put "$f" "/usr/bin/${f##*/}" 755; done
	for f in rtl8723ds_fw.bin rtl8723ds_config.bin; do put "$RTL8723DS_BT/$f" /lib/firmware/rtl_bt/$f 644; done
	# Specular, its cores and fonts, as its own Makefile installed them (SPECULAR_STAGE in the Makefile).
	cp -R "$B/specular-install/." "$R/"
}

# The initramfs's programs besides BusyBox and e2fsck: the status screen (messages, recovery menu)
# and the installer (the recovery menu's actions).
INITRAMFS_PROGRAMS="/usr/bin/status /usr/sbin/crystaline-install"

# make_boot INITRAMFS: this version's boot.img in $V (BOOT_FILES, for the manifest), what a boot slot
# holds (the partition boot_a or boot_b, tools/mainline/build-card.sh): a FAT image that U-Boot
# starts from with extlinux.conf, holding the kernel, INITRAMFS and the device tree of each board of
# the family; each board's U-Boot names its own (fdtfile). In APPEND:
# - root= and crystaline.boot=: the system partition and the slot, from U-Boot's settings (mmc_root,
#   boot_partition), since one boot.img goes into either slot of any card;
# - the serial console (1,500,000 baud on the RK3566) and the screen; the screen is last, so it is
#   /dev/console;
# - a 1 MiB kernel log buffer, and only warnings and worse on the consoles, as on the Brick;
# - panic=10: restart 10 s after a panic; the kernel's log of it survives in RAM (ramoops) and the
#   next start saves it in /system/logs/crash-*/.
make_boot() {
	b=$TMP/boot
	mkdir -p "$b/extlinux"
	cp "$KBUILD/arch/arm64/boot/Image" "$1" "$b/"
	for board in $("$ROOT/tools/system/family-boards.sh" mainline); do
		dtb=$(sed -n 's/^DTB := //p' "$ROOT/system/board/$board/board.mk")
		install -D -m 644 "$KBUILD/arch/arm64/boot/dts/$dtb" "$b/dtbs/$dtb"
	done
	cat >"$b/extlinux/extlinux.conf" <<-'EOF'
	# Written by tools/system/parts-mainline.sh. U-Boot's settings fill in ${...}.
	DEFAULT crystaline
	LABEL crystaline
	  LINUX /Image
	  INITRD /initramfs.cpio.gz
	  FDTDIR /dtbs
	  APPEND root=${mmc_root} crystaline.boot=${boot_partition} console=ttyS2,1500000 console=tty0 log_buf_len=1M loglevel=4 panic=10
	EOF
	# Room for the files plus 2 MiB for the filesystem's own structures, in whole MiB.
	kib=$(( $(du -sk "$b" | cut -f1) / 1024 * 1024 + 3072 ))
	rm -f "$V/boot.img"
	mkfs.vfat -C -n BOOT -i 0c7a5717 "$V/boot.img" $kib >/dev/null
	MTOOLS_SKIP_CHECK=1 mcopy -s -m -i "$V/boot.img" "$b/extlinux" "$b/Image" "$b/initramfs.cpio.gz" "$b/dtbs" ::/
	BOOT_FILES=boot.img
}

# manifest_extra: this family's fields in manifest.json: none.
manifest_extra() { :; }
