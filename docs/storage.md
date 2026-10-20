# Storage

Status: In progress · Updated: 2026-10-19

The Brick's two disks, the microSD card and the 8 GB internal eMMC: how they are driven, how our code tells them apart, and the filesystem of the card's data partition, where all user data lives ([system-image.md](system-image.md)). The SD card is also the game library's read path, so its speed matters, and the data partition must stay readable by any PC.

## Decisions

- **The SD card runs at UHS SDR104 (150 MHz, 1.8 V signalling), as on stock** (2026-10-11). This needed the A133's built-in supply switch for the SD pins (port F), which our kernel source only drove for other chips.
- **The eMMC runs at stock's settings: 8-bit DDR52, 50 MHz, the driver's default sample delays** (2026-10-14). These are the limits U-Boot sets when TrimUI's system starts from the eMMC; the device tree for our system sets them the same way, since U-Boot leaves the eMMC disabled when starting from the card. Rejected: HS200/HS400, which the chip supports but U-Boot strips (2026-10-18: they would only speed up install, backup and loading from the eMMC, which are fine as they are, and need per-unit tuning values that U-Boot fills only for an eMMC start).
- **Disks are found by controller, partitions by GPT name within one disk, the system partition by filesystem UUID** (2026-10-14). Both disks have partitions named `bootloader`, `env`, `boot`, and `mmcblkN` numbers depend on probe order, so neither names alone nor numbers can say which disk is which. Controllers: `sdc0` is the card, `sdc2` the eMMC.
- **The data partition is FAT32, made on the first start over the rest of the card** (2026-10-14). The written image covers only the system's partitions, so it fits any card; the first start moves the backup partition table to the card's end, adds a partition named `sdcard` over the free space and formats it (label `BRICK`). Only a partition made this way is ever formatted, and only on the card the system runs from.
- **With the system on the eMMC, any FAT32 or exFAT card works**: the card's first FAT or exFAT partition other than `bootloader` is used, or the whole card when it has no partition table (2026-10-14; exFAT and whole cards 2026-10-18).
- **Mount options: FAT `rw,noatime,flush,iocharset=iso8859-1,utf8,errors=remount-ro`; exFAT `rw,noatime,iocharset=utf8,errors=remount-ro,sys_tz`; both `gid=<www-data>,umask=0002`** (2026-10-11, names 2026-10-13, exFAT and owner 2026-10-18; `usr/libexec/brick/card-options`, shared by `mount-card` and the recovery menu). File names are UTF-8 but matched regardless of case, as a PC does. `flush` writes a file's data soon after it is closed. On filesystem damage the card turns read-only rather than getting worse. Every file is group `www-data` and group-writable, so WebDAV can write the card without root ([system-image.md](system-image.md)). File times: [power.md](power.md). Rejected: `sync`, TrimUI's choice (about 10× slower uploads and more card wear); `iocharset=utf8` on FAT (makes lookups case-sensitive, so `roms/` didn't find a card's `Roms/`).
- **Saving safely across a power cut is the writing program's job**: write a temporary file, then rename it over the old one (2026-10-14). The mount options only bound how long data sits in memory.
- **The card is kept mounted to match the slot, and its state is published in a file** (2026-10-18). mdev runs `mount-card` whenever the card's disk appears, changes or goes; `/run/card/state` says how the card stands, and Specular follows it with inotify. Rejected: mounting only at start-up (a card inserted later was never used, and a pulled one stayed "mounted"); Specular mounting the card itself (the system and WebDAV need it too).
- **Every run works out the mount from what is there now, under one lock**, not from the event that started it (2026-10-18). mdev's runs can overlap and arrive out of order (Findings); this way the last run always leaves the mount matching the card.
- **Cards and partitions are told apart by device number, never by name** (2026-10-18). A card inserted after a removal gets the old card's name while the old disk is still held (Findings), so a test by name would take a stranger's card, inserted after the system's own was pulled, for the card the system runs from, and repartition and format it.
- **The data partition is checked before every mount** (`fsck.fat -a`, `fsck.exfat -p`) (2026-10-18). `flush` alone doesn't keep a FAT partition consistent when it is pulled or powered off mid-write. Checking always also catches damage that left no "not unmounted cleanly" mark (e.g. made on a PC), and reading that mark ourselves would mean parsing three on-disk formats (FAT16, FAT32 and exFAT keep it in different places). A check that leaves errors, or can't run, mounts the card read-only rather than not at all, so games still play. Rejected: checking only when that mark is set (revisit if the check takes more than ~3 s on a typical card: Open questions).
- **A card the kernel turns read-only after mounting (`errors=remount-ro`) is noticed by Specular** (2026-10-18): a write failing as read-only makes it run `mount-card`, which reports `read-only damaged`. The kernel announces this nowhere (Findings). Rejected: a service following the kernel log (one more service, for a rare case); polling.
- **Pulling the card the system runs from turns the Brick off** (`poweroff -f`, best effort, 3 s after a line in the kernel log and the state, so that Specular, if it still runs from memory, can show the message) (2026-10-18). Nothing on that card can be reached any more and it can't be put back (a re-inserted card is a new disk), so the device can only be restarted. The test (`/system`'s device number gone from sysfs) can't misfire: a device number leaves sysfs only when its disk is removed, and isn't reused while `/system` holds it (Findings). Rejected: leaving it broken until the power key is held. Not rebooting: with no card, the boot ROM would start TrimUI's system from the eMMC.
- **Start-up waits up to 5 s for a card** (2026-10-18), so that Specular's first screen normally has the library. It costs 5 s on every start of an eMMC-installed Brick without a card; a card that is slower to appear is mounted when it does. Rejected for now: reading the card-detect line from debugfs to skip the wait (relies on debugfs's text format).
- **exFAT cards are supported by backporting mainline's exFAT driver to our 4.9 kernel** (2026-10-18), trusted only after power-cut stress tests, so no user has to reformat. The base is `fs/exfat` from Linux 6.18.57 (the newest long-term release), plus later upstream fixes picked one by one. Rejected: offering to reformat the card on the device (erases it); the out-of-tree linux-exfat driver's 4.1+ branch (fewer fixes, version checks all through the code); the 7.x driver (rewritten onto iomap, which 4.9 lacks).
- **The exFAT tools are exfatprogs 1.4.3, packaged by us** (`system/package/exfatprogs-upstream`) (2026-10-18), for `fsck.exfat`'s repair fixes since Buildroot 2026.02's 1.2.9. A Buildroot external tree can't change one of Buildroot's own packages, so ours has another name and excludes Buildroot's. Rejected: Buildroot's 1.2.9; patching Buildroot's package (it is unpacked fresh from the release tarball).
- **The system partition is ext4 without `orphan_file`, checked with `e2fsck -p` at every start** (2026-10-14). e2fsprogs 1.47 turns that feature on by default and our 4.9 kernel can't mount it. The same `mke2fs` options are used by the SD card build and the installer.
- **Our system never mounts anything on the eMMC by itself**; it leaves the disk attached for the installer ([install-and-update.md](install-and-update.md)) (2026-10-14).

