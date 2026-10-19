# Install and update

Status: In progress · Updated: 2026-10-18

How a system version is named, checked, switched to and kept; update files; how the system moves from the SD card onto the internal storage (eMMC); and how TrimUI's system is backed up first and put back later. These are the operations that can leave a device unable to start, so each is ordered to be recognisable and repeatable if cut short, and everything written is read back.

## Decisions

- **System versions are read-only image files on an ext4 partition** (2026-10-14). Simple, and tried and true; it is also the common pattern elsewhere (Batocera, Knulli, ROCKNIX, and stock's own `trimui.img`), and an update is one file. Rejected: btrfs with a subvolume per version and snapshots (its 4.9 code lacks years of fixes; fast development updates come from the developer layer instead, [system-image.md](system-image.md)).
- **Each build is a version: a boot image, a read-only root filesystem and a manifest, kept in `images/<version>/` on the system partition** (2026-10-14). The name is the build time in UTC plus the git commit, with `-dirty` for uncommitted changes, so versions sort by age and trace to their source.
- **Two boot slots (A/B); switching versions writes the slot not running, then switches U-Boot's settings to it** (2026-10-18). U-Boot loads the slot its `boot_partition` setting names, and the boot image carries its version ([boot.md](boot.md)), so the running version stays the one that starts until the switch, and is the one to go back to after it. The switch writes U-Boot's two settings copies in an order that leaves one of them valid at every moment (Design). What a slot holds needs no record: it is read by comparing the slot with each version's `boot.img` hash. Rejected: one boot partition rewritten in place (2026-10-14; a power cut while writing it left the disk unable to start until an SD card repaired it, and going back meant writing again); a start counter that falls back to the previous version by itself after failed starts (later, if the recovery menu proves too little).
- **The device keeps the new version and the one it was running; nothing older** (2026-10-14). Going back is `brick-install activate <previous>` (over SSH, or "Start the previous version" in the recovery menu) and a restart: the other slot still holds it, so only the settings change. A developer layer on the running version gets an empty one for the new version, so developer mode carries over but its files don't.
- **Every update goes through `brick-install update <file>`: Settings, the recovery menu and `make update-device` alike** (2026-10-18), so one code path is tested. It copies into `images/<version>.part/` and renames when complete, so an interrupted copy is never activated. Rejected: `brick-activate`, a shell script (the settings switch needs CRCs and a write order a shell can't do safely).
- **`brick-install activate <running version>` is allowed and points the settings back at the running slot** (2026-10-18), so an update or activate can be undone before restarting; it writes no slot and deletes nothing. Rejected: refusing it (nothing could undo an activate but restarting into it).
- **Older update files are allowed; `offer` marks them `"older"` so Specular can warn** (2026-10-18). Going back to a known-good release must stay possible. Rejected: refusing them in Settings, or always.
- **A version whose manifest lacks `"dt_edits": true` is refused: as an update file, for activating, and for installing** (2026-10-18). Our SD cards and installs carry TrimUI's boot package unchanged, and the kernel makes our device-tree changes itself ([boot.md](boot.md)); an older kernel would start without its buttons, internal storage or CPU voltage control. Devices installed earlier still have the changes in their boot package and could run such a version, but get the same rule. Rejected: patching the boot package as well (old kernels would keep working, but every install would keep writing a tree that ages with each change).
- **Installing copies the running SD-card system onto the eMMC** (2026-10-14): the boot area and bootloader partition byte for byte, the running version's boot image, and a new system partition with that version and the state (saved WiFi networks, Bluetooth pairings). The eMMC then starts exactly what has been running.
- **TrimUI's first four eMMC partitions stay where its layout has them** (2026-10-14); it is the only layout known to start from the eMMC. Our system partition takes everything after them.
- **The order of writes makes a cut-short install or restore recognisable and harmless** (2026-10-14). While writing, the partition table's header sector holds a marker (`BRICK-INSTALLING`, `BRICK-RESTORING`); everything else is written at fixed places without the table; the table is written last (a restore writes its first 4 MiB last). Until the very end the card still starts the device, so a cut-short install is simply run again.
- **The card's first-stage loader is erased when an install finishes** (2026-10-14), unless `--keep-card-bootable` is given (a developer option in Specular). The boot ROM tries the card first, so otherwise the card would keep starting the device.
- **The eMMC can be backed up to the card first, as 1 GiB zstd-compressed pieces** (2026-10-14). FAT32 can't hold a file over 4 GiB. A backup counts only once every piece has been read back and checked; until then its folder ends in `.partial`, and the next backup deletes it.
- **An install, an update and a restore (prepared or run) refuse to start below 50 % battery unless charging** (2026-10-14; update and restore 2026-10-18).
- **The installer is one program (`brick-install`) that prints a line protocol; Specular only displays it** (2026-10-14). The same program runs on a PC against image files, which is how `make test-installer` tests it, including runs killed mid-way.
- **One `brick-install` task at a time (install, restore, update or activate), and anyone can follow it from its start** (2026-10-14; update and activate 2026-10-18). The task holds an exclusive lock on `/run/brick-install.status` and copies every line there, so a restarted Specular can show it again (`follow`), and `sleepnow` won't sleep while the lock is held.
- **Getting back to TrimUI's system starts from the installed system** (2026-10-18): Settings → Internal storage → Restore writes the card's erased first-stage loader back (an install leaves the card's system partition and backups untouched), restarts from the card, and the restore continues there. The card's system asks before restoring (Restore, Not now, Cancel), so a forgotten marker never erases the eMMC unattended. Rejected: restoring the eMMC in place from a system running off it (the system would first have to move into memory: complex and riskier); copying the backup off, reflashing the card and copying it back by hand; restoring automatically at start-up.
- **After a restore the card stays able to start the device** (2026-10-18), and DONE says to remove it: it stays a working recovery card. Rejected: erasing its first-stage loader at the end, so TrimUI's system starts with the card in.
- **An exFAT card is a data partition like a FAT32 one, for backups and logs too** (2026-10-18; exFAT support: [storage.md](storage.md)). Rejected: going without a data partition (no backups or logs) on exFAT cards, the stopgap before exFAT was supported.
- **An update file is a version folder exactly as `make update-device` copies it (boot image, root filesystem, manifest) plus a signature over the manifest, packed as one file** (2026-10-18). It is signed with an Ed25519 key the maintainer keeps offline, and the public key is built into the system; the key moves to a CI secret once GitHub Actions builds releases for over-the-air updates. Rejected: keeping the key in CI from the start; no signing.
- **The update file is a plain ustar tar, signed with OpenSSL on the PC and checked in Rust on the device** (2026-10-18). Any PC can open a tar, GNU tar writes it reproducibly, and the manifest and signature come first, so nothing is trusted before the signature is checked. The device's reader is strict (exact names, order and types) rather than a general tar library, which would accept far more than we write. It isn't compressed: the root filesystem already is. Development images also trust the checkout's own key (`build/ssh-host-keys/update_key.pem`), so development builds install the same way. Rejected: signify or minisign (not on PCs by default); `ssh-keygen -Y` (its format needs a parser on the device); OpenSSL on the device (about 3 MB).

## Design

### A version

```
images/<YYYYMMDD-HHMMSS>-<commit>[-dirty]/
├── boot.img          kernel + initramfs (Android v0); written to a boot slot to run this version
├── rootfs.squashfs   root filesystem (zstd), mounted read-only
├── manifest.json
└── manifest.sig      (installed from an update file) the signature over manifest.json
```

```json
{ "version": "<version>", "commit": "<commit>[-dirty]", "built": "<YYYY-MM-DDTHH:MM:SSZ>",
  "kernel": "4.9.191", "release": false, "dt_edits": true,
  "files": { "boot.img": { "size": <bytes>, "sha256": "<hex>" },
             "rootfs.squashfs": { "size": <bytes>, "sha256": "<hex>" } } }
```

### Update files

```
crystaline-<version>.update     ustar tar, exactly these regular files in this order:
├── manifest.json               the version's manifest, as build-system.sh wrote it
├── manifest.sig                64 bytes: Ed25519 signature over manifest.json's exact bytes
├── boot.img
└── rootfs.squashfs
```

`tools/system/sign-update.sh <version dir> <key.pem> <out file>` makes one (`make update-file`); it refuses a `-dirty` version with any key but the checkout's development key. Trusted keys are files of 64 hex characters (a raw public key) in `/etc/brick/update-keys/`: `release.pub` (from `system/board/brick/update-keys/`; a release image doesn't build while that file is a placeholder) and, on development images, `dev.pub`.

### `brick-install update <file>`

```
1. Checking the update   tar layout; signature against a trusted key (the log names which);
                         version name ^\d{8}-\d{6}-[0-9a-f]{7,40}(-dirty)?$, not the running one;
                         sizes as in the manifest; boot.img fits the other slot; /system has room
                         for both files + 16 MiB; battery
2. Copying the update    delete images/*.part/; stream into images/V.part/, hashing; write
                         manifest.json and manifest.sig; fsync; rename to images/V; fsync images/
                         (skipped when images/V already matches)
3. Switching to V        as brick-install activate V (below)
```

`make update-device` signs the new version with the development key (or `KEY=`), copies it to `/tmp` on the device, runs `brick-install update` there and restarts the device.

### Activating a version (`brick-install activate V`)

S is the slot the system started from (`brick.boot=` on the kernel command line, checked to hold the running version's `boot.img`), O the other one.

1. Check V's files against its manifest.
2. Unless O already holds V: check `boot.img` fits O; if the settings name O (an earlier activate not followed by a restart), switch them back to S first; write it, read it back. A cut here leaves the settings naming S.
3. Switch the settings to `boot_partition=O` (below).
4. Delete `images/` and `overlay/` entries other than V and the running version; carry the developer layer over.

Activating the running version undoes an activate (or update) not yet followed by a restart: it only switches the settings back to S, and writes no slot and deletes nothing.

Switching U-Boot's settings, with P the copy U-Boot uses now (its rule: [boot.md](boot.md)), f its flags byte and Q the other copy:

```
1. Q ← new settings, flags f+1; sync     until complete, Q's CRC is bad or Q is older → S
                                         once complete, Q is newer → O  (the switch)
2. P ← new settings, flags f+2; sync     while written, P's CRC is bad → Q → O
```

Only neighbouring flag values ever meet, so U-Boot's 255/0 wrap is always read right; both copies end up the same. Every change to the settings, the installer's included, starts from the copy U-Boot uses, never just from `env`.

### Layouts

The SD card's is in [boot.md](boot.md), the eMMC's after an install in [storage.md](storage.md). The eMMC's boot slots are 24 MiB, against 32 MiB on the card; the installer and `update` refuse a `boot.img` that doesn't fit. The smallest eMMC accepted is the partitions before the system partition plus 1 GiB.

### Install steps

1. **Checking**: the source must be the SD card holding `/system`, the target the eMMC; size; battery; the running version's files against its manifest; room for a backup if asked (as much free space as the eMMC holds).
2. **Backing up** (with `--backup`).
3. **Writing the start-up files**: marker; boot area; bootloader partition; both settings copies (the card's, as U-Boot uses them, with `mmc_root=UUID=<new system partition>`, `boot_partition=boot_a` and `blkoops_blkdev=PARTUUID=<new pstore partition>`); `boot.img` into `boot_a` (`boot_b` stays as it was); zeros over `pstore`.
4. **Writing the system**: `mke2fs -d` from a staging folder on `/system` (hard links to the version's files, a copy of `state/`, the install log), at the partition's offset.
5. **Checking the internal storage**: read back the boot area, bootloader partition, settings, boot image and `pstore`; `e2fsck -fn` and each image file through `debugfs` against the manifest.
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

A restore runs from an SD-card system: battery; check every piece; refuse a backup of a different-sized disk; marker; write all but the first 4 MiB; write the first 4 MiB; read the whole disk back against `sha256`; delete `restore-pending.json`.

From the installed system, `brick-install restore <backup>` prepares it instead:

1. **Checking**: the eMMC holds `this-system`; the card has our partitions (`bootloader`, `env`, `env-redund`, `boot_a`, `boot_b`, `system`) and the slot its settings name starts with `ANDROID!`; the backup is of a disk the eMMC's size and has all its pieces; battery.
2. **Making the SD card start the device**: copy the eMMC's sectors 16–32799 (boot0 and its copy, copied from a card by the install) onto the card and read them back; then write `backups/restore-pending.json`.

```json
{ "backup": "internal-20261014-101010", "bytes": 7818182656, "prepared": "20261018-120000" }
```

In that order a cut leaves either nothing done or a card that starts without a marker, where the restore is still in Settings as usual. The card's system reports the marker in `offer`; `brick-install restore --cancel` (only while the eMMC holds `this-system`) deletes it and erases the card's boot0 again, so the device starts from the eMMC. The restore overwrites the whole eMMC, slots included; the card's own slots and settings are never touched.

### `brick-install`

```
brick-install offer                     what can be done now, as JSON
brick-install install [--backup] [--keep-card-bootable] [--dry-run]
brick-install restore <backup folder>   from the card: restore; from the installed system: prepare
brick-install restore --cancel          on the card: drop a prepared restore
brick-install update <file>             check an update file, copy it into images/, activate it
brick-install activate <version>        make an installed version start next
brick-install slots                     what each slot holds, as text (below)
brick-install follow                    replay the running task from its start until it ends
options (found by themselves on the device): --target (eMMC) --source (card) --running (the disk
  holding /system) --system --data --version --slot (boot_a | boot_b) --keys (trusted update
  keys) --power-supply (sysfs power_supply, for the battery check) --status
```

```
$ brick-install slots
boot_a 20261018-212347-b3a6d97 running
boot_b 20261012-090000-1a2b3c4 previous     ("unknown" if no version in images/ matches)
next boot_a                                 (from the settings copy U-Boot uses)
```

```
LOG-FILE <path>          first line, if there is a log (logs/<task>-<time>.log on the data card)
TASK <install|restore|update|activate>
STEP <i>/<n> <label>
PROGRESS <0.00-1.00>     at most once per whole percent
DONE <message>           last line on success
FAIL <message>\t<hint>   last line on failure: what happened, what the user can do
```

```json
{ "install": null | { "bytes": <eMMC size>, "backup": { "possible": true, "free": <bytes> } },
  "why_not": "<why installing isn't possible>",
  "internal": "trimui | this-system | unfinished-install | unfinished-restore | unknown",
  "backups": [ { "dir": "…", "created": "…", "bytes": 0, "holds": "trimui" } ],
  "running":  { "version": "…", "disk": "card | internal", "slot": "boot_a | boot_b | null" },
  "previous": null | { "version": "…", "slot": "boot_b" },
  "updates":  [ { "file": "/mnt/SDCARD/updates/….update", "version": "…" | null, "older": false,
                  "problem": null | "<why it can't be used>" } ],
  "restore":  null | { "possible": true } | { "why_not": "…" },       (on the installed system)
  "restore_pending": null | { "backup": "…", "bytes": 0, "prepared": "…" } }   (on the card)
```

`updates` lists `updates/*.update` on the data partition, newest first, with their signature checked but not their contents.

`free` counts the space backups cut short take, since the next backup deletes them. The log has every step, every command with its exit status and output, and timings; it is flushed at every step. It also has the update file's path, size, time and manifest hash and the key that verified it; the battery and free space; every write to a boot slot or the settings with its offset, length, SHA-256 and read-back result; both settings copies' flags and CRC state and which U-Boot uses, before and after; and what each slot holds. That is enough to rebuild the disks' state as image files and replay it with `make test-installer`.

## Findings

- (2026-10-14, device) This unit's eMMC: GPT with 10 entries, first usable sector 41984 (1024 sectors later than the card's 40960); the hardware boot areas (`mmcblk0boot0/1`) are empty, so boot0 is read from the main area as on the card.
- (2026-10-15, device) First install onto the eMMC: the Brick starts from it without the SD card. Source: device check.
