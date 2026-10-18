#!/bin/bash
# Tests the installer (userspace/brick-install) on the PC, against image files: a fake internal
# storage laid out as TrimUI's (with the real boot area from this Brick's eMMC survey, when there,
# and random data in its partitions), a copy of the SD card image (make sd-card) and the system
# version it holds. Runs offer, a dry run (which must change nothing), an install with a backup,
# checks what was written, then restores the backup and checks the fake internal storage is back
# exactly as it was. Then cuts tasks short (as a power cut would) and checks what is left is
# recognised and cleared up, and that only one task runs at a time and can be followed. Needs no
# root rights. Prints PASS or the first failure.
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
# The boot area (sectors 16 to 40959) copied off a Brick's eMMC (TrimUI's; not in git), when there.
SURVEY=$ROOT/third-party/emmc-head-20MiB.img
[ -f "$SURVEY" ] && dd if="$SURVEY" of="$EMMC" bs=512 skip=16 seek=16 count=40944 conv=notrunc status=none
for mib in 30 200 900 1500; do head -c 4M /dev/urandom | dd of="$EMMC" bs=1M seek=$mib conv=notrunc status=none; done
ORIGINAL=$(sum "$EMMC")

# The card, the running system's partition (as folders) and the data partition.
cp --sparse=always "$B/sd-card.img" "$T/card.img"
mkdir -p "$T/system/images/$V" "$T/system/state/wifi" "$T/data"
cp "$B/system/$V"/{boot.img,rootfs.squashfs,manifest.json} "$T/system/images/$V/"
echo 'network={ ssid="Test" }' >"$T/system/state/wifi/wpa_supplicant.conf"
ARGS=(--target "$EMMC" --source "$T/card.img" --system "$T/system" --data "$T/data" --version "$V" --status "$T/status")
# What the internal storage holds, from the offer (install::holds).
holds() { "$BIN" offer "${ARGS[@]}" | sed -n 's/.*"internal":"\([a-z-]*\)".*/\1/p'; }
# start <name> <args...>: runs brick-install in the background, its output in $T/<name>.out.
start() { local name=$1; shift; "$BIN" "$@" "${ARGS[@]}" >"$T/$name.out" & PID=$!; }
# wait_for <name> <awk condition>: waits until the task's output meets the condition.
wait_for() { until awk "$2" "$T/$1.out"; do sleep 0.05; done; }
# cut_short <name> <step>: once the task's output shows step <step> (e.g. 'STEP 2/') has made progress
# (so has written something), kills it, with no chance to clean up, as with a power cut.
cut_short() {
    wait_for "$1" "index(\$0, \"$2\") == 1 { on = 1 } on && /^PROGRESS/ { found = 1 } END { exit !found }"
    kill -9 $PID; wait $PID 2>/dev/null || true
}
# The card's boot0 (sectors 16 to 32799; install.rs's CARD_BOOT0), as written.
CARD_BOOT0=$(sectors "$T/card.img" 16 32784 | sha256sum)

echo "== offer"
"$BIN" offer "${ARGS[@]}" | tee "$T/offer.json"
check grep -q '"bytes":2147483648' "$T/offer.json"
check grep -q '"internal":"trimui"' "$T/offer.json"

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
check [ "$(holds)" = trimui ]
rm -r "$T"/data/backups/*
cp --sparse=always "$B/sd-card.img" "$T/card.img"  # bootable again

echo "== a backup cut short: nothing written to the internal storage, its leftovers cleared next time"
start cut-backup install --backup
cut_short cut-backup 'STEP 2/'
check ls -d "$T"/data/backups/*.partial
check [ "$(holds)" = trimui ]
check [ "$(sum "$EMMC")" = "$ORIGINAL" ]

echo "== an install cut short: recognised, the card still starts the device, and it can run again"
start cut-install install
cut_short cut-install 'STEP 2/'  # writing the start-up files
check [ "$(holds)" = unfinished-install ]
check [ "$(sectors "$T/card.img" 16 32784 | sha256sum)" = "$CARD_BOOT0" ]

echo "== one task at a time"
flock "$T/status" sleep 3 & sleep 0.5  # holds the lock as a running task would
"$BIN" install "${ARGS[@]}" >"$T/locked.out" || true
check grep -q '^FAIL an install or a restore is already running' "$T/locked.out"
wait

echo "== run again, with a backup (of the unfinished install), followed from its start"
start again install --backup
wait_for again '/^STEP/ { found = 1 } END { exit !found }'
"$BIN" follow "${ARGS[@]}" >"$T/follow.out"
wait $PID
check grep -q '^DONE Installed' "$T/again.out"
check cmp <(grep -v '^PROGRESS' "$T/again.out") <(grep -v '^PROGRESS' "$T/follow.out")
check [ "$(holds)" = this-system ]
check [ -z "$(ls -d "$T"/data/backups/*.partial 2>/dev/null)" ]
check grep -q '"holds": "unfinished-install"' "$T"/data/backups/internal-*/manifest.json
"$BIN" follow "${ARGS[@]}" >"$T/follow-none.out"  # nothing runs: prints nothing
check [ ! -s "$T/follow-none.out" ]

echo "== a restore cut short: recognised"
start cut-restore restore "$(ls -d "$T"/data/backups/internal-*)"
cut_short cut-restore 'STEP 2/'
check [ "$(holds)" = unfinished-restore ]
echo PASS