## Design

### Controllers and names

| Controller | Linux host | What | Mode |
|---|---|---|---|
| `sdc0` (`sdmmc@04020000`) | mmc1 | SD card, card detect PF6 | 4-bit UHS SDR104, 150 MHz, 1.8 V |
| `sdc1` (`sdmmc@04021000`) | mmc2 | XR829 WiFi ([wireless.md](wireless.md)) | 4-bit, 50 MHz, 3.3 V |
| `sdc2` (`sdmmc@04022000`) | mmc0 | eMMC | 8-bit DDR52, 50 MHz, 1.8 V |

Code finds a controller's disk under `/sys/bus/platform/devices/<controller>/mmc_host/mmc*/mmc*:*/block/`, and a partition by `PARTNAME=` in `/sys/block/<disk>/<partition>/uevent`.

### Keeping the card mounted (`mount-card`)

```
rcS            mount-card start    waits up to 5 s for a card, then as below
mdev           mount-card event    the disk mmcblk<N> appeared, changed or went (etc/mdev.conf)
Specular       mount-card          a write to the card failed as read-only
rcK            mount-card stop     unmounts (logs who holds the card if it can't)
```

Each run, under `flock /run/card/lock`:

1. If `/system`'s device number is gone from `/sys/class/block/*/dev`, the system's card was pulled: a line to `/dev/kmsg`, `failed system-card-removed`, 3 s later `poweroff -f`. Nothing else.
2. If something is mounted at `/mnt/SDCARD` and its device number is one of the card's (`/sys/block/<disk>/{,<partition>/}dev`), it is kept; if the kernel has since made it read-only (`ro` in mountinfo's last field) and the state is `mounted`, the state becomes `read-only damaged`. Otherwise the old card is released: `umount -l`, `sv down webdav`.
3. No card: `absent`. Else `checking`; choose the data partition (below); check it (not if the card reports itself read-only); if it was pulled meanwhile, `absent`; mount it (read-only after `errors-left`, `not-run`, or for a write-protected card); if read-write, make `roms/ bios/ saves/ updates/`, copy the card's guide files where they differ ([system-image.md](system-image.md), "No manuals") and log a check that wasn't `clean` on the card.

