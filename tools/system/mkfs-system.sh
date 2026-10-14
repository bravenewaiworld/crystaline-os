#!/bin/sh
# Make the system partition's ext4 filesystem (in a file or on a device), optionally filled from a
# directory, for the SD card build. The installer (userspace/brick-install, install.rs) makes the
# internal storage's system partition with the same options; keep them in step. Features our 4.9 kernel lacks are
# switched off: orphan_file (needs Linux 5.15 or later), on by default in e2fsprogs 1.47. Files
# copied from DIR keep their owner IDs; the device runs as root, so that doesn't matter.
# Usage: mkfs-system.sh <file|device> <uuid> [dir [size]]
set -eu
mke2fs -q -F -t ext4 -O ^orphan_file -L brick-system -U "$2" ${3:+-d "$3"} -E root_owner=0:0 "$1" ${4:-}
