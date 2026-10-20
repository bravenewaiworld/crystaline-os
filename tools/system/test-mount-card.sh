#!/bin/bash
# Tests mount-card (system/board/brick/rootfs-overlay/usr/libexec/brick/mount-card) on the PC: the
# real script runs against a fake root (MOUNT_CARD_ROOT): a fake sysfs and mount table, and image
# files standing in for the card's disk and partitions: each partition is its own image file
# (pN.img), and disk.img holds only the partition table. mount, umount, partx, sv, logger, id and
# poweroff are stubs that record their calls; blkid, sfdisk, flock, fsck.fat, mkfs.fat and
# fsck.exfat are the PC's own, run on the image files (sfdisk, mkfs.fat, fsck.fat and fsck.exfat
# wrapped to record their calls; mkfs.exfat only makes test cards). With BusyBox on the PATH (make
# test-mount-card builds the device's, tools/system/pc-busybox.sh), the script runs under BusyBox's
# shell and text tools (awk, grep, sed, …), as on the device; without it, under the PC's.
# Refuses to run as root, so that a missed stub can't run the PC's own mount, partx or poweroff.
# Needs dosfstools; the exFAT cases need exfatprogs and are skipped without it. Prints PASS or the
# first failure.
# Usage: test-mount-card.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=$ROOT/system/board/brick/rootfs-overlay/usr/libexec/brick/mount-card
[ "$(id -u)" != 0 ] || { echo "run this as a normal user" >&2; exit 1; }
PATH=$PATH:/usr/sbin:/sbin
for t in blkid sfdisk flock fsck.fat mkfs.fat; do
	command -v $t >/dev/null || { echo "needs $t on the PC (util-linux, dosfstools)" >&2; exit 1; }
done
EXFAT=$(command -v mkfs.exfat >/dev/null && command -v fsck.exfat >/dev/null && echo 1 || true)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R=$T/root
SDC0=$R/sys/bus/platform/devices/sdc0/mmc_host/mmc1/mmc1:0001/block

