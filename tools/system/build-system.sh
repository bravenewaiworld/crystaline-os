#!/bin/sh
# Assemble one version of the system: Buildroot's base root filesystem plus our parts, as
#   $OUT/<version>/rootfs.squashfs   the root filesystem (zstd), mounted read-only on the device
#   $OUT/<version>/boot.img          our kernel + initramfs (system/board/brick/initramfs/init),
#                                    written to the "boot" partition to run this version
#   $OUT/<version>/manifest.json     version, git commit, build time, release or development,
#                                    sizes and SHA-256 of both
# and points $OUT/latest at it. Prints the version.
#
# Our parts are built by the top-level Makefile, never by Buildroot, so changing them needs no
# Buildroot rebuild: the kernel and its modules, the GPU driver, Specular and its cores, padbridge,
# xr829-attach, the device tools and the installer. TrimUI's binaries come from its firmware: the
# GPU libraries and firmware, and the XR829's WiFi/Bluetooth firmware.
# RELEASE=1 (from the environment; `make system RELEASE=1`) builds a release image, without the
# checkout's SSH keys, the serial-console login, and the debugging and hardware test tools a
# development image (the default) has: see "Debugging tools" and "SSH and root" below.
#
# Runs without root rights: the base is unpacked as the current user, then packed from a tar
# stream that restores Buildroot's owners (tar-with-owners.py; our files are root's).
# Usage: [RELEASE=1] build-system.sh <out-dir>
set -eu
OUT=$1
RELEASE=${RELEASE:-0}
case $RELEASE in 0 | 1) ;; *) echo "RELEASE must be 0 or 1, not '$RELEASE'" >&2; exit 1 ;; esac
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/tools/env.sh"
B=$ROOT/build
BR=$B/buildroot
KBUILD=$B/kernel
BOARD=$ROOT/system/board/brick
HOST=$BR/host/bin
READELF=$(ls "$HOST"/aarch64-*-readelf | head -1)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

dirty=$(git -C "$ROOT" status --porcelain --untracked-files=no | grep -q . && echo -dirty || true)
commit=$(git -C "$ROOT" rev-parse --short HEAD)
VERSION=$(date -u +%Y%m%d-%H%M%S)-$commit$dirty
KERNEL_RELEASE=$(cat "$KBUILD/include/config/kernel.release")
R=$TMP/root

# --- Base -------------------------------------------------------------------------------------
mkdir -p "$R"
tar xf "$BR/images/rootfs.tar" -C "$R"

# --- Our parts --------------------------------------------------------------------------------
# put SRC DEST MODE: copy a file into the root filesystem.
put() { install -D -m "$3" "$1" "$R$2"; }

# Kernel modules, the GPU driver's in extra/, and their dependency lists for modprobe.
"$ROOT/tools/kmake.sh" "$KBUILD" modules_install INSTALL_MOD_PATH="$R" INSTALL_MOD_STRIP=1 \
	DEPMOD=true >/dev/null
for ko in "$B"/gpu/*.ko; do put "$ko" "/lib/modules/$KERNEL_RELEASE/extra/${ko##*/}" 644; done
rm -f "$R/lib/modules/$KERNEL_RELEASE/build" "$R/lib/modules/$KERNEL_RELEASE/source"
"$HOST/depmod" -b "$R" "$KERNEL_RELEASE"

put "$B/userspace/padbridge" /usr/bin/padbridge 755
put "$B/userspace/xr829-attach" /usr/bin/xr829-attach 755
put "$B/installer/aarch64-unknown-linux-gnu/release/brick-install" /usr/sbin/brick-install 755
for f in "$B"/tools/* "$ROOT/tools/device/powertest" "$ROOT/tools/device/sleepnow"; do
	put "$f" "/usr/bin/${f##*/}" 755
done
put "$DUFS" /usr/bin/dufs 755
# Specular, its cores and fonts, as its own Makefile installed them (SPECULAR_STAGE in the Makefile).
cp -R "$B/specular-install/." "$R/"

