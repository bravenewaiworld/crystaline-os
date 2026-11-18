#!/bin/sh
# Runs after Buildroot has filled the target directory ($1), before the root filesystem tar is
# made. The root filesystem is mounted read-only, so everything that must be written to links to
# the state area (/var/state, on the system partition: see rootfs-overlay/usr/libexec/crystaline/state).
set -eu
T=$1

# Packages' own start scripts: our services are supervised by runit instead (etc/sv).
rm -f "$T"/etc/init.d/S[0-9]*
# Our services exactly as in the overlays (BR2_ROOTFS_OVERLAY: common, family, board): Buildroot
# copies the overlays over the target directory it keeps between builds, so a service removed from
# an overlay would otherwise stay.
rm -rf "$T/etc/sv"
mkdir "$T/etc/sv"
overlays=$(sed -n 's/^BR2_ROOTFS_OVERLAY="\(.*\)"$/\1/p' "$BR2_CONFIG" |
	sed "s#\$(BR2_EXTERNAL_CRYSTALINE_PATH)#$BR2_EXTERNAL_CRYSTALINE_PATH#g")
for o in $overlays; do
	[ ! -d "$o/etc/sv" ] || cp -a "$o/etc/sv/." "$T/etc/sv/"
done

mkdir -p "$T/system" "$T/mnt/SDCARD"
ln -sfn /system/state "$T/var/state"

# BlueZ's storage (pairings) is in the state area, which survives updates, next to the XR829's
# Bluetooth address file (xr829-attach uses /var/state/bluetooth/xr_bt.conf).
rm -rf "$T/var/lib/bluetooth"	# a directory in BlueZ's package
ln -s /var/state/bluetooth "$T/var/lib/bluetooth"

# D-Bus needs a machine ID that stays the same (its package links /var/lib/dbus/machine-id to
# /etc/machine-id); the state script makes it once.
ln -sfn /var/state/machine-id "$T/etc/machine-id"

# The time zone, which crystaline-timezone keeps in the state area. Until it first sets one,
# /var/state/time/localtime doesn't exist and glibc uses UTC.
ln -sfn /var/state/time/localtime "$T/etc/localtime"
# The zones' leap-second variants: nothing uses them.
rm -rf "$T/usr/share/zoneinfo/right"