# --- Stubs and wrappers (first on the script's PATH) ---
mkdir -p $T/bin $T/cards
# stub NAME BODY: a stub that records its call (paths without the fake root) and then runs BODY.
stub() {
	printf '#!/bin/sh\necho "%s $*" | sed "s|$MOUNT_CARD_ROOT||g" >>$TEST_DIR/calls\n%s\n' "$1" "$2" >$T/bin/$1
	chmod +x $T/bin/$1
}
# wrap NAME [BODY]: records the call, runs BODY (which may use $REAL, the PC's NAME), then $REAL.
# Exits 8 (fsck's "couldn't run") if the PC has no NAME.
wrap() { stub $1 "REAL=$(command -v $1 || echo false)
${2-}
[ \$REAL != false ] || exit 8
exec \$REAL \"\$@\""; }
# logger [-s] [-t TAG] MSG: MSG to $TEST_DIR/log (shown on a failure) and stderr.
printf '#!/bin/sh\n[ "$1" = -s ] && shift; [ "$1" = -t ] && shift 2; echo "$*" >>$TEST_DIR/log; echo "$*" >&2\n' >$T/bin/logger
chmod +x $T/bin/logger
stub sv ''
stub poweroff 'sed -n 1p $MOUNT_CARD_ROOT/run/card/state >$TEST_DIR/state-at-poweroff'
stub id 'echo 33'	# www-data's group, as on the device
# mount -t TYPE -o OPTIONS DEVICE DIR: fails as the kernel would for a missing device or another
# filesystem type (or when told to, $TEST_DIR/mount-fails); else adds a line to mountinfo, with
# the filesystem's own options (the last field) only "rw" or "ro".
stub mount '[ ! -e $TEST_DIR/mount-fails ] || exit 32
num=$(cat $MOUNT_CARD_ROOT/sys/class/block/${5##*/}/dev) || exit 32
[ "$(blkid -p -o value -s TYPE $5)" = $2 ] || exit 32
case ,$4, in *,ro,*) sb=ro ;; *) sb=rw ;; esac
echo "99 17 $num / $6 $sb,noatime - $2 ${5#$MOUNT_CARD_ROOT} $sb" >>$MOUNT_CARD_ROOT/proc/self/mountinfo'
# umount [-l] DIR
stub umount 'eval dir=\${$#}; mi=$MOUNT_CARD_ROOT/proc/self/mountinfo
grep -q " $dir " $mi || exit 1
awk -v m=$dir '"'"'$5 != m'"'"' $mi >$mi.new && mv $mi.new $mi'
# fake-partition DISK N: the kernel's view of partition N of DISK (sysfs entry, device file),
# from the card's partition table. Makes the partition's image file (zeroed, sized from the table)
# if there is none yet, e.g. for a partition sfdisk just added.
cat >$T/bin/fake-partition <<'EOF'
#!/bin/sh
R=$MOUNT_CARD_ROOT disk=$1 n=$2
img=$(readlink -f $R/dev/$disk)
line=$(sfdisk --dump $img | grep "^[^ ]*[^0-9]$n : ")
size=$(echo "$line" | sed 's/.*size= *\([0-9]*\).*/\1/')
name=$(echo "$line" | sed -n 's/.*name="\([^"]*\)".*/\1/p')
[ -e ${img%/*}/p$n.img ] || truncate -s $((size * 512)) ${img%/*}/p$n.img
ln -sfn ${img%/*}/p$n.img $R/dev/${disk}p$n
d=$R/sys/block/$disk/${disk}p$n
mkdir -p $d
echo 179:$(($(cut -d: -f2 $R/sys/block/$disk/dev) + n)) >$d/dev
{ echo PARTN=$n; [ -z "$name" ] || echo PARTNAME=$name; } >$d/uevent
ln -sfn $d $R/sys/class/block/${disk}p$n
EOF
chmod +x $T/bin/fake-partition
# partx --add --nr N DISK; fails when told to ($TEST_DIR/partx-fails).
stub partx '[ ! -e $TEST_DIR/partx-fails ] || exit 1; exec fake-partition ${4##*/} $3'
wrap sfdisk
wrap mkfs.fat
# $TEST_DIR/slow-fsck: takes a second, noting when it starts and ends (to see runs overlapping).
wrap fsck.fat 'if [ -e $TEST_DIR/slow-fsck ]; then
	echo begin >>$TEST_DIR/fsck-trace; touch $TEST_DIR/fsck-started; sleep 1
	$REAL "$@"; rc=$?; echo end >>$TEST_DIR/fsck-trace; exit $rc
fi'
# $TEST_DIR/fsck-exit: exit with that code instead of checking.
wrap fsck.exfat '[ ! -s $TEST_DIR/fsck-exit ] || exit $(cat $TEST_DIR/fsck-exit)'

if command -v busybox >/dev/null; then
	SH="busybox sh" P=$T/bin:$T/bb:$PATH
	mkdir $T/bb
	for a in awk cat cmp cp cut date dd grep head ls mkdir mv rm sed sleep sort wc; do ln -s "$(command -v busybox)" $T/bb/$a; done
else
	echo "no BusyBox on the PATH: testing with the PC's shell and tools" >&2
	SH=sh P=$T/bin:$PATH
fi

# --- The fake device ---
# new_root DEV: a fresh fake root with no card, /system mounted from device number DEV (179:5 is
# the eMMC's partition 5; 179:39 is partition 7 of a card numbered 179:32, as the kernel numbers
# the first card; the next disk is 179:64). new_root, then insert, stands for a start with that
# card in.
new_root() {
	rm -rf "${R:?}"
	mkdir -p $R/proc/self $R/sys/block $R/sys/class/block $SDC0 $R/dev $R/mnt/SDCARD $R/system $R/run
	# The eMMC's disk and partition 5, so that an eMMC system's /system (179:5) exists.
	for d in mmcblk0:0 mmcblk0p5:5; do mkdir $R/sys/class/block/${d%:*}; echo 179:${d#*:} >$R/sys/class/block/${d%:*}/dev; done
	: >$R/dev/kmsg
	# The guide texts mount-card copies onto the card.
	mkdir -p $R/usr/share/brick && cp -r $ROOT/system/board/brick/rootfs-overlay/usr/share/brick/card-guides $R/usr/share/brick/
	echo "17 1 $1 / $R/system rw,noatime - ext4 /dev/system rw" >$R/proc/self/mountinfo
	: >$T/calls
}
# insert CARD MINOR [RO]: CARD ($T/cards/CARD: disk.img, pN.img, cid) appears as mmcblk1, numbered
# 179:MINOR; RO=1: it reports itself read-only.
insert() {
	local c=$T/cards/$1 b=$SDC0/mmcblk1 n
	mkdir -p $b/device
	echo 179:$2 >$b/dev; echo ${3:-0} >$b/ro; cp $c/cid $b/device/cid
	ln -sfn $b $R/sys/block/mmcblk1; ln -sfn $b $R/sys/class/block/mmcblk1; ln -sfn $c/disk.img $R/dev/mmcblk1
	for n in $(sfdisk --dump $c/disk.img | sed -n 's/^[^ ]*[^0-9]\([0-9]*\) : .*/\1/p'); do
		MOUNT_CARD_ROOT=$R $T/bin/fake-partition mmcblk1 $n
	done
}
pull() { rm -rf "${SDC0:?}/mmcblk1" $R/sys/block/mmcblk1 $R/sys/class/block/mmcblk1* $R/dev/mmcblk1*; }

# --- Cards ---
# new_card NAME MiB: an empty card with a CID of its own.
new_card() {
	mkdir -p $T/cards/$1
	truncate -s $2M $T/cards/$1/disk.img
	echo $1 | sha256sum | cut -c1-32 >$T/cards/$1/cid
}
# system_card NAME [MiB]: a card as `make sd-card` writes it (tools/sdboot/build_sd_image.sh's
# layout, with a small system partition, p7), before its first start: no data partition.
system_card() {
	new_card $1 ${2:-300}
	sfdisk --quiet $T/cards/$1/disk.img <<-EOF
	label: gpt
	table-length: 16
	first-lba: 40960
	start=40960, size=49152, name=bootloader
	start=90112, size=2048, name=env
	start=98304, size=2048, name=env-redund
	start=100352, size=65536, name=boot_a
	start=165888, size=65536, name=boot_b
	start=231424, size=2048, name=pstore
	start=233472, size=32768, name=system
	EOF
	truncate -s 24M $T/cards/$1/p1.img; mkfs.fat -n BOOTLOADER $T/cards/$1/p1.img >/dev/null
}
# fat_card NAME LAYOUT [TYPE]: a PC-formatted card, FAT32 or exFAT (TYPE exfat): one partition
# (LAYOUT mbr), the whole card (whole), or a GPT partition named "sdcard" (sdcard).
fat_card() {
	local c=$T/cards/$1 f=$T/cards/$1/p1.img
	new_card $1 200
	case $2 in
	mbr)	echo 'start=2048, type=c' | sfdisk --quiet $c/disk.img ;;
	sdcard)	printf 'label: gpt\nstart=2048, name=sdcard\n' | sfdisk --quiet $c/disk.img ;;
	whole)	f=$c/disk.img ;;
	esac
	# Fills the partition: the card less the 1 MiB before it and (GPT) the backup table at the end.
	[ $2 = whole ] || truncate -s $(( (200 - 1) * 1024 * 1024 - 33 * 512 )) $f
	if [ "${3-}" = exfat ]; then mkfs.exfat $f >/dev/null; else mkfs.fat -F 32 $f >/dev/null; fi
}
# FAT32 damage: dirty IMG sets the "not unmounted cleanly" mark, as Linux does on mounting; lost IMG
# marks cluster 1000 used with no file holding it; garbage IMG overwrites the boot sector.
dirty() { printf '\001' | dd of=$1 bs=1 seek=65 conv=notrunc status=none; }
lost() {
	local rs fs; rs=$(od -An -tu2 -j14 -N2 $1) fs=$(od -An -tu4 -j36 -N4 $1)
	for at in $((rs * 512 + 4000)) $(((rs + fs) * 512 + 4000)); do
		printf '\377\377\377\017' | dd of=$1 bs=1 seek=$at conv=notrunc status=none
	done
}
garbage() { { yes garbage || true; } | head -c 512 | dd of=$1 conv=notrunc status=none; }
sum() { sha256sum $1 | cut -d' ' -f1; }

