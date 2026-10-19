#!/bin/sh
# The init of test-exfat.sh's QEMU guest: runs one test phase on the virtual disk /dev/vda with the
# device's own tools and mount options, prints "ok <check>" or "FAIL: <check>" per check, then
# powers off. The phase is the kernel command line's test=:
#   functional  format the disk, then file operations, preallocated files, timestamps, loop images
#   options     mount-card's mount options; which remounts the driver accepts
#   cut         writes, saves and mkdir/rm until a reset 3-14 s in, as if power were cut
#   after-cut   fsck.exfat -n; if it finds errors, repair with -p as mount-card does; check the save
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mount -t tmpfs tmp /tmp
D=/dev/vda M=/mnt IO=/test-exfat-io
. /usr/libexec/brick/card-options
OPTS=$(card_options exfat 33)	# 33: www-data's group, as mount-card passes it

say() { echo "TEST: $*"; }
# check NAME COMMAND: runs COMMAND (a string, evaluated) and reports NAME.
check() { if eval "$2"; then echo "ok $1"; else echo "FAIL: $1"; fi; }
# fsck_n: fsck.exfat -n, its output shown when it finds something.
fsck_n() {
	fsck.exfat -n $D >/tmp/fsck 2>&1; rc=$?
	say "fsck.exfat -n exit $rc"; [ $rc = 0 ] || sed 's/^/  | /' /tmp/fsck
	return $rc
}
finish() { say "done"; sync; poweroff -f; }

phase=$(sed -n 's/.*test=\([a-z-]*\).*/\1/p' /proc/cmdline)
case $phase in
functional)
	mkfs.exfat -L BRICK $D >/dev/null || echo "FAIL: mkfs.exfat"
	check "fsck after mkfs" fsck_n
	check "mount" "mount -t exfat -o $OPTS $D $M"
	head -c 20000000 /dev/urandom >/tmp/rand
	cp /tmp/rand $M/big.bin
	check "big file" "cmp /tmp/rand $M/big.bin"
	mkdir -p $M/Roms/GBA; echo x >"$M/Roms/GBA/Pokémon Émeraude.gba"
	check "names matched regardless of case" "[ -f '$M/roms/gba/POKÉMON émeraude.gba' ]"
	long=$(printf 'n%.0s' $(seq 255))
	check "255-character name" "touch $M/$long"
	check "256-character name refused" "! touch $M/${long}x 2>/dev/null"
	echo old >$M/s.dat; echo new >$M/s.tmp; mv $M/s.tmp $M/s.dat
	check "rename over a file" "[ \"\$(cat $M/s.dat)\" = new ] && [ ! -e $M/s.tmp ]"
	check "200 saves" "$IO save $M 200 && head -1 $M/save.dat | grep -q 'save 00000199'"
	for i in $(seq 50); do mkdir $M/d$i && echo $i >$M/d$i/f; done; rm -r $M/d*
	check "mkdir and rm -r" "! ls -d $M/d* 2>/dev/null"
	check "rmdir of a full directory refused" "mkdir $M/full && touch $M/full/f && ! rmdir $M/full 2>/dev/null"
	# A preallocated file: its size runs past the written data (at 10000), as Windows and macOS
	# leave them. Bytes 8192-16383 straddle the end of the data.
	head -c 10000 /tmp/rand >$M/pre.bin; truncate -s 3000000 $M/pre.bin
	{ dd if=/tmp/rand bs=1 skip=8192 count=1808 2>/dev/null; head -c 6384 /dev/zero; } >/tmp/expected
	check "preallocated: data then zeros" "dd if=$M/pre.bin bs=8192 skip=1 count=1 2>/dev/null | cmp - /tmp/expected"
	check "preallocated: O_DIRECT read" "$IO direct-read $M/pre.bin 8192 8192 | cmp - /tmp/expected"
	check "preallocated: mmap write" "$IO mmap-write $M/pre.bin 2000000 && [ \"\$(dd if=$M/pre.bin bs=1 skip=2000000 count=4 2>/dev/null)\" = MMAP ]"
	echo tail >>$M/pre.bin
	check "preallocated: append" "[ \$(stat -c %s $M/pre.bin) = 3000005 ]"
	truncate -s 100 $M/big.bin
	check "shrink" "[ \$(stat -c %s $M/big.bin) = 100 ] && cmp -n 100 $M/big.bin /tmp/rand"
	cp /tmp/rand $M/b2; mv $M/b2 $M/Roms/
	check "move to another directory" "cmp /tmp/rand $M/Roms/b2"
	touch -d '1970-01-02 00:00:00' $M/early; touch -d '2200-01-01 00:00:00' $M/late
	sum=$(cat $M/Roms/b2 $M/pre.bin $M/save.dat | sha256sum)
	check "unmount" "umount $M"
	check "fsck after use" fsck_n
	# Read back from the disk, not from memory (read-only: nothing is written from here on).
	mount -t exfat -o ro $D $M
	check "same data after remounting" "[ \"\$(cat $M/Roms/b2 $M/pre.bin $M/save.dat | sha256sum)\" = \"$sum\" ]"
	check "preallocated from disk: data then zeros" "dd if=$M/pre.bin bs=8192 skip=1 count=1 2>/dev/null | cmp - /tmp/expected"
	check "preallocated from disk: O_DIRECT read" "$IO direct-read $M/pre.bin 8192 8192 | cmp - /tmp/expected"
	check "preallocated from disk: zeros after the mmap write" "[ \$(dd if=$M/pre.bin bs=1 skip=2000004 count=999996 2>/dev/null | tr -d '\\0' | wc -c) = 0 ]"
	check "times before 1980 stored as 1980" "[ \"\$(date -u -r $M/early +%Y)\" = 1980 ]"
	check "times after 2107 stored as 2107" "[ \"\$(date -u -r $M/late +%Y)\" = 2107 ]"
	umount $M
	truncate -s 64M /tmp/img; mkfs.exfat /tmp/img >/dev/null; mkdir /tmp/loop
	check "loop image" "mount -t exfat -o loop /tmp/img /tmp/loop && cp /tmp/rand /tmp/loop/r && umount /tmp/loop && fsck.exfat -n /tmp/img >/dev/null"
	finish ;;
