#!/bin/sh
# Runs after Buildroot has filled the target directory ($1), before the root filesystem tar is
# made. The root filesystem is mounted read-only, so everything that must be written to links to
# the state area (/var/state, on the system partition: see rootfs-overlay/usr/libexec/brick/state).
set -eu
T=$1

# Packages' own start scripts: our services are supervised by runit instead (etc/sv).
rm -f "$T"/etc/init.d/S[0-9]*
# Our services exactly as in the overlay: Buildroot copies the overlay over the target directory
# it keeps between builds, so a service removed from the overlay would otherwise stay.
rm -rf "$T/etc/sv"
cp -a "$BR2_EXTERNAL_BRICK_PATH/board/brick/rootfs-overlay/etc/sv" "$T/etc/sv"

mkdir -p "$T/system" "$T/mnt/SDCARD"
ln -sfn /system/state "$T/var/state"

# The XR829's Bluetooth address file and BlueZ's storage (pairings) share one directory in the
# state area, which survives updates.
mkdir -p "$T/etc/bluetooth"
ln -sfn /var/state/bluetooth/xr_bt.conf "$T/etc/bluetooth/xr_bt.conf"
rm -rf "$T/var/lib/bluetooth"	# a directory in BlueZ's package
ln -s /var/state/bluetooth "$T/var/lib/bluetooth"

# D-Bus needs a machine ID that stays the same (its package links /var/lib/dbus/machine-id to
# /etc/machine-id); the state script makes it once.
ln -sfn /var/state/machine-id "$T/etc/machine-id"