# --- Running and checking ---
# run ARGS: runs mount-card once; no run may leave state.new behind.
run() {
	MOUNT_CARD_ROOT=$R TEST_DIR=$T PATH=$P $SH $SCRIPT "$@" 2>>$T/stderr || true
	[ ! -e $R/run/card/state.new ] || fail "state.new left behind"
}
event() { SEQNUM=1 ACTION=$1 MDEV=mmcblk1 run event; }	# what mdev runs
fail() {
	echo "FAIL ($CASE): $*" >&2
	for f in $R/run/card/state $T/calls $T/log $T/stderr; do echo "--- $f" >&2; tail -20 $f >&2 2>/dev/null || true; done
	exit 1
}
case_() { CASE=$*; echo "== $CASE"; : >$T/log; }
# state LINE1 [DETAIL...]: the state file's first line is LINE1 and its third holds each DETAIL
# (e.g. check=clean). Line 2, the message, must be there for every state but a plain "mounted".
state() {
	local f=$R/run/card/state d
	[ "$(sed -n 1p $f)" = "$1" ] || fail "state '$(sed -n 1p $f 2>/dev/null)', expected '$1'"
	[ "$1" = mounted ] || [ -n "$(sed -n 2p $f)" ] || fail "no message for '$1'"
	shift; for d; do sed -n 3p $f | tr ' ' '\n' | grep -qx -- "$d" || fail "details '$(sed -n 3p $f)' lack $d"; done
}
message_has() { sed -n 2p $R/run/card/state | grep -q -- "$1" || fail "message '$(sed -n 2p $R/run/card/state)' lacks '$1'"; }
# called PATTERN: some recorded call starts with PATTERN (a regular expression); not_called: none.
called() { grep -q -- "^$1" $T/calls || fail "no call like '$1'"; }
not_called() { ! grep -q -- "^$1" $T/calls || fail "unexpected call: $(grep -- "^$1" $T/calls | head -1)"; }
mounted_at() { awk -v m=$R/mnt/SDCARD '$5 == m { print $3 }' $R/proc/self/mountinfo; }

