#!/bin/bash
# Tests the installer (userspace/brick-install) on the PC, against image files: a fake internal
# storage laid out as TrimUI's (with the boot area copied off a Brick's eMMC, when there, and
# random data in its partitions), a copy of the SD card image (make sd-card) and the system
# version it holds. Checks the card's layout and start-up settings, runs offer, a dry run (which
# must change nothing), an install with a backup, checks what was written, prepares a restore
# from the installed system, then restores the backup from the card and checks the fake internal
# storage is back exactly as it was. Then cuts tasks short (as a power cut would) and checks what
# is left is recognised and cleared up, and that only one task runs at a time and can be
# followed; cancels a prepared restore. Then installs update files on the card (signed with a
# test key; damaged and wrongly signed ones, and versions whose kernel doesn't make the device-tree
# changes, must change nothing), cut short at each write that matters (the cut points in
# userspace/brick-install/src/cut.rs), switches back to the previous version, and checks that a
# low battery stops each task. Needs no root rights. Prints PASS or the first failure.
# Usage: test-installer.sh   (after make sd-card)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
B=$ROOT/build
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { "$@" || { echo "FAIL: $*" >&2; exit 1; }; }
sum() { sha256sum "$1" | cut -d' ' -f1; }
# Sectors of a disk image: sectors <image> <first> <count>
sectors() { dd if="$1" bs=512 skip="$2" count="$3" status=none; }
# What U-Boot will use on a disk image, read independently of brick-install: uboot <image> [key]
uboot() { python3 -I "$ROOT/tools/sdboot/uboot-env.py" "$@"; }
# A partition's start sector or GPT UUID (in capitals), from sfdisk: part <image> <name> start|uuid
part() { sfdisk -d "$1" | sed -n "s/.*$3= *\([0-9A-F-]*\).*name=\"$2\".*/\1/p"; }
# Whether all of stdin is zero bytes.
zeros() { [ "$(tr -d '\0' | wc -c)" = 0 ]; }

# From its directory, where rustup finds its pinned toolchain.
(cd "$ROOT/userspace/brick-install" && CARGO_TARGET_DIR=$B/installer-host cargo build -q --release --features cut-points)
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
# Random data where our layout puts boot_b (which an install leaves alone) and pstore (which it zeroes).
for s in 142336 191488; do head -c 1M /dev/urandom | dd of="$EMMC" bs=512 seek=$s conv=notrunc status=none; done
ORIGINAL=$(sum "$EMMC")

# The card, the running system's partition (as folders) and the data partition.
cp --sparse=always "$B/sd-card.img" "$T/card.img"
mkdir -p "$T/system/images/$V" "$T/system/state/wifi" "$T/data"
cp "$B/system/$V"/{boot.img,rootfs.squashfs,manifest.json} "$T/system/images/$V/"
echo 'network={ ssid="Test" }' >"$T/system/state/wifi/wpa_supplicant.conf"
# A full battery, an almost empty one, and the trusted update keys (a test key).
for p in power:100 low-power:30; do
	mkdir -p "$T/${p%:*}/battery"
	echo Battery >"$T/${p%:*}/battery/type"; echo "${p#*:}" >"$T/${p%:*}/battery/capacity"; echo Discharging >"$T/${p%:*}/battery/status"
done
mkdir "$T/keys"
for k in key other-key; do openssl genpkey -algorithm ed25519 -out "$T/$k.pem" 2>/dev/null; done
"$ROOT/tools/system/sign-update.sh" --public-key "$T/key.pem" >"$T/keys/test.pub"
echo 'not a key' >"$T/keys/junk.pub"  # skipped

# brick-install's options: the system runs from $RUNNING (default the card) as version $VER
# (default $V) from slot $SLOT (default boot_a), with $POWER as its power supplies.
args() {
	ARGS=(--target "$EMMC" --source "$T/card.img" --running "${RUNNING:-$T/card.img}" --system "$T/system" --data "$T/data"
	      --version "${VER:-$V}" --slot "${SLOT:-boot_a}" --power-supply "${POWER:-$T/power}" --keys "$T/keys" --status "$T/status")
}
bi() { args; "$BIN" "$@" "${ARGS[@]}"; }
# What the internal storage holds, from the offer (install::holds).
holds() { bi offer | sed -n 's/.*"internal":"\([a-z-]*\)".*/\1/p'; }
# start <name> <args...>: runs brick-install in the background, its output in $T/<name>.out.
start() { local name=$1; shift; args; "$BIN" "$@" "${ARGS[@]}" >"$T/$name.out" & PID=$!; }
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