options)
	mkfs.exfat $D >/dev/null
	check "mount-card's options" "mount -t exfat -o $OPTS $D $M"
	echo x >$M/f
	check "files group 33, mode 775" "[ \"\$(stat -c '%g %a' $M/f)\" = '33 775' ]"
	# A remount must repeat the options the driver can't change while mounted (super.c).
	check "remount leaving out sys_tz refused" "! $IO remount-ro $M '' 2>/dev/null"
	check "remount repeating sys_tz" "$IO remount-ro $M sys_tz"
	umount $M
	check "unknown option refused" "! mount -t exfat -o bogus $D $M 2>/dev/null"
	finish ;;
cut)
	mount -t exfat -o $OPTS $D $M || echo "FAIL: mount"
	mkdir -p $M/s
	$IO save $M/s 0 &
	( i=0; while :; do
		i=$((i + 1)); mkdir -p $M/s/d$i
		dd if=/dev/urandom of=$M/s/d$i/f bs=64k count=$((i % 16 + 1)) 2>/dev/null
		[ $i -le 3 ] || rm -rf $M/s/d$((i - 3))
	done ) &
	( while :; do dd if=/dev/zero of=$M/s/stream bs=1M count=40 2>/dev/null; rm $M/s/stream; done ) &
	t=$(($(head -c 2 /dev/urandom | od -An -tu2) % 12 + 3))
	say "cutting power after ${t}s"
	sleep $t
	# Resets at once, without syncing or unmounting.
	echo 1 >/proc/sys/kernel/sysrq; echo b >/proc/sysrq-trigger ;;
after-cut)
	if ! fsck_n; then
		fsck.exfat -p $D >/tmp/repair 2>&1; say "fsck.exfat -p exit $?"
		check "clean after repair" fsck_n
	fi
	check "mount" "mount -t exfat -o $OPTS $D $M"
	check "last save whole" "[ \$(stat -c %s $M/s/save.dat) = 8192 ] && head -1 $M/s/save.dat | grep -q '^save '"
	umount $M
	finish ;;
*)
	echo "FAIL: unknown phase '$phase'" ;;
esac
poweroff -f