# --- Cases ---
case_ "1. no card: absent, after waiting at start-up"
new_root 179:5
run start
state absent
not_called mount

case_ "2. a fresh system card: data partition made and formatted, mounted"
system_card sys
new_root 179:39; insert sys 32
run start
state mounted partition=mmcblk1p8 type=vfat check=clean
called 'partx --add --nr 8 /dev/mmcblk1'
called 'mkfs.fat -F 32 -n BRICK /dev/mmcblk1p8'
called 'mount -t vfat -o rw,noatime,flush,iocharset=iso8859-1,utf8,errors=remount-ro,gid=33,umask=0002 /dev/mmcblk1p8 /mnt/SDCARD'
[ "$(mounted_at)" = 179:40 ] || fail "mounted $(mounted_at), expected 179:40"
for d in roms bios saves updates; do [ -d $R/mnt/SDCARD/$d ] || fail "no $d/"; done
sfdisk --dump $T/cards/sys/disk.img | grep -q 'img8 : .*name="sdcard"' || fail "no sdcard partition in the table"
sfdisk --verify $T/cards/sys/disk.img >/dev/null 2>&1 || fail "partition table doesn't verify"

case_ "3. the same card again: nothing formatted; then shutdown unmounts"
before=$(sum $T/cards/sys/p8.img)
new_root 179:39; insert sys 32
run start
state mounted partition=mmcblk1p8 check=clean
not_called mkfs.fat; not_called partx
[ "$(sum $T/cards/sys/p8.img)" = "$before" ] || fail "data partition changed"
: >$T/calls; run stop
called 'umount /mnt/SDCARD'
[ -z "$(mounted_at)" ] || fail "still mounted"

case_ "4. system on the eMMC: a PC-formatted card, with a partition table and without; refused"
fat_card mbr mbr
new_root 179:5; insert mbr 32
run start
state mounted partition=mmcblk1p1 type=vfat check=clean
fat_card whole whole
new_root 179:5; insert whole 32
run start
state mounted partition=mmcblk1 type=vfat check=clean
touch $T/mount-fails	# the kernel refuses it
new_root 179:5; insert mbr 32
run start
state "failed mount"
rm $T/mount-fails

