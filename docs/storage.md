# Storage

Status: In progress · Updated: 2026-10-18

The Brick's two disks, the microSD card and the 8 GB internal eMMC: how they are driven, how our code tells them apart, and the filesystem of the card's data partition, where all user data lives ([system-image.md](system-image.md)). The SD card is also the game library's read path, so its speed matters, and the data partition must stay readable by any PC.

## Decisions

- **The SD card runs at UHS SDR104 (150 MHz, 1.8 V signalling), as on stock** (2026-10-11). This needed the A133's built-in supply switch for the SD pins (port F), which our kernel source only drove for other chips.
- **The eMMC runs at stock's settings: 8-bit DDR52, 50 MHz, the driver's default sample delays** (2026-10-14). These are the limits U-Boot sets when TrimUI's system starts from the eMMC; the device tree for our system sets them the same way, since U-Boot leaves the eMMC disabled when starting from the card. Rejected: HS200/HS400, which the chip supports but U-Boot strips (2026-10-18: they would only speed up install, backup and loading from the eMMC, which are fine as they are, and need per-unit tuning values that U-Boot fills only for an eMMC start).
- **Disks are found by controller, partitions by GPT name within one disk, the system partition by filesystem UUID** (2026-10-14). Both disks have partitions named `bootloader`, `env`, `boot`, and `mmcblkN` numbers depend on probe order, so neither names alone nor numbers can say which disk is which. Controllers: `sdc0` is the card, `sdc2` the eMMC.
- **The data partition is FAT32, made on the first start over the rest of the card** (2026-10-14). The written image covers only the system's partitions, so it fits any card; the first start moves the backup partition table to the card's end, adds a partition named `sdcard` over the free space and formats it (label `BRICK`). Only a partition made this way is ever formatted, and only on the card the system runs from.
- **With the system on the eMMC, any FAT card works**: the card's first FAT partition other than `bootloader` is used (2026-10-14).
- **Mount options: `rw,noatime,flush,iocharset=iso8859-1,utf8,errors=remount-ro`** (2026-10-11, names 2026-10-13). File names are UTF-8 but matched regardless of case, as a PC does. `flush` writes a file's data soon after it is closed. On filesystem damage the card turns read-only rather than getting worse. Rejected: `sync`, TrimUI's choice (about 10× slower uploads and more card wear); `iocharset=utf8` (makes lookups case-sensitive, so `roms/` didn't find a card's `Roms/`).
- **Saving safely across a power cut is the writing program's job**: write a temporary file, then rename it over the old one (2026-10-14). The mount options only bound how long data sits in memory.
- **The data partition gets a FAT check before mounting** (2026-10-18). `flush` alone doesn't keep a FAT partition consistent when it is pulled or powered off mid-write. Not done yet.
- **exFAT cards are supported by backporting mainline's exFAT driver (Linux 5.7+) to our 4.9 kernel** (2026-10-18), trusted only after power-cut stress tests, so no user has to reformat. Rejected: offering to reformat the card on the device (erases it).
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

### Choosing the data partition (`mount-card`)

```
no disk on sdc0                          → nothing mounted; Specular shows "No SD card"
partition named "sdcard"                 → use it
card holds /system and has no "sdcard"   → add and format it (above)
otherwise                                → lowest-numbered FAT partition not named "bootloader"
none                                     → nothing mounted (logged)
```

The card layout is in [boot.md](boot.md), the eMMC layout after an install in [install-and-update.md](install-and-update.md).

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
