# Install and update

Status: In progress · Updated: 2026-10-18

How a system version is named, checked, switched to and kept; how the system moves from the SD card onto the internal storage (eMMC); and how TrimUI's system is backed up first and put back later. These are the operations that can leave a device unable to start, so each is ordered to be recognisable and repeatable if cut short, and everything written is read back.

## Decisions

- **System versions are read-only image files on an ext4 partition** (2026-10-14). Simple, and tried and true; it is also the common pattern elsewhere (Batocera, Knulli, ROCKNIX, and stock's own `trimui.img`), and an update is one file. Rejected: btrfs with a subvolume per version and snapshots (its 4.9 code lacks years of fixes; fast development updates come from the developer layer instead, [system-image.md](system-image.md)).
- **Each build is a version: a boot image, a read-only root filesystem and a manifest, kept in `images/<version>/` on the system partition** (2026-10-14). The name is the build time in UTC plus the git commit, with `-dirty` for uncommitted changes, so versions sort by age and trace to their source.
- **One boot partition; switching versions rewrites it** (2026-10-14). The boot image carries its version ([boot.md](boot.md)), so writing another version's `boot.img` is the whole switch. `brick-activate` first checks both files against the manifest. Recovery is manual for now: the boot ROM always tries the SD card first, so any of our SD cards can start and repair a device, and that is easy enough for a first version (2026-10-14). Rejected for now: two boot partitions (A/B), and a start counter (in a spare clock-chip register, [boot.md](boot.md)) that falls back to the previous version after two failed starts; either can come later if manual recovery proves too much.
- **The device keeps the new version and the one it was running; nothing older** (2026-10-14). Going back is `brick-activate <previous>` and a reboot. A developer layer on the running version gets an empty one for the new version, so developer mode carries over but its files don't.
- **Updates are copied over SSH into `<version>.part/` and renamed when complete** (2026-10-14), so an interrupted copy is never activated.
- **Installing copies the running SD-card system onto the eMMC** (2026-10-14): the boot area and bootloader partition byte for byte, the running version's boot image, and a new system partition with that version and the state (saved WiFi networks, Bluetooth pairings). The eMMC then starts exactly what has been running.
- **TrimUI's first four eMMC partitions stay where its layout has them** (2026-10-14); it is the only layout known to start from the eMMC. Our system partition takes everything after them.
- **The order of writes makes a cut-short install or restore recognisable and harmless** (2026-10-14). While writing, the partition table's header sector holds a marker (`BRICK-INSTALLING`, `BRICK-RESTORING`); everything else is written at fixed places without the table; the table is written last (a restore writes its first 4 MiB last). Until the very end the card still starts the device, so a cut-short install is simply run again.
- **The card's first-stage loader is erased when an install finishes** (2026-10-14), unless `--keep-card-bootable` is given (a developer option in Specular). The boot ROM tries the card first, so otherwise the card would keep starting the device.
- **The eMMC can be backed up to the card first, as 1 GiB zstd-compressed pieces** (2026-10-14). FAT32 can't hold a file over 4 GiB. A backup counts only once every piece has been read back and checked; until then its folder ends in `.partial`, and the next backup deletes it.
- **An install refuses to start below 50 % battery unless charging** (2026-10-14). (A restore doesn't check.)
- **The installer is one program (`brick-install`) that prints a line protocol; Specular only displays it** (2026-10-14). The same program runs on a PC against image files, which is how `make test-installer` tests it, including runs killed mid-way.
- **One install or restore at a time, and anyone can follow it from its start** (2026-10-14). The task holds an exclusive lock on `/run/brick-install.status` and copies every line there, so a restarted Specular can show it again (`follow`), and `sleepnow` won't sleep while the lock is held.
- **Getting back to TrimUI's system starts from the installed system** (2026-10-18): Settings → Internal storage → Restore writes the card's erased first-stage loader back (an install leaves the card's system partition and backups untouched), restarts from the card, and the restore continues there. Not built yet; until then the manual steps in the README apply. Rejected: restoring the eMMC in place from a system running off it (the system would first have to move into memory: complex and riskier); copying the backup off, reflashing the card and copying it back by hand.
- **An installed system with an exFAT card goes without a data partition (no backups or logs) until exFAT is supported** (2026-10-18; [storage.md](storage.md)). Rejected: an interim workaround.
- **An update file is a version folder exactly as `make update-device` copies it (boot image, root filesystem, manifest) plus a signature over the manifest, packed as one file** (2026-10-18). It is signed with an Ed25519 key the maintainer keeps offline, and the public key is built into the system; the key moves to a CI secret once GitHub Actions builds releases for over-the-air updates. Rejected: keeping the key in CI from the start; no signing.

## Design

### A version

```
images/<YYYYMMDD-HHMMSS>-<commit>[-dirty]/
├── boot.img          kernel + initramfs (Android v0); written to the "boot" partition to run this version
├── rootfs.squashfs   root filesystem (zstd), mounted read-only
└── manifest.json
```

```json
{ "version": "<version>", "commit": "<commit>[-dirty]", "built": "<YYYY-MM-DDTHH:MM:SSZ>",
  "kernel": "4.9.191", "release": false,
  "files": { "boot.img": { "size": <bytes>, "sha256": "<hex>" },
             "rootfs.squashfs": { "size": <bytes>, "sha256": "<hex>" } } }
```

Each file's entry must stay on one line with this spacing: `brick-activate` reads it with `sed` (the device has no JSON parser).

### Update (`make update-device`)

```
PC: build version V → scp to /system/images/V.part/ → mv V.part V
device: brick-activate V
          check boot.img and rootfs.squashfs against the manifest
          find "boot" on the disk holding /system; check boot.img fits
          dd boot.img → boot (fsync)
          delete images/ (and overlay/) other than V and the running version
        reboot
```

### eMMC after an install (512-byte sectors)

```
0-5          protective MBR, GPT header, 16 GPT entries
16 … 40959   boot area copied from the card: boot0, its copy at 256, boot package at 32800
41984        bootloader  24 MiB   FAT, copied from the card
91136        env        512 KiB   card's U-Boot settings with mmc_root=UUID=<new system partition>
92160        env-redund 512 KiB   same
93184        boot        24 MiB   running version's boot.img
142336       system      rest     ext4, label brick-system (last 34 sectors: backup GPT)
```

The eMMC's boot partition is 24 MiB, against 64 MiB on the card; the installer refuses a `boot.img` that doesn't fit. The smallest eMMC accepted is the boot partitions plus 1 GiB.

### Install steps

1. **Checking**: the source must be the SD card holding `/system`, the target the eMMC; size; battery; the running version's files against its manifest; room for a backup if asked (as much free space as the eMMC holds).
2. **Backing up** (with `--backup`).
3. **Writing the start-up files**: marker; boot area; bootloader partition; both settings copies; `boot.img`.
4. **Writing the system**: `mke2fs -d` from a staging folder on `/system` (hard links to the version's files, a copy of `state/`, the install log), at the partition's offset.
5. **Checking the internal storage**: read back the boot area, bootloader partition, settings and boot image; `e2fsck -fn` and each image file through `debugfs` against the manifest.
6. **Finishing**: write the partition table and read it back; erase the card's boot0 (sectors 16–32799).

What the eMMC holds, from its partition table: `trimui` (has `UDISK`), `this-system` (has `system`), `unfinished-install`, `unfinished-restore` (the markers), or `unknown`.

### Backups

```
backups/internal-<YYYYMMDD-HHMMSS>[.partial]/
├── piece-000.zst … piece-NNN.zst   1 GiB of the disk each (the last one less)
└── manifest.json
```

```json
{ "created": "<YYYYMMDD-HHMMSS>", "bytes": <disk size>, "sha256": "<whole disk>",
  "holds": "trimui",
  "pieces": [ { "file": "piece-000.zst", "bytes": 1073741824, "sha256": "<piece's disk bytes>" }, … ] }
```

A restore runs only from an SD-card system: check every piece; refuse a backup of a different-sized disk; marker; write all but the first 4 MiB; write the first 4 MiB; read the whole disk back against `sha256`.

### `brick-install`

```
brick-install offer                     what can be done now, as JSON
brick-install install [--backup] [--keep-card-bootable] [--dry-run]
brick-install restore <backup folder>
brick-install follow                    replay the running task from its start until it ends
options (found by themselves on the device): --target --source --system --data --version --status
```

```
LOG-FILE <path>          first line, if there is a log (logs/<task>-<time>.log on the data card)
TASK <install|restore>
STEP <i>/<n> <label>
PROGRESS <0.00-1.00>     at most once per whole percent
DONE <message>           last line on success
FAIL <message>\t<hint>   last line on failure: what happened, what the user can do
```

```json
{ "install": null | { "bytes": <eMMC size>, "backup": { "possible": true, "free": <bytes> } },
  "why_not": "<why installing isn't possible>",
  "internal": "trimui | this-system | unfinished-install | unfinished-restore | unknown",
  "backups": [ { "dir": "…", "created": "…", "bytes": 0, "holds": "trimui" } ] }
```

`free` counts the space backups cut short take, since the next backup deletes them. The log has every step, every command with its exit status and output, and timings; it is flushed at every step.

## Findings

- (2026-10-14, device) This unit's eMMC: GPT with 10 entries, first usable sector 41984 (1024 sectors later than the card's 40960); the hardware boot areas (`mmcblk0boot0/1`) are empty, so boot0 is read from the main area as on the card.
- (2026-10-15, device) First install onto the eMMC: the Brick starts from it without the SD card. Source: device check.