# TrimUI's GPU libraries (with their NULL window system, loaded by name) and firmware, and the
# XR829's firmware. Only these come from TrimUI's system.
for l in libEGL.so libEGL.so.1 libGLESv2.so libGLESv2.so.2 libIMGegl.so libsrv_um.so \
	libglslcompiler.so libusc.so libpvrNULL_WSEGL.so; do
	cp -P "$B/stock-root/usr/lib/$l" "$R/usr/lib/$l"
done
mkdir -p "$TMP/stock"
debugfs -R "rdump /lib/firmware $TMP/stock" "$B/stock-fw/rootfs.fex" 2>/dev/null
mkdir -p "$R/lib/firmware"
cp "$TMP"/stock/firmware/*xr829* "$TMP"/stock/firmware/rgx.* "$R/lib/firmware/"

# --- Debugging tools --------------------------------------------------------------------------
# Release images leave out the debugging and hardware test tools in debug-tools.list, which `make
# debug-running-release` copies into a running release's memory instead.
if [ "$RELEASE" = 1 ]; then
	mkdir "$TMP/left-out"
	grep -v -e '^#' -e '^$' "$BOARD/debug-tools.list" | while read -r p; do
		set -- "$R"/$p
		[ -e "$1" ] || { echo "debug-tools.list: nothing in the image matches $p" >&2; exit 1; }
		mv "$@" "$TMP/left-out/"
	done
	# Nothing still in the image may need a library left out (its NEEDED names are file names here,
	# as the list takes each library's links too).
	find "$R" -type f \( -perm -u+x -o -name '*.so*' \) -exec "$READELF" -d {} + 2>/dev/null |
		sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort -u >"$TMP/needed"
	[ -s "$TMP/needed" ] || { echo "readelf ($READELF) found no libraries needed in the image" >&2; exit 1; }
	if ls "$TMP/left-out" | grep -Fx -f "$TMP/needed" >&2; then
		echo "debug-tools.list: the release image still needs the libraries above" >&2
		exit 1
	fi
fi

# --- SSH and root -----------------------------------------------------------------------------
# Development: the checkout's SSH keys (build/ssh-host-keys, made by dev-keys.sh); root logs in
# with dev_key, or without a password on the serial console.
# Release: no keys in the image. The host keys and root's authorized_keys link into the state
# area: the device makes host keys of its own (ssh-host-keys), and the login keys are only those
# the user imports on the device (brick-ssh, which also switches SSH on and off). Root's password
# becomes "*", which no password matches, so nobody can log in on the serial console ("!" would
# mark the account locked, and sshd would then refuse root's keys too).
install -d -m 700 "$R/root/.ssh"
if [ "$RELEASE" = 1 ]; then
	for t in rsa ecdsa ed25519; do
		ln -s /var/state/ssh/ssh_host_${t}_key "$R/etc/ssh/ssh_host_${t}_key"
	done
	ln -s /var/state/ssh/authorized_keys "$R/root/.ssh/authorized_keys"
	sed -i 's/^root:[^:]*:/root:*:/' "$R/etc/shadow"
else
	"$ROOT/tools/system/dev-keys.sh"
	KEYS=$B/ssh-host-keys
	for t in rsa ecdsa ed25519; do
		put "$KEYS/ssh_host_${t}_key" /etc/ssh/ssh_host_${t}_key 600
		put "$KEYS/ssh_host_${t}_key.pub" /etc/ssh/ssh_host_${t}_key.pub 644
	done
	put "$KEYS/dev_key.pub" /root/.ssh/authorized_keys 600
fi

echo "$VERSION" >"$R/etc/brick-version"
V=$OUT/$VERSION
mkdir -p "$V"
# -root-*: the tar has no entry for the root directory itself.
# Here and for the initramfs below, the stream goes through a file rather than a pipe: sh (dash,
# on Debian and Ubuntu) has no pipefail, so a failure in the first command of a pipe would go
# unnoticed.
python3 -I "$ROOT/tools/system/tar-with-owners.py" "$BR/images/rootfs.tar" "$R" >"$TMP/rootfs.tar"
"$HOST/sqfstar" -comp zstd -quiet -root-uid 0 -root-gid 0 -root-mode 755 "$V/rootfs.squashfs" <"$TMP/rootfs.tar"

# --- Initramfs --------------------------------------------------------------------------------
# init, the programs it runs and the libraries they need, listed for the kernel's gen_init_cpio
# (which sets owners itself, so no root rights are needed).
list=$TMP/initramfs.list
{
	for d in /dev /proc /sys /system /lower /newroot /bootlog /bin /sbin /etc /lib /usr /usr/bin \
		/usr/sbin /usr/lib; do
		echo "dir $d 755 0 0"
	done
	# The dynamic loader looks for libraries in /lib64 and /usr/lib64 only (Buildroot's root
	# filesystem links both to lib, as here).
	echo "slink /lib64 lib 777 0 0"
	echo "slink /usr/lib64 lib 777 0 0"
	echo "slink /etc/mtab /proc/mounts 777 0 0"	# e2fsck checks for mounts through /etc/mtab
	echo "nod /dev/console 600 0 0 c 5 1"
	echo "file /init $BOARD/initramfs/init 755 0 0"
	echo "file /etc/brick-version $R/etc/brick-version 644 0 0"
} >"$list"
# need FILE: add FILE (a path in the root filesystem) and, recursively, the libraries it needs and
# its dynamic loader. A path that is a link in the root filesystem becomes a copy of its target.
seen=" "
need() {
	case $seen in *" $1 "*) return 0 ;; esac
	seen="$seen$1 "
	echo "file $1 $R$1 755 0 0" >>"$list"
	for lib in $("$READELF" -d "$R$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
		for d in /lib /usr/lib; do [ -e "$R$d/$lib" ] && { need "$d/$lib"; break; }; done
	done
	interp=$("$READELF" -l "$R$1" | sed -n 's/.*interpreter: \(.*\)\]/\1/p')
	[ -z "$interp" ] || need "$interp"
	return 0
}
need /bin/busybox
need /sbin/e2fsck
need /usr/bin/status
for a in sh mount umount mkdir cat sed sleep findfs watchdog reboot switch_root cp echo ln devmem \
	grep dmesg ps sync kill; do
	echo "slink /bin/$a busybox 777 0 0" >>"$list"
done
"$KBUILD/usr/gen_init_cpio" "$list" >"$TMP/initramfs.cpio"
gzip -9 "$TMP/initramfs.cpio"

# --- Boot image -------------------------------------------------------------------------------
# Appended to U-Boot's boot arguments (for these, the last occurrence wins):
# - rdinit=/init: TrimUI's U-Boot settings pass rdinit=/rdinit; this runs our initramfs's /init;
# - a 1 MiB kernel log buffer (TrimUI's config has 16 KiB, which loses early messages);
# - only warnings and worse on the serial console: at 115200 baud each line holds a CPU and the
#   console lock for about 5 ms, which the GPU's display module needs on every flip.
python3 -I "$ROOT/tools/sdboot/mkbootimg.py" --ramdisk "$TMP/initramfs.cpio.gz" "$B/stock-fw/boot.fex" \
	"$KBUILD/arch/arm64/boot/Image" "$V/boot.img" "rdinit=/init log_buf_len=1M loglevel=4" >/dev/null

# --- Manifest ---------------------------------------------------------------------------------
entry() { printf '"%s": { "size": %s, "sha256": "%s" }' "$1" "$(stat -c%s "$V/$1")" \
	"$(sha256sum "$V/$1" | cut -d' ' -f1)"; }
cat >"$V/manifest.json" <<EOF
{ "version": "$VERSION", "commit": "$commit$dirty", "built": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "kernel": "$KERNEL_RELEASE", "release": $([ "$RELEASE" = 1 ] && echo true || echo false),
  "files": { $(entry boot.img), $(entry rootfs.squashfs) } }
EOF
ln -sfn "$VERSION" "$OUT/latest"
echo "$VERSION"