case_ "5. our written card with the system on the eMMC: not set up yet, nothing changed"
system_card written
before=$(sum $T/cards/written/disk.img)
new_root 179:5; insert written 32
run start
state "failed not-set-up"
message_has "Restart the Brick with this card in"
not_called sfdisk; not_called mkfs.fat; not_called mount
[ "$(sum $T/cards/written/disk.img)" = "$before" ] || fail "card changed"

case_ "6. unclean removal, then a lost cluster: checked, repaired, logged on the card"
dirty $T/cards/mbr/p1.img
new_root 179:5; insert mbr 32
run start
state mounted check=unclean
grep -q '^== .* mmcblk1p1 (vfat): unclean$' $R/mnt/SDCARD/logs/card-check.log || fail "unclean check not logged on the card"
lost $T/cards/mbr/p1.img
new_root 179:5; insert mbr 32
run start
state mounted check=repaired
message_has logs/card-check.log
grep -q 'Reclaimed' $R/mnt/SDCARD/logs/card-check.log || fail "repair not logged on the card"
new_root 179:5; insert mbr 32
run start
state mounted check=clean

case_ "7. an unreadable \"sdcard\" partition on another card: not formatted"
fat_card badsd sdcard
garbage $T/cards/badsd/p1.img
before=$(sum $T/cards/badsd/p1.img)
new_root 179:5; insert badsd 32
run start
state "failed no-partition"
not_called mkfs.fat; not_called mount
[ "$(sum $T/cards/badsd/p1.img)" = "$before" ] || fail "partition changed"

case_ "8. a card that reports itself read-only: mounted read-only, not checked"
new_root 179:5; insert mbr 32 1
run start
state "read-only write-protected" check=not-run
called 'mount -t vfat -o .*,ro /dev/mmcblk1p1'
not_called fsck.fat
[ ! -e $R/mnt/SDCARD/roms ] && [ ! -e $R/mnt/SDCARD/README.txt ] || fail "folders or guides made on a read-only card"

if [ -n "$EXFAT" ]; then
	case_ "9. exFAT: mounted, or read-only when the check leaves errors or can't run"
	fat_card ex mbr exfat
	new_root 179:5; insert ex 32
	run start
	state mounted type=exfat check=clean
	called 'fsck.exfat -p /dev/mmcblk1p1'
	called 'mount -t exfat -o rw,noatime,iocharset=utf8,errors=remount-ro,sys_tz,gid=33,umask=0002 /dev/mmcblk1p1'
	echo 4 >$T/fsck-exit
	new_root 179:5; insert ex 32
	run start
	state "read-only damaged" check=errors-left
	called 'mount -t exfat -o .*,ro '
	echo 8 >$T/fsck-exit
	new_root 179:5; insert ex 32
	run start
	state "read-only unchecked" check=not-run
	rm $T/fsck-exit
else
	echo "== 9. exFAT: SKIPPED (no mkfs.exfat/fsck.exfat on this PC: exfatprogs)"
fi

case_ "10. the card removed: released, WebDAV stopped"
new_root 179:5; insert mbr 32
run start
pull; : >$T/calls
event remove
state absent
called 'umount -l /mnt/SDCARD'
called 'sv down webdav'
[ -z "$(mounted_at)" ] || fail "still mounted"

case_ "11. a card swapped with no run between: the old one released, the new one mounted"
fat_card other mbr
new_root 179:5; insert mbr 32
run start
pull; insert other 64; : >$T/calls
event add
state mounted card=$(cat $T/cards/other/cid) partition=mmcblk1p1
called 'umount -l /mnt/SDCARD'
[ "$(mounted_at)" = 179:65 ] || fail "mounted $(mounted_at), expected 179:65"