echo "== the card: two boot slots, crash records, U-Boot's settings"
sfdisk -d "$T/card.img" | tee "$T/card-table"
for p in env:90112 env-redund:98304 boot_a:100352 boot_b:165888 pstore:231424 system:233472; do
	check [ "$(part "$T/card.img" ${p%:*} start)" = ${p#*:} ]
done
uboot "$T/card.img" >"$T/card-env"
grep -v = "$T/card-env"
check grep -qx 'picked: env' "$T/card-env"
check [ "$(uboot "$T/card.img" boot_partition)" = boot_a ]
check [ "$(uboot "$T/card.img" blkoops_blkdev | tr a-f A-F)" = "PARTUUID=$(part "$T/card.img" pstore uuid)" ]
check grep -q ' brick.boot=${boot_partition}$' <(uboot "$T/card.img" setargs_mmc)
check zeros < <(sectors "$T/card.img" 231424 2048)

echo "== offer"
bi offer | tee "$T/offer.json"
check grep -q '"bytes":2147483648' "$T/offer.json"
check grep -q '"internal":"trimui"' "$T/offer.json"
check grep -q '"running":{"disk":"card","slot":"boot_a","version":"'"$V"'"}' "$T/offer.json"

echo "== dry run"
bi install --backup --dry-run | tee "$T/dry.out"
check grep -q '^DONE Dry run' "$T/dry.out"
check [ "$(sum "$EMMC")" = "$ORIGINAL" ]

echo "== install with a backup"
BOOT_B=$(sectors "$EMMC" 142336 49152 | sha256sum)
bi install --backup | grep -v '^PROGRESS' | tee "$T/install.out"
check grep -q '^DONE Installed' "$T/install.out"
sfdisk -d "$EMMC" | tee "$T/table"
for p in boot_a:93184 boot_b:142336 pstore:191488 system:193536; do
	check [ "$(part "$EMMC" ${p%:*} start)" = ${p#*:} ]
done
# The boot area (sectors 16 to 40959) as on the card; boot.img in boot_a, boot_b untouched, pstore
# zeroed; the card's boot0 (sectors 16 to 32799, up to the boot package) erased.
check cmp <(sectors "$EMMC" 16 40944) <(sectors "$B/sd-card.img" 16 40944)
IMG=$T/system/images/$V
check cmp -n "$(stat -c%s "$IMG/boot.img")" <(sectors "$EMMC" 93184 49152) "$IMG/boot.img"
check [ "$(sectors "$EMMC" 142336 49152 | sha256sum)" = "$BOOT_B" ]
check zeros < <(sectors "$EMMC" 191488 2048)
check zeros < <(sectors "$T/card.img" 16 32784)
# U-Boot's settings name the new system partition's filesystem, boot_a and the new pstore
# partition; the system partition's files are there.
# (debugfs reads the filesystem at a byte offset into the image without mounting it.)
SYS="$EMMC?offset=$((193536 * 512))"
UUID=$(debugfs -R stats "$SYS" 2>/dev/null | sed -n 's/^Filesystem UUID: *//p')
check [ -n "$UUID" ]
uboot "$EMMC" | grep -v =
check [ "$(uboot "$EMMC" mmc_root)" = "UUID=$UUID" ]
check [ "$(uboot "$EMMC" boot_partition)" = boot_a ]
check [ "$(uboot "$EMMC" blkoops_blkdev | tr a-f A-F)" = "PARTUUID=$(part "$EMMC" pstore uuid)" ]
check [ "$(uboot "$EMMC" blkoops_blkdev)" != "$(uboot "$T/card.img" blkoops_blkdev)" ]
check cmp <(sectors "$EMMC" 91136 256) <(sectors "$EMMC" 92160 256)  # both copies the same
check cmp <(debugfs -R "cat /images/$V/rootfs.squashfs" "$SYS" 2>/dev/null) "$IMG/rootfs.squashfs"
check grep -q Test <(debugfs -R "cat /state/wifi/wpa_supplicant.conf" "$SYS" 2>/dev/null)
check ls "$T"/data/backups/internal-*/manifest.json
check ls "$T"/data/logs/install-*.log
BACKUP=$(ls -d "$T"/data/backups/internal-*)

echo "== restore, prepared on the installed system: the card starts the device again, with a marker"
RUNNING=$EMMC bi offer | tee "$T/offer-installed.json"
check grep -q '"restore":{"possible":true}' "$T/offer-installed.json"
check grep -q '"running":{"disk":"internal"' "$T/offer-installed.json"
RUNNING=$EMMC bi restore "$BACKUP" | grep -v '^PROGRESS' | tee "$T/prepare.out"
check grep -q '^DONE Restart to continue the restore' "$T/prepare.out"
check cmp <(sectors "$T/card.img" 16 32784) <(sectors "$EMMC" 16 32784)
check [ -f "$T/data/backups/restore-pending.json" ]
bi offer | tee "$T/offer2.json"
check grep -q '"backups":\[{' "$T/offer2.json"
check grep -q '"restore_pending":{"backup":"'"${BACKUP##*/}"'"' "$T/offer2.json"

echo "== restore, from the card"
bi restore "$BACKUP" | grep -v '^PROGRESS' | tee "$T/restore.out"
check grep -q '^DONE Restored' "$T/restore.out"
check [ "$(sum "$EMMC")" = "$ORIGINAL" ]
check [ "$(holds)" = trimui ]
check [ ! -e "$T/data/backups/restore-pending.json" ]
rm -r "$T"/data/backups/*
cp --sparse=always "$B/sd-card.img" "$T/card.img"  # as written

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
bi install >"$T/locked.out" || true
check grep -q '^FAIL another install, restore or update is already running' "$T/locked.out"
wait

echo "== run again, with a backup (of the unfinished install), followed from its start"
start again install --backup
wait_for again '/^STEP/ { found = 1 } END { exit !found }'
bi follow >"$T/follow.out"
wait $PID
check grep -q '^DONE Installed' "$T/again.out"
check cmp <(grep -v '^PROGRESS' "$T/again.out") <(grep -v '^PROGRESS' "$T/follow.out")
check [ "$(holds)" = this-system ]
check [ -z "$(ls -d "$T"/data/backups/*.partial 2>/dev/null)" ]
check grep -q '"holds": "unfinished-install"' "$T"/data/backups/internal-*/manifest.json
bi follow >"$T/follow-none.out"  # nothing runs: prints nothing
check [ ! -s "$T/follow-none.out" ]

echo "== a prepared restore, cancelled on the card: the card's boot0 erased again, the marker gone"
BACKUP=$(ls -d "$T"/data/backups/internal-*)
RUNNING=$EMMC bi restore "$BACKUP" | grep -v '^PROGRESS' >"$T/prepare2.out"
check grep -q '^DONE' "$T/prepare2.out"
bi restore --cancel | tee "$T/cancel.out"
check grep -q '^DONE The restore is cancelled' "$T/cancel.out"
check zeros < <(sectors "$T/card.img" 16 32784)
check [ ! -e "$T/data/backups/restore-pending.json" ]
check [ "$(holds)" = this-system ]

echo "== a restore cut short: recognised"
start cut-restore restore "$BACKUP"
cut_short cut-restore 'STEP 2/'
check [ "$(holds)" = unfinished-restore ]

echo "== a low battery stops install and restore (update: below)"
LOW=$(sum "$EMMC")
POWER=$T/low-power bi install >"$T/low-install.out" || true
POWER=$T/low-power bi restore "$BACKUP" >"$T/low-restore.out" || true
for t in install restore; do check grep -q '^FAIL the battery is at 30 %' "$T/low-$t.out"; done
check [ "$(sum "$EMMC")" = "$LOW" ]

# --- Update files ---------------------------------------------------------------------------
# version <name> <boot.img bytes...>: a version folder in $T/versions/<name> with that boot.img,
# a small root filesystem and a manifest as build-system.sh writes them.
version() {
	local d=$T/versions/$1; shift
	mkdir -p "$d"
	"$@" >"$d/boot.img"
	head -c 1M /dev/urandom >"$d/rootfs.squashfs"
	entry() { printf '"%s": { "size": %s, "sha256": "%s" }' "$1" "$(stat -c%s "$d/$1")" "$(sum "$d/$1")"; }
	printf '{ "version": "%s", "commit": "test", "built": "", "kernel": "", "release": false, "dt_edits": true,\n  "files": { %s, %s } }\n' \
		"${d##*/}" "$(entry boot.img)" "$(entry rootfs.squashfs)" >"$d/manifest.json"
}
sign() { "$ROOT/tools/system/sign-update.sh" "$T/versions/$1" "$T/${3:-key}.pem" "$T/updates/$2.update" >/dev/null; }
# A fresh card running $V, with nothing else installed.
fresh() {
	cp --sparse=always "$B/sd-card.img" "$T/card.img"
	rm -rf "$T/system/images" "$T/system/overlay"
	mkdir -p "$T/system/images/$V"
	cp "$B/system/$V"/{boot.img,rootfs.squashfs,manifest.json} "$T/system/images/$V/"
}
# The invariant a cut must keep: the slot U-Boot's settings name holds a complete boot.img of a
# version whose files in images/ are complete.
startable() {
	local slot at d
	slot=$(uboot "$T/card.img" boot_partition) && at=$(part "$T/card.img" "$slot" start)
	for d in "$T"/system/images/*/; do
		[[ $d = *.part/ ]] && continue
		cmp -s -n "$(stat -c%s "$d/boot.img")" <(sectors "$T/card.img" "$at" 65536) "$d/boot.img" || continue
		for f in boot.img rootfs.squashfs; do grep -q "\"$f\": { \"size\": [0-9]*, \"sha256\": \"$(sum "$d/$f")\"" "$d/manifest.json" || return 1; done
		return 0
	done
	return 1
}
V2=29991231-235959-0000002
mkdir -p "$T/updates"
version $V2 sh -c "cat '$B/system/$V/boot.img'; echo V2"
version 20000101-000000-0000000 sh -c "cat '$B/system/$V/boot.img'; echo old"
version 29991231-235959-0000003 head -c 33M /dev/zero  # more than a card's 32 MiB slot
# A version whose kernel doesn't make the device-tree changes itself.
OLD_DT=29991231-235959-0000004
version $OLD_DT sh -c "cat '$B/system/$V/boot.img'; echo old-dt"
sed -i 's/ "dt_edits": true,//' "$T/versions/$OLD_DT/manifest.json"
sign $V2 good
sign 20000101-000000-0000000 older
sign 29991231-235959-0000003 oversized
sign $OLD_DT no-dt-edits
sign $V2 other-key other-key
# Where manifest.sig's data starts in the good file: manifest.json's header at 0, its data at 512
# (padded to 512 bytes), then manifest.sig's header.
M=$(stat -c%s "$T/versions/$V2/manifest.json")
SIG_AT=$(( 512 + (M + 511) / 512 * 512 + 512 ))
cp "$T/updates/good.update" "$T/updates/bad-signature.update"
printf '\xff\xff\xff\xff' | dd of="$T/updates/bad-signature.update" bs=1 seek=$SIG_AT conv=notrunc status=none
cp "$T/updates/good.update" "$T/updates/damaged.update"
printf 'XXXX' | dd of="$T/updates/damaged.update" bs=1 seek=$(( SIG_AT + 512 + 512 + 4096 )) conv=notrunc status=none  # 4 KiB into boot.img
mkdir "$T/unpacked" && tar xf "$T/updates/good.update" -C "$T/unpacked"
tar --format=ustar -cf "$T/updates/wrong-order.update" -C "$T/unpacked" manifest.json boot.img manifest.sig rootfs.squashfs

echo "== update files that must change nothing"
fresh
CARD=$(sum "$T/card.img") IMAGES=$(ls "$T/system/images")
for u in bad-signature:"isn't signed" other-key:"isn't signed" damaged:damaged wrong-order:damaged oversized:'bigger than boot slot boot_b' no-dt-edits:'too old'; do
	bi update "$T/updates/${u%%:*}.update" | grep -v '^PROGRESS' | tee "$T/${u%%:*}.out" || true
	check grep -q "^FAIL .*${u#*:}" "$T/${u%%:*}.out"
	check [ "$(sum "$T/card.img")" = "$CARD" ]
	check [ "$(ls "$T/system/images")" = "$IMAGES" ]
done
POWER=$T/low-power bi update "$T/updates/good.update" >"$T/low-update.out" || true
check grep -q '^FAIL the battery is at 30 %' "$T/low-update.out"
check [ "$(sum "$T/card.img")" = "$CARD" ]

echo "== update files on the card, in the offer"
mkdir -p "$T/data/updates"
cp "$T/updates/good.update" "$T/updates/older.update" "$T/updates/other-key.update" "$T/data/updates/"
bi offer | tee "$T/offer-updates.json"
check grep -q '"file":"[^"]*good.update","older":false,"problem":null,"version":"'$V2'"' "$T/offer-updates.json"
check grep -q '"older":true,"problem":null,"version":"20000101-000000-0000000"' "$T/offer-updates.json"
check grep -q '"file":"[^"]*other-key.update","older":false,"problem":"[^"]*isn.t signed' "$T/offer-updates.json"
rm -r "$T/data/updates"

echo "== an update: copied, written to boot_b, U-Boot switched to it"
bi update "$T/updates/good.update" | grep -v '^PROGRESS' | tee "$T/update.out"
check grep -q "^DONE Version $V2 starts at the next restart" "$T/update.out"
check [ "$(uboot "$T/card.img" boot_partition)" = boot_b ]
check cmp -n "$(stat -c%s "$T/versions/$V2/boot.img")" <(sectors "$T/card.img" 165888 65536) "$T/versions/$V2/boot.img"
check cmp "$T/system/images/$V2/rootfs.squashfs" "$T/versions/$V2/rootfs.squashfs"
bi slots | tee "$T/slots.out"
check [ "$(cat "$T/slots.out")" = "$(printf 'boot_a %s running\nboot_b %s previous\nnext boot_b' $V $V2)" ]

echo "== another update before a restart: the settings are pointed away from the slot before it is overwritten"
BRICK_INSTALL_CUT=slot-written bi update "$T/updates/older.update" >"$T/cut.out" 2>&1 || true
check grep -q 'cut at slot-written' "$T/cut.out"
check [ "$(uboot "$T/card.img" boot_partition)" = boot_a ]
check startable
fresh
bi update "$T/updates/good.update" | grep -v '^PROGRESS' >"$T/update.out"

echo "== the running version activated after an update: the settings name its slot again, nothing else changes"
SLOTS=$(sectors "$T/card.img" 100352 131072 | sha256sum) IMAGES=$(ls "$T/system/images")
bi activate $V | grep -v '^PROGRESS' | tee "$T/activate-running.out"
check grep -q "^DONE Version $V is running, and stays the one that starts" "$T/activate-running.out"
check [ "$(uboot "$T/card.img" boot_partition)" = boot_a ]
check [ "$(sectors "$T/card.img" 100352 131072 | sha256sum)" = "$SLOTS" ]
check [ "$(ls "$T/system/images")" = "$IMAGES" ]

echo "== back to the previous version, after a restart into the new one: only the settings change"
SLOTS=$(sectors "$T/card.img" 100352 131072 | sha256sum)
VER=$V2 SLOT=boot_b bi activate $V | grep -v '^PROGRESS' | tee "$T/activate.out"
check grep -q "^DONE Version $V starts at the next restart" "$T/activate.out"
check [ "$(uboot "$T/card.img" boot_partition)" = boot_a ]
check [ "$(sectors "$T/card.img" 100352 131072 | sha256sum)" = "$SLOTS" ]
check [ "$(ls "$T/system/images" | sort)" = "$(printf '%s\n' $V2 $V | sort)" ]

echo "== a version without the kernel's device-tree changes, installed: it can't be activated"
fresh
cp -r "$T/versions/$OLD_DT" "$T/system/images/"
CARD=$(sum "$T/card.img")
bi activate $OLD_DT >"$T/activate-old-dt.out" || true
check grep -q "^FAIL version $OLD_DT is too old" "$T/activate-old-dt.out"
check [ "$(sum "$T/card.img")" = "$CARD" ]

echo "== updates cut short at each write that matters: the device still starts, and it can run again"
for cut in slot-written:boot_a env-1-torn:boot_a env-1:boot_b env-2-torn:boot_b env-2:boot_b; do
	fresh
	BRICK_INSTALL_CUT=${cut%:*} bi update "$T/updates/good.update" >"$T/cut.out" 2>&1 || true
	check grep -q "cut at ${cut%:*}" "$T/cut.out"
	check [ "$(uboot "$T/card.img" boot_partition)" = ${cut#*:} ]
	check startable
	bi update "$T/updates/good.update" | grep -v '^PROGRESS' >"$T/cut-again.out"
	check grep -q "^DONE Version $V2" "$T/cut-again.out"
	check [ "$(uboot "$T/card.img" boot_partition)" = boot_b ]
	check startable
done
# A copy cut short leaves <version>.part (too quick here to cut reliably, so made by hand); the
# next update deletes it.
fresh
mkdir "$T/system/images/$V2.part" && head -c 1M /dev/urandom >"$T/system/images/$V2.part/boot.img"
bi update "$T/updates/good.update" | grep -v '^PROGRESS' >"$T/copy-again.out"
check grep -q "^DONE Version $V2" "$T/copy-again.out"
check [ ! -e "$T/system/images/$V2.part" ]
echo PASS
