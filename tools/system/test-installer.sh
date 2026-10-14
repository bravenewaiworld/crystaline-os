#!/bin/bash
# Tests the installer (userspace/brick-install) on the PC, against image files: a fake internal
# storage laid out as TrimUI's (with the real boot area from this Brick's eMMC survey, when there,
# and random data in its partitions), a copy of the SD card image (make sd-card) and the system
# version it holds. Runs offer, a dry run (which must change nothing), an install with a backup,
# checks what was written, then restores the backup and checks the fake internal storage is back
# exactly as it was. Needs no root rights. Prints PASS or the first failure.
# Usage: test-installer.sh   (after make sd-card)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
B=$ROOT/build
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { "$@" || { echo "FAIL: $*" >&2; exit 1; }; }
sum() { sha256sum "$1" | cut -d' ' -f1; }
# Sectors of a disk image: sectors <image> <first> <count>
sectors() { dd if="$1" bs=512 skip="$2" count="$3" status=none; }

CARGO_TARGET_DIR=$B/installer-host cargo build -q --release --manifest-path "$ROOT/userspace/brick-install/Cargo.toml"
BIN=$B/installer-host/release/brick-install
V=$(basename "$(readlink -f "$B/system/latest")")

# The fake internal storage: 2 GiB, TrimUI's partitions (the sizes in its firmware's
# sys_partition.fex, UDISK the rest).
EMMC=$T/emmc.img
truncate -s 2G "$EMMC"
sfdisk --quiet "$EMMC" <<'EOF'
label: gpt
table-length: 10
first-lba: 41984
start=41984, size=49152, name=bootloader
size=1024, name=env
size=1024, name=env-redund
size=49152, name=boot
size=1146880, name=rootfs
size=500000, name=rootfs_data
size=1024, name=private
size=32768, name=recovery
size=1024, name=pstore
name=UDISK
EOF
# The boot area (sectors 16 to 40959) copied off this Brick's eMMC, when there (it isn't in git).
SURVEY=$ROOT/.scratch/research/device/20261014-emmc-survey/head-20MiB.img
[ -f "$SURVEY" ] && dd if="$SURVEY" of="$EMMC" bs=512 skip=16 seek=16 count=40944 conv=notrunc status=none
for mib in 30 200 900 1500; do head -c 4M /dev/urandom | dd of="$EMMC" bs=1M seek=$mib conv=notrunc status=none; done
ORIGINAL=$(sum "$EMMC")

# The card, the running system's partition (as folders) and the data partition.
cp --sparse=always "$B/sd-card.img" "$T/card.img"
mkdir -p "$T/system/images/$V" "$T/system/state/wifi" "$T/data"
cp "$B/system/$V"/{boot.img,rootfs.squashfs,manifest.json} "$T/system/images/$V/"
echo 'network={ ssid="Test" }' >"$T/system/state/wifi/wpa_supplicant.conf"
ARGS=(--target "$EMMC" --source "$T/card.img" --system "$T/system" --data "$T/data" --version "$V")

echo "== offer"
"$BIN" offer "${ARGS[@]}" | tee "$T/offer.json"
check grep -q '"bytes":2147483648' "$T/offer.json"

echo "== dry run"
"$BIN" install --backup --dry-run "${ARGS[@]}" | tee "$T/dry.out"
check grep -q '^DONE Dry run' "$T/dry.out"
check [ "$(sum "$EMMC")" = "$ORIGINAL" ]

echo "== install with a backup"
"$BIN" install --backup "${ARGS[@]}" | grep -v '^PROGRESS' | tee "$T/install.out"
check grep -q '^DONE Installed' "$T/install.out"
sfdisk -d "$EMMC" | tee "$T/table"
check grep -q 'start=       93184, size=       49152.*name="boot"' "$T/table"
check grep -q 'start=      142336.*name="system"' "$T/table"
# The boot area (sectors 16 to 40959) as on the card; boot.img in the boot partition; the card's
# boot0 (sectors 16 to 32799, up to the boot package) erased.
check cmp <(sectors "$EMMC" 16 40944) <(sectors "$B/sd-card.img" 16 40944)
IMG=$T/system/images/$V
check cmp -n "$(stat -c%s "$IMG/boot.img")" <(sectors "$EMMC" 93184 49152) "$IMG/boot.img"
check [ "$(sectors "$T/card.img" 16 32784 | tr -d '\0' | wc -c)" = 0 ]
# U-Boot's settings name the new system partition's filesystem; its files are there.
# (debugfs reads the filesystem at a byte offset into the image without mounting it.)
SYS="$EMMC?offset=$((142336 * 512))"
UUID=$(debugfs -R stats "$SYS" 2>/dev/null | sed -n 's/^Filesystem UUID: *//p')
check [ -n "$UUID" ]
for env in 91136 92160; do  # env and env-redund
    check grep -q "mmc_root=UUID=$UUID" <(sectors "$EMMC" $env 256 | tr '\0' '\n')
done
check cmp <(debugfs -R "cat /images/$V/rootfs.squashfs" "$SYS" 2>/dev/null) "$IMG/rootfs.squashfs"
check grep -q Test <(debugfs -R "cat /state/wifi/wpa_supplicant.conf" "$SYS" 2>/dev/null)
check ls "$T"/data/backups/internal-*/manifest.json
check ls "$T"/data/logs/install-*.log

echo "== restore"
"$BIN" offer "${ARGS[@]}" | tee "$T/offer2.json"
check grep -q '"backups":\[{' "$T/offer2.json"
"$BIN" restore "$T"/data/backups/internal-* "${ARGS[@]}" | grep -v '^PROGRESS' | tee "$T/restore.out"
check grep -q '^DONE Restored' "$T/restore.out"
check [ "$(sum "$EMMC")" = "$ORIGINAL" ]
echo PASS
