# System image

Status: In progress · Updated: 2026-10-18

The system that runs on the Brick: how it is built, what it contains, how it starts its services, where its state and the user's files live, how files get to and from a PC, and how developers get in. It replaces TrimUI's system entirely; only the bootloaders and a few closed binaries remain from TrimUI ([platform.md](platform.md)).

## Decisions

- **Our own system image, built with Buildroot, not TrimUI's system** (2026-10-11; first booted 2026-10-14). We want to own as much of the code as possible: TrimUI doesn't make the best use of its own hardware and doesn't fix bugs (no stock update in over a year as of 2026-10). TrimUI's system is closed binaries built around its own launcher (which won't run without the anti-clone chip), drives hardware through `/dev/mem`, and its start-up scripts pick partitions by name in ways that can reach the eMMC. Rejected: TrimUI's system with our kernel (the development "test card", which remains for comparison).
- **Buildroot builds only the base** (C library, BusyBox, daemons); our kernel, GPU driver, Specular, cores, tools and TrimUI's binaries are added when a version is assembled (`build-system.sh`), so changing them never rebuilds Buildroot (2026-10-14). Buildroot is pinned to a long-term release (2026.02.3) and its download checked against the published checksum.
- **glibc, with 4.9 kernel headers** (2026-10-14). TrimUI's GPU libraries need glibc 2.17 or newer; headers must not be newer than the kernel.
- **BusyBox init with BusyBox's runit applets supervising every service** (2026-10-14). `runsvdir` restarts any service that exits; `sv` stops, starts and checks them. Packages' own start scripts are deleted. Services that need another check it with `sv check` and exit, to be retried a second later.
- **The root filesystem is read-only** (squashfs, zstd) (2026-10-14). What must be written links into the state area on the system partition; services' control files live in a RAM copy of `/etc/sv`.
- **The system log is kept in memory only** (512 KiB, `syslogd -C`) (2026-10-14), so logging never wears storage. Start-up has its own logs on disk (below).
- **User data lives on the SD card's FAT32 data partition, also when the system is installed on the eMMC** (2026-10-11). For portability and accessibility: the card is what users move between PC and device, any PC reads FAT32, and the system can be replaced without touching games and saves. Filesystem details: [storage.md](storage.md).
- **File transfer: WebDAV first, then our own browser page; no MTP** (2026-10-11). `dufs` serves the data partition on port 80, both as WebDAV (mountable in PC file managers) and as a basic browser page, over WiFi or the USB network link. Rejected for now: MTP and USB mass storage. Either lets a PC write the card while the device may also be writing it, which corrupts the filesystem ([Knulli's warning](https://knulli.org/play/add-games/accessing-via-usb/)); they come once there is a safe way to hand the card over ([usb.md](usb.md)).
- **WiFi is down at start-up; Specular brings it up and down** as its setting says, unloading the driver when off (2026-10-14). Networks are saved by `wpa_supplicant` itself in the state area ([wireless.md](wireless.md)).
- **The frontend falls back to the hardware status screen after 3 starts within a minute**, until the next boot (2026-10-13), so a crashing Specular still leaves a device that shows its battery, sleeps and can be reached over SSH.
- **Development access: SSH with keys only; serial console as root without a password** (2026-10-14). The SSH host keys and the login key are made once per checkout (`build/ssh-host-keys`, kept across `make clean`), so every image from that checkout has the same identity and a reflash doesn't trigger the PC's changed-host-key warning. Caveat: anyone holding a checkout's key has root on every image built from it.
- **Developer layer: a writable overlay over one version's read-only root** (2026-10-14), present when `overlay/<version>/` exists on the system partition. It lasts until that version is replaced, so an update always starts clean.

## Design

### Building a version

```
make system
  Buildroot (system/configs/brick_defconfig)  → rootfs.tar (base)
  + kernel modules, GPU modules, padbridge, brick-install, device tools, dufs,
    Specular + cores + fonts, frontend-run
  + TrimUI's: GPU libraries (EGL, GLESv2, NULL window system, …), rgx.* and *xr829* firmware, hciattach
  + dev SSH host keys, root's authorized_keys, /etc/brick-version
  → build/system/<version>/{rootfs.squashfs, boot.img, manifest.json}
```

Owners come from Buildroot's tar (`tar-with-owners.py` → `sqfstar`), so no root rights are needed. Versions and the manifest: [install-and-update.md](install-and-update.md).

### Start-up

`rcS` (output to `/system/logs/rcS.log`, since the system log isn't running yet): mount `/run`, `/tmp`, `/dev/pts`, `/dev/shm`; `mdev` for devices and hotplug; load the GPU modules; mount the data card (`mount-card`, [storage.md](storage.md)); prepare the state area; copy `/etc/sv` to `/run/sv`. Then `runsvdir` starts:

| Service | What | Waits for |
|---|---|---|
| `syslogd` | in-memory system log | |
| `dbus` | system message bus | |
| `bluetoothd`, `bluealsa` | Bluetooth, Bluetooth audio output | `dbus` |
| `hciattach` | attaches the XR829's Bluetooth (TrimUI's binary) | |
| `padbridge` | buttons → standard gamepad ([input.md](input.md)) | |
| `frontend` | Specular (`frontend-run`, with the fallback above) | `padbridge` |
| `usb` | USB network link ([usb.md](usb.md)) | |
| `sshd` | SSH, keys only | |
| `webdav` | `dufs` on the data card, port 80 | data card mounted (else stays down) |
| `wpa_supplicant`, `wifi-dhcp` | WiFi (down until Specular starts them) | `wpa_supplicant` |
| `ntpd` | clock from the network | a default route (checks every 30 s) |

Shutdown (`rcK`): stop every service, waiting up to 10 s (Specular saves the running game), `sync`, unmount the data card.

### Where things live

```
/system  (ext4 "system" partition; mounted by the initramfs)
├── images/<version>/   boot.img, rootfs.squashfs, manifest.json   (install-and-update.md)
├── overlay/<version>/  upper/, work/: developer layer for that version
├── state/              kept across versions; /var/state links here
│   ├── bluetooth/      xr_bt.conf (controller address) and BlueZ's pairings
│   ├── wifi/           wpa_supplicant.conf (saved networks, mode 600)
│   └── machine-id      D-Bus machine ID
└── logs/               init.log, rcS.log (replaced each start), install.log after an install

/mnt/SDCARD  (FAT32 data partition, label BRICK)
├── roms/  bios/  saves/  configs/
├── cache/              downloaded box art and indexes; safe to delete
├── backups/            eMMC backups (install-and-update.md)
├── logs/               installer logs
└── wpa_supplicant.conf optional; its networks are imported once

bootloader partition (FAT): brick-log/ init.log, dmesg.txt, ps.txt from the last start (boot.md)
```

One-time imports at start-up: a `wpa_supplicant.conf` at the card's root (its `ctrl_interface` and `update_config` lines replaced with ours), and the Bluetooth address and pairings from a test card's `.system-state.img`.

### File transfer

`dufs -A -p 80 /mnt/SDCARD`: uploads, deletes and search allowed, no login, files written as root. The planned browser page for games and saves sits on top of it.

## Findings

- (2026-10-10, stock) TrimUI's system is Tina Linux 1.1.1 (OpenWrt base, `procd`); its launcher exits immediately without a genuine anti-clone chip, and its button daemon reads the GPIO controller through `/dev/mem`. Source: stock rootfs, `MainUI` and `trimui_inputd` disassembly.
- (2026-10-11, device) TrimUI's `adbd` kills a session's processes when the session ends, and sometimes comes up without the USB network link. Source: test card.
- (2026-10-11, stock) TrimUI's BlueZ keeps its storage in `/etc/lib/bluetooth`, and its `hciattach` keeps the XR829's address in `/etc/bluetooth/xr_bt.conf`, writing a random one there if missing; on a read-only root the address (and so every pairing) would change each boot. Source: stock rootfs, `hciattach_xradio.c`.
- (2026-10-14, device) A freshly written card got its data partition (28 GB) on the first start, with WebDAV up. Source: device check after commit 8f03615.