A run that changes nothing leaves the state file alone. If the card goes during a run, the run reports `absent`, not a failure (or, if it goes just after mounting, the removal's own run does). Every run logs why it ran.

#### Choosing the data partition

```
partition named "sdcard" with FAT or exFAT       → use it
card holds /system, no "sdcard"                  → add it over the rest of the card, format FAT32
card holds /system, "sdcard" with no filesystem  → format it (a first start cut short), unless it
                                                   has a FAT32 backup boot sector (sector 6): then
                                                   only its main boot sector is damaged; left alone
                                                   (so, with no other, failed no-partition)
otherwise                                        → lowest-numbered FAT or exFAT partition not named
                                                   "bootloader"; the whole card if it has no partitions
none                                             → failed not-set-up if the card has our "system"
                                                   partition but no "sdcard" (written, never started
                                                   from), else failed no-partition
```

The data partition is made only with at least 64 MiB free after the system partition (`MIN_DATA_MiB`); otherwise `failed too-small`, and the card is left as it was but for its backup partition table, moved to the card's end.

The card layout is in [boot.md](boot.md), the eMMC's after an install below.

#### The check

| Filesystem | Command | Exit → `check=` |
|---|---|---|
| FAT | `fsck.fat -a` | 0 → `clean`; 1 with `*** Filesystem was changed ***` → `unclean` if its only finding was the "not unmounted cleanly" mark, else `repaired`; anything else → `not-run` (it also exits 1 when it couldn't check) |
| exFAT | `fsck.exfat -p` | 0 → `clean` (also when it only cleared that mark); 1 → `repaired`; 4 → `errors-left`; else → `not-run` |

Then `clean`, `unclean`, `repaired`: read-write; `errors-left`: read-only `damaged`; `not-run`: read-only `unchecked`. FAT never gives `errors-left`: with `-a` it fixes all it finds or gives up.

A card that reports itself read-only (`/sys/block/<disk>/ro`) isn't checked (the check couldn't write) and is mounted read-only (`write-protected`). Output: `/run/card/check.log` (the last check), the system log (result, seconds, up to 20 lines), and, after a read-write mount that wasn't `clean`, a dated block in `logs/card-check.log` on the card (moved to `card-check.log.old` past 1 MiB).

#### State file

`/run/card/state`, replaced whole on each change (written to `state.new`, renamed over `state`), so a reader sees the old file or the new one, and one inotify event (`IN_MOVED_TO`, name `state`) on `/run/card` announces each change.

```
<state>[ <reason>]                                            line 1: for programs; the words below are stable
<message>                                                     line 2: for the user, one line, may be empty
card=<cid> partition=<name> type=<vfat|exfat> check=<result>  line 3: details; any may be empty; unknown keys are ignored
```

`card=` is the card's CID (`/sys/block/<disk>/device/cid`), unique per card: it tells whether the same card came back. Line 2 says what happened, what still works and what to do; `mount-card`'s `message` has the texts. Specular shows it as it is:

| Line 1 | When | Line 2 says | Specular |
|---|---|---|---|
| `absent` | no card | No SD card; insert the one with your games | the message in place of the library |
| `checking` | a card was found; checking (on a first start, also making) its data partition | checking, a few seconds | the message in place of the library |
| `mounted` | mounted read-write | empty; after `check=repaired`: errors were repaired, `logs/card-check.log` lists the changes | the library; a repair message once, dismissable |
| `read-only write-protected` | the card reports itself read-only | locked against writing: games play, nothing is saved; use a writable card | the library, the message above it, always visible |
| `read-only damaged` | the check left errors (`check=errors-left`), or the kernel made the card read-only after an error | games play, nothing is saved; repair on a PC (errors left), or take the card out and insert it again to check it (the system's own card: restart) | as above; saving shows that it can't save instead of failing silently |
| `read-only unchecked` | the check couldn't run (e.g. read errors) | games play, nothing is saved; insert again (restart) to retry; if it keeps happening, the card may be failing | as above |
| `failed no-partition` | no readable FAT32 or exFAT partition (e.g. an NTFS card) | use a FAT32 or exFAT card | the message in place of the library |
| `failed not-set-up` | our card, written but never started from (no `sdcard` partition), in a Brick running from the eMMC | restart with this card in to finish setting it up | as above |
| `failed mount` | the kernel refused to mount it | damaged or not supported: repair on a PC or format | as above |
| `failed partition` | the first start couldn't make the data partition | restart; if it fails again, write Crystaline OS to the card again (this erases it; it holds no games yet) | as above |
| `failed too-small` | the system's own card has under 64 MiB left for the data partition | too small: a card of at least 2 GB is needed | as above |
| `failed system-card-removed` | the card holding `/system` was pulled | the Brick turned off; insert the card and turn it on | the message, for the 3 s before it turns off (if Specular still runs) |

#### Specular's side (its own repository)

```rust
/// The SD card as the system reports it (/run/card/state on the Brick; a device without that
/// file, e.g. the desktop build, always reports `Mounted`).
pub struct Card {
    pub status: CardStatus,
    /// Why, for read-only and failed: a stable word (the table above).
    pub reason: Option<String>,
    /// What to tell the user, as the system words it; may be empty.
    pub message: String,
    /// The card's identity (its CID): tells whether the same card came back after a removal.
    pub id: Option<String>,
}
pub enum CardStatus { Absent, Checking, Mounted, ReadOnly, Failed }
```

- Read the file at start-up and on each `IN_MOVED_TO` (name `state`) on `/run/card`.
- On becoming `Mounted` or `ReadOnly` from any other status: reload the global settings, watch the ROM folders anew (watches on a released card never fire again) and rescan.
- When a write to the card fails with `EROFS` while the status is `Mounted`: run `/usr/libexec/brick/mount-card`, then show the new state.
- The card goes while a game runs: pause the game and say "Insert the SD card again to save". When the same card (`id`) is back, save and return to the library; quitting instead loses unsaved progress. Continuing play isn't offered: disc games stream from the card.
- `mount-card` stops WebDAV when the card goes; the File transfer screen starts it again (`sv up webdav`) once the card is back.

#### Diagnostics

| What | Where |
|---|---|
| Every run: why it ran (`start`, `stop`, the mdev event, or asked), the card's CID, partition and type chosen, the check (result, seconds, output), mount options, releases, each state written | system log, tag `mount-card`; during start-up `/system/logs/rcS.log` |
| The kernel's FAT/exFAT messages (e.g. "Filesystem has been set read-only") | system log (`klogd`), `dmesg` |
| Current state, last check's output | `/run/card/state`, `/run/card/check.log` |
| Repairs and unclean removals, across restarts | `logs/card-check.log` on the card |
| The system's card pulled | `/dev/kmsg` (serial console; the system log's file was on the pulled card) |
| A run, command by command | `touch /run/card/trace` (DEVELOPMENT.md) |

### exFAT driver

`linux/fs/exfat`, built in (`CONFIG_EXFAT_FS=y`, names in UTF-8). The files stay as upstream wrote them where possible, so upstream fixes apply cleanly:

- `compat.h`: newer kernel interfaces written in 4.9's terms (timestamp and change-counter helpers, `SB_*` flags, `kvmalloc_array`, block-device helpers, the ioctl numbers), and the list of upstream fixes applied on top of 6.18.57. 64-bit only.
- Changed in place: mount options (`mount_bdev()` with a `match_token()` table; same options and remount rules as upstream), page-cache hooks (`readpage`, `readpages`, `writepage`, `write_begin`/`write_end` on pages), `mmap`/`page_mkwrite`, `setattr`/`getattr`, freeing inodes, timestamps clamped to 1980–2107 when written.
- What 4.9 can't do: report creation time in `stat` (no `statx`); the "shut down" ioctl works, but nothing calls it on card removal.

A remount resets every option it doesn't name except `uid`, `gid`, `fmask` and `dmask`, and fails if `iocharset`, `time_offset`, `sys_tz`, `keep_last_dots` or `allow_utime` would change.

### The eMMC after an install (512-byte sectors)

```
0-5          protective MBR, GPT header, 16 GPT entries
16 … 40959   boot area copied from the card: boot0, its copy at 256, boot package at 32800
41984        bootloader  24 MiB   FAT, copied from the card
91136        env        512 KiB   card's U-Boot settings, pointed at the partitions below
92160        env-redund 512 KiB   same
93184        boot_a      24 MiB   running version's boot.img (TrimUI's "boot")
142336       boot_b      24 MiB   left as it was until the first update
191488       pstore       1 MiB   kernel crash records; zeroed, a new GPT UUID at each install
193536       system      rest     ext4, label brick-system (last 34 sectors: backup GPT)
```

The first four stay where TrimUI's layout has them, the only layout known to start from the eMMC ([install-and-update.md](install-and-update.md)). The installer writes it (`LAYOUT` in `userspace/brick-install/src/install.rs`).

### TrimUI's eMMC layout (512-byte sectors, from 41984)

```
bootloader    49152   24 MiB    FAT: boot logo, pictures
env            1024  512 KiB    U-Boot settings
env-redund     1024  512 KiB
boot          49152   24 MiB    kernel (Android boot image)
rootfs      1146880  560 MiB    ext4, read-only
rootfs_data 4194304    2 GiB    overlay over rootfs (settings)
private        1024  512 KiB
recovery      32768   16 MiB
pstore         1024  512 KiB    crash log
UDISK          rest   ~4.6 GiB  ext4, user data
```

## Findings

- (2026-10-11, device) The A133's SD pins (port F) have a supply switch inside the chip: PIO register 0x0300B350 bit 0 (1 = 3.3 V, 0 = 1.8 V), next to the pad-mode bits at 0x0300B340 (bit 5 = port F). No external 1.8 V regulator is involved. TrimUI's kernel writes both; our source did so only for sun8iw16/19 and sun50iw11, so 1.8 V signalling put the pads in 1.8 V mode on a 3.3 V supply and UHS modes never initialised (the card fell back to 50 MHz). The vendor code never clears a pad-mode bit, which the WiFi port relies on, so only port F follows the voltage both ways. Source: stock kernel disassembly, `memreg`.
- (2026-10-11, device) At SDR104 a 32 GB card reads 67 MB/s raw and writes 22 MB/s through FAT32 with `fsync`; the card re-initialises at SDR104 after deep sleep. Source: device measurement.
- (2026-10-14, device) This unit's eMMC: Samsung 8 GB eMMC 5.0 (15269888 sectors), made 05/2015, wear reported by the chip 40–50 % used (`life_time` 0x05 0x05, `pre_eol_info` normal), likely a reclaimed part. HS200/HS400-capable. Two full reads at DDR52 took ~127 s each (~58 MB/s with SHA-256 on the CPU) and matched.
- (2026-10-14, device) On stock, `private`, `pstore` and the eMMC's hardware boot areas are empty, `recovery` holds only "recovery part not used!", `UDISK` holds 9 MB (empty folders and TrimUI's `system.json`), `rootfs_data` only stock's settings (WiFi, Bluetooth address, SSH keys).
- (2026-10-11, stock) Stock mounts the data card at `/mnt/SDCARD` (`mmcblk1p1`, else the whole `mmcblk1`) with `sync`, and its hotplug script mounted any USB drive over `/mnt/SDCARD`, hiding the card. Source: stock `/etc/config/fstab`, `/etc/hotplug.d/block/10-mount`.
- (2026-10-13, device) Linux's FAT driver with `iocharset=utf8` matches names case-sensitively (only the all-capitals 8.3 alias matched); `utf8` with `iocharset=iso8859-1` keeps UTF-8 names and case-insensitive lookups (`roms/gba` finds `Roms/GBA/Pokémon.gba`). Source: loop-image test on the device; the kernel's FAT documentation warns about this.
- (2026-10-14, stock) TrimUI's kernel reads exFAT through an out-of-tree driver (`CONFIG_EXFAT_FS=y`); the Sonic Pad source we build from has no exFAT driver. Source: stock kernel config, our `fs/`.
- (2026-10-14, upstream) e2fsprogs 1.47 enables `orphan_file` by default; Linux mounts it only from 5.15. Source: `tools/system/mkfs-system.sh`.
- (2026-10-18, upstream) A card's disk name comes from its controller (`mmcblk%u` from `card->host->index`), so a card inserted after a removal is `mmcblk1` again, even while the old card's disk is still held (by a lazily unmounted filesystem, or by `/system`). Its device number differs: the index behind it is freed only when the old disk's last user lets go. Source: `linux/drivers/mmc/card/block.c`.
- (2026-10-18, upstream) Linux's FAT driver sets the boot sector's "not unmounted cleanly" mark on every read-write mount and clears it on a clean unmount, in the main boot sector only. `fsck.fat` (dosfstools 4.2) clears it, and for FAT32 also Windows' clean-shutdown bit in FAT[1]; it then also reports that byte (65) as differing from the backup boot sector, and leaves that alone with `-a`. Source: `linux/fs/fat/inode.c`, dosfstools `check.c`; PC test.
- (2026-10-18, upstream) `fsck.fat` exits 1 both after it changed something (only then printing `*** Filesystem was changed ***`) and when it couldn't check at all (`die()`); 0 when nothing changed. With `-a` it fixes everything it finds, writing at the end, so a check it gives up on writes nothing. Source: dosfstools 4.2 `fsck.fat.c`, `common.c`.
- (2026-10-18, upstream) `fsck.exfat -p` (exfatprogs 1.4.3) exits 0 when the only thing wrong was the volume's dirty flag: it sets the flag itself while checking and clears it at the end. 1: corrected; 4: errors left (also for a damaged boot region); 8: couldn't run. Source: exfatprogs `fsck/fsck.c`; PC test.
- (2026-10-18, upstream) When FAT turns read-only after an error (`errors=remount-ro`), the kernel only sets the read-only flag on the filesystem: no uevent, no mount-table change (polling `/proc/mounts` doesn't wake). It shows in mountinfo's last field and in `statvfs`; the kernel's message (`FAT-fs (…): Filesystem has been set read-only`) is in the kernel log. Source: `linux/fs/fat/misc.c` (`__fat_fs_error`).
- (2026-10-18, upstream) The SD card isn't removed and re-added around deep sleep (SD has no `pre_suspend` in `mmc_pm_notify`); it is re-identified on resume, so a card swapped during sleep shows up as a remove then an add. The kernel syncs filesystems before suspending. Source: `linux/drivers/mmc/core/core.c`, `kernel/power/suspend.c`.
- (2026-10-18, upstream) A disk's add uevent is sent once its partitions exist in sysfs and devtmpfs's `/dev`, before their own add uevents. Source: `linux/block/genhd.c`.
- (2026-10-18, upstream) BusyBox `mdev`: the kernel starts one per uevent without waiting, so runs overlap (there is no `/dev/mdev.seq`, so no ordering); `mdev -s` sets `ACTION=add` and no `SEQNUM`; a `*command` runs on add, remove and change; rules match the whole name; `/dev/mdev.log`, if it exists, gets its debug log. Source: `busybox-1.37.0/util-linux/mdev.c`.
- (2026-10-18, device) `/system` on an eMMC-installed Brick is 179:5 (`mmcblk0p5`, on the layout before the two boot slots); the card is `mmcblk1`, 179:32, its first partition 179:33. `/sys/block/mmcblk1/device/cid` is readable. Source: device, read-only.
- (2026-10-18, inferred) Our exFAT driver passes, in QEMU (our kernel with lockdep, a 1 GiB virtual disk, exfatprogs 1.4.3): `fsck.exfat -n` clean after use; names matched regardless of case with `iocharset=utf8` (`roms/gba/POKÉMON émeraude.gba` finds `Roms/GBA/Pokémon Émeraude.gba`); 255-character names; rename over an existing file; preallocated files (size past the written data, as Windows and macOS leave them) read back as data then zeros, also with `O_DIRECT` and after a remount, and take `mmap` writes and appends; times before 1980 or after 2107 stored as the limits; loop-mounted images; mount-card's options. No lockdep or kernel warnings. Not yet run on the device. Source: `tools/system/test-exfat.sh`.
- (2026-10-18, inferred) In 40 power cuts in QEMU (a reset 3–14 s into writes, saves by rename, mkdir/rm), every save by rename survived whole. 12 times `fsck.exfat -n` then found one error, always in the temporary file being written at the cut ("cluster … is marked as free": its entry reached the card before the allocation bitmap); `fsck.exfat -p` repaired it (exit 1) and the card was clean after. Source: `tools/system/test-exfat.sh`.
- (2026-10-18, upstream) Linux 4.9 differs from 6.18 where the driver depends on it: it doesn't clamp timestamps to what the filesystem stores; it ignores `VM_FAULT_RETRY` from `page_mkwrite`; readahead hands over pages in reverse order and leaves out cached ones; it has no `statx` (no creation time in `stat`). Source: `linux/mm/memory.c`, `linux/mm/readahead.c`, `linux/fs/exfat/compat.h`.

## Open questions

- How long does the check take on a large, full card? If more than ~3 s on a typical card, check only when the "not unmounted cleanly" mark is set and offer a full check in Settings. Measured by `time fsck.fat -n` on the device.