case_ "12. the kernel made the mounted card read-only after an error"
new_root 179:5; insert mbr 32
run start
sed -i '/SDCARD/s/ rw$/ ro/' $R/proc/self/mountinfo	# as errors=remount-ro: only the last field
run
state "read-only damaged" partition=mmcblk1p1 type=vfat check=clean
message_has "insert it again"
cp $R/run/card/state $T/state.before; : >$T/calls
run
cmp -s $R/run/card/state $T/state.before || fail "state rewritten"
[ ! -s $T/calls ] || fail "calls on a run with nothing to do: $(cat $T/calls)"

case_ "13. the system's own card removed, a stranger's card inserted: nothing done to it"
system_card stranger
before=$(sum $T/cards/stranger/disk.img)
new_root 179:39; insert sys 32
run start
state mounted
pull; insert stranger 64; : >$T/calls
event add
state "failed system-card-removed"
called 'poweroff -f'
[ "$(cat $T/state-at-poweroff)" = "failed system-card-removed" ] || fail "turned off before reporting it"
grep -q 'holding the system was removed' $R/dev/kmsg || fail "nothing in kmsg"
not_called sfdisk; not_called partx; not_called mkfs.fat; not_called fsck.fat; not_called mount
[ "$(sum $T/cards/stranger/disk.img)" = "$before" ] || fail "stranger's card changed"

case_ "14. a first start cut short before formatting: formatted; a damaged one isn't; making it fails, or the card is too small"
system_card cut
printf 'size=+, name=sdcard\n' | sfdisk --quiet --append $T/cards/cut/disk.img	# no filesystem yet
new_root 179:39; insert cut 32
run start
state mounted partition=mmcblk1p8 type=vfat
called 'mkfs.fat -F 32 -n BRICK /dev/mmcblk1p8'
garbage $T/cards/cut/p8.img	# its main boot sector damaged, the backup boot sector intact
before=$(sum $T/cards/cut/p8.img)
new_root 179:39; insert cut 32; : >$T/calls
run start
state "failed no-partition"
not_called mkfs.fat
[ "$(sum $T/cards/cut/p8.img)" = "$before" ] || fail "damaged partition changed"
system_card fails
touch $T/partx-fails
new_root 179:39; insert fails 32
run start
state "failed partition"
rm $T/partx-fails
system_card tiny 150	# 20 MiB after the system partition
new_root 179:39; insert tiny 32
run start
state "failed too-small"
message_has "at least 2 GB"
not_called partx; not_called mkfs.fat

case_ "15. two runs at once, the card pulled during the check: they take turns, absent"
new_root 179:5; insert mbr 32
touch $T/slow-fsck; : >$T/fsck-trace
event add & a=$!
run & b=$!
until [ -e $T/fsck-started ]; do sleep 0.05; done
pull
wait $a $b
rm $T/slow-fsck
state absent
not_called mount
# Without the lock, both runs would begin a check before the pull: "begin begin".
[ -z "$(uniq -d $T/fsck-trace)" ] || fail "checks overlapped: $(paste -sd' ' $T/fsck-trace)"

case_ "16. guide files: written where their folder exists, rewritten only when they differ"
G=$R/usr/share/brick/card-guides
fat_card guide mbr
new_root 179:5; insert guide 32
run start
state mounted
cmp -s $G/README.txt $R/mnt/SDCARD/README.txt || fail "README.txt not written"
cmp -s $G/updates/README.txt $R/mnt/SDCARD/updates/README.txt || fail "updates/README.txt not written"
[ ! -e $R/mnt/SDCARD/backups ] || fail "backups/ made"
grep -q "wrote README.txt" $T/log || fail "writing not logged"
# Unmounted and mounted again (no argument: make the mount match the slot). The fake mount leaves
# the folder's files, which stand in for the card's copies: nothing is rewritten. Then backups/
# appears, and an outdated root guide is replaced.
run stop; : >$T/log; run
state mounted
! grep -q "wrote" $T/log || fail "guides rewritten unchanged: $(grep wrote $T/log)"
mkdir $R/mnt/SDCARD/backups; echo old >$R/mnt/SDCARD/README.txt
run stop; run
cmp -s $G/README.txt $R/mnt/SDCARD/README.txt || fail "outdated README.txt not replaced"
cmp -s $G/backups/README.txt $R/mnt/SDCARD/backups/README.txt || fail "backups/README.txt not written"

case_ "17. no state.new left behind: checked after every run above"
echo PASS
