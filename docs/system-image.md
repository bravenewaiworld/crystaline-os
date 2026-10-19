# System image

Status: In progress · Updated: 2026-10-18

The system that runs on the Brick: how it is built, what it contains, how it starts its services, where its state and the user's files live, how files get to and from a PC, and how developers get in. It replaces TrimUI's system entirely; only the bootloaders and a few closed binaries remain from TrimUI ([platform.md](platform.md)).

## Decisions

- **Our own system image, built with Buildroot, not TrimUI's system** (2026-10-11; first booted 2026-10-14). We want to own as much of the code as possible: TrimUI doesn't make the best use of its own hardware and doesn't fix bugs (no stock update in over a year as of 2026-10). TrimUI's system is closed binaries built around its own launcher (which won't run without the anti-clone chip), drives hardware through `/dev/mem`, and its start-up scripts pick partitions by name in ways that can reach the eMMC. Rejected: TrimUI's system with our kernel (our first development setup, the "test card").
- **Buildroot builds only the base** (C library, BusyBox, daemons); our kernel, GPU driver, Specular, cores, tools and TrimUI's binaries are added when a version is assembled (`build-system.sh`), so changing them never rebuilds Buildroot (2026-10-14). Buildroot is pinned to a long-term release (2026.02.3) and its download checked against the published checksum.
- **glibc, with 4.9 kernel headers** (2026-10-14). TrimUI's GPU libraries need glibc 2.17 or newer; headers must not be newer than the kernel.
- **BusyBox init with BusyBox's runit applets supervising every service** (2026-10-14). `runsvdir` restarts any service that exits; `sv` stops, starts and checks them. Packages' own start scripts are deleted. Services that need another check it with `sv check` and exit, to be retried a second later.
- **The root filesystem is read-only** (squashfs, zstd) (2026-10-14). What must be written links into the state area on the system partition; services' control files live in a RAM copy of `/etc/sv`.
- **The system log is kept in memory and in a file on the system partition** (2026-10-18): `logread` reads the memory copy (512 KiB), and `/system/logs/messages` keeps what happened before a reboot, a crash or a freeze. The file is rotated at 512 KiB with one older file kept, so it takes at most 1 MiB; ext4 writes out every 5 s, so log lines reach storage in batches. BusyBox's `syslogd` does either one; our patch makes it do both (`system/patches/busybox`). Start-up has its own logs on disk (below). Rejected: memory only (2026-10-14, so logging never wore storage; but nothing survived a reboot).
- **The kernel's messages go into the system log too** (BusyBox `klogd`) (2026-10-18), so that they are kept with what the services logged at the time, across reboots, rather than only in the kernel's small buffer (`dmesg`). It leaves the console's level alone (warnings only).
- **User data lives on the SD card's FAT32 data partition, also when the system is installed on the eMMC** (2026-10-11). For portability and accessibility: the card is what users move between PC and device, any PC reads FAT32, and the system can be replaced without touching games and saves. Filesystem details: [storage.md](storage.md).
- **File transfer: WebDAV first, then our own browser page; no MTP** (2026-10-11). `dufs` serves the data partition on port 80, both as WebDAV (mountable in PC file managers) and as a basic browser page, over WiFi or the USB network link. Rejected for now: MTP and USB mass storage. Either lets a PC write the card while the device may also be writing it, which corrupts the filesystem ([Knulli's warning](https://knulli.org/play/add-games/accessing-via-usb/)); they come once there is a safe way to hand the card over ([usb.md](usb.md)).
- **WiFi is down at start-up; Specular brings it up and down** as its setting says, unloading the driver when off (2026-10-14). Networks are saved by `wpa_supplicant` itself in the state area ([wireless.md](wireless.md)).
- **The frontend falls back to the hardware status screen after 3 starts within a minute**, until the next boot (2026-10-13), so a crashing Specular still leaves a device that shows its battery, sleeps and can be reached over SSH.
- **Development access: SSH with keys only; serial console as root without a password** (2026-10-14). The SSH host keys and the login key are made once per checkout (`build/ssh-host-keys`, kept across `make clean`), so every image from that checkout has the same identity and a reflash doesn't trigger the PC's changed-host-key warning. Caveat: anyone holding a checkout's key has root on every image built from it.
- **Release images (`make system RELEASE=1`) have none of that access** (2026-10-18); development images stay as above. A release image carries no keys. Root has no password, so there is no login on the serial console. SSH is off until the user switches it on on the device, and accepts only the login keys the user imported there from `authorized_keys` at the data card's root; both are kept in the state area (`/var/state/ssh/`) and done with `brick-ssh` (below), which Specular's developer settings will run. Each device makes its own host keys on its first start, into the state area. The manifest says `"release": true`. `build-system.sh` is the one place that decides which kind an image is; on the device, `brick-ssh` and the sshd service tell them apart by whether root's `authorized_keys` is a link into the state area. Rejected: reading the card's `authorized_keys` at each start (WebDAV has no password, so anyone on the network could add a key while file transfer is on, and get root at the next start); host keys made at build time (every device of a release would share them).
- **WebDAV runs only while Specular's "File transfer" screen is open, with no password** (2026-10-18). Specular starts and stops it (`sv up webdav`, `sv down webdav`), so the card is open to the network only while the user is transferring files. Rejected: always running (anyone on the network could read and write the card at any time).
- **strace, gdbserver and perf are in development images; release images leave them out, and `make debug-running-release` copies them to a running release** (2026-10-18), so a problem can be looked at on the device where it happens, a user's included, without a special build or a reflash. The tools and the elfutils libraries only they use take 6.6 MB, 2.3 MB compressed in the image; `system/board/brick/debug-tools.list` names them for both the build and the copy, and `build-system.sh` refuses a release in which anything remaining needs one of those libraries. Our hardware test tools (`memreg`, `i2creg`, `blkro`, `glspin`, `rumble`, `dispctl`, `powertest`) go the same way; releases keep `status` and `sleepnow`, which Specular and start-up use. perf is built from kernel.org's standalone perf release (`system/package/linux-perf`): Buildroot's own needs a kernel built by Buildroot. gdb itself runs on the PC (Buildroot builds a cross gdb), where the sources and symbols are. Rejected: the tools in every image (2.3 MB in every release for something rarely needed there, which the copy covers); Buildroot building each kind of image separately (one base serves both, and a Buildroot build is slow); a separate debugging image (a second image to keep working, and a problem may not show on it); the full gdb on the device (it would need the symbols there too).
- **`make debug-running-release` copies the tools into memory only** (2026-10-18): `/run/debug`, over SSH with the user's own key, so nothing on the device's storage changes and they are gone at the next restart. They come from the PC's build (Buildroot's, and our device tools) and use the device's C library, not one of their own, so the device's dynamic loader checks each program without running it (`ld.so --list`, as some test tools would act at once): it names any library or symbol version the device lacks, and the copy is then removed. Rejected: the developer layer (kept across restarts, and it lets anything in the root be changed until the next update); comparing a hash of the device's Buildroot build or C library with the PC's (would refuse builds that are compatible, and the manifest would need a new field); a serial-console login for the session, as an in-memory `/etc/shadow` giving root an empty password, mounted over the read-only one (it needs the SSH login first, helps only when the network is down, and needs a serial adapter wired inside the device).
- **Developer layer: a writable overlay over one version's read-only root** (2026-10-14), present when `overlay/<version>/` exists on the system partition. It lasts until that version is replaced, so an update always starts clean.

## Design

### Building a version

```
make system
  Buildroot (system/configs/brick_defconfig)  → rootfs.tar (base)
  + kernel modules, GPU modules, padbridge, xr829-attach, brick-install, device tools, dufs,
    Specular + cores + fonts, frontend-run
  + TrimUI's: GPU libraries (EGL, GLESv2, NULL window system, …), rgx.* and *xr829* firmware
  + dev SSH host keys, root's authorized_keys (RELEASE=1: links into the state area, for keys
    made or imported on the device, and no root password), /etc/brick-version
  - RELEASE=1: the debugging and hardware test tools (system/board/brick/debug-tools.list)
  → build/system/<version>/{rootfs.squashfs, boot.img, manifest.json}
```

Owners come from Buildroot's tar (`tar-with-owners.py` → `sqfstar`), so no root rights are needed. Versions and the manifest: [install-and-update.md](install-and-update.md).

### Start-up

`rcS` (output to `/system/logs/rcS.log`, since the system log isn't running yet): mount `/run`, `/tmp`, `/dev/pts`, `/dev/shm`; `mdev` for devices and hotplug; load the GPU modules; apply the balanced CPU profile (`brick-power`, [power.md](power.md)); give the kernel the time zone's offset (`brick-timezone kernel`, for file times on the card); mount the data card (`mount-card`, [storage.md](storage.md)); prepare the state area; copy `/etc/sv` to `/run/sv`. Then `runsvdir` starts:

| Service | What | Waits for |
|---|---|---|
| `syslogd` | system log, in memory and in `/system/logs/messages` | |
| `klogd` | the kernel's messages into the system log | the system log's socket |
| `dbus` | system message bus | |
| `bluetoothd`, `bluealsa` | Bluetooth, Bluetooth audio output | `dbus` |
| `xr829-attach` | starts the XR829's Bluetooth and attaches it as `hci0` ([wireless.md](wireless.md)) | |
| `padbridge` | buttons → standard gamepad ([input.md](input.md)) | |
| `frontend` | Specular (`frontend-run`, with the fallback above) | `padbridge` |
| `usb` | USB network link ([usb.md](usb.md)) | |
| `sshd` | SSH, keys only (release images: only while switched on with `brick-ssh`, else stays down; makes the host keys first, `ssh-host-keys`) | |
| `webdav` | `dufs` on the data card, port 80 (down until Specular's File transfer screen) | data card mounted (else stays down) |
| `wpa_supplicant`, `wifi-dhcp` | WiFi (down until Specular starts them) | `wpa_supplicant` |
| `ntpd` | clock from the network | a default route (checks every 30 s) |
| `timezone-offset` | the kernel's time zone offset for SD card file times, checked each minute ([power.md](power.md)) | |
| `battery-guard` | powers off cleanly when the battery is empty ([power.md](power.md)) | |

Shutdown (`rcK`): stop every service but the system log and `klogd`, waiting up to 10 s (Specular saves the running game), `sync`, unmount the data card. init then ends the rest and syncs again.

### Where things live

```
/system  (ext4 "system" partition; mounted by the initramfs)
├── images/<version>/   boot.img, rootfs.squashfs, manifest.json   (install-and-update.md)
├── overlay/<version>/  upper/, work/: developer layer for that version
├── state/              kept across versions; /var/state links here
│   ├── bluetooth/      xr_bt.conf (controller address) and BlueZ's pairings
│   ├── wifi/           wpa_supplicant.conf (saved networks, mode 600)
│   ├── time/           localtime: the time zone (brick-timezone, power.md); /etc/localtime links here
│   ├── ssh/            release images only: this device's SSH host keys (made on its first start),
│   │                   authorized_keys (imported by brick-ssh), on (present while SSH is on)
│   └── machine-id      D-Bus machine ID
└── logs/               init.log, rcS.log (replaced each start), install.log after an install,
                        messages, messages.0 (the system log)

/mnt/SDCARD  (FAT32 data partition, label BRICK)
├── roms/  bios/  saves/  configs/
├── cache/              downloaded box art and indexes; safe to delete
├── backups/            eMMC backups (install-and-update.md)
├── logs/               installer logs
├── wpa_supplicant.conf optional; its networks are imported once
└── authorized_keys     optional: SSH login keys, for brick-ssh import on release images

bootloader partition (FAT): brick-log/ init.log, dmesg.txt, ps.txt from the last start (boot.md)
```

One-time import at start-up: a `wpa_supplicant.conf` at the card's root (its `ctrl_interface` and `update_config` lines replaced with ours).

### SSH on release images

`brick-ssh`, for Specular's developer settings (it does nothing on development images, where SSH is always on with the checkout's key):

```
brick-ssh           image=release|development, ssh=on|off, keys=<N>: one per line
brick-ssh on|off    switch SSH on or off (kept across reboots: /var/state/ssh/on); sv up/down sshd.
                    Off leaves open sessions running
brick-ssh import    replace the login keys with the card's authorized_keys (CRLF made LF); prints
                    keys=<N>. Fails, keeping the old keys, without that file or a valid key in it
errors: a message on stderr, exit status 1
```

Specular (not yet done): an "SSH" on/off setting and an "Import SSH keys from the SD card" action that shows the count or the error, both shown only when `image=release`.

### File transfer

`dufs -A -p 80 /mnt/SDCARD`, while Specular's File transfer screen is open: uploads, deletes and search allowed, no login, files written as root. The planned browser page for games and saves sits on top of it.

## Findings

- (2026-10-10, stock) TrimUI's system is Tina Linux 1.1.1 (OpenWrt base, `procd`); its launcher exits immediately without a genuine anti-clone chip, and its button daemon reads the GPIO controller through `/dev/mem`. Source: stock rootfs, `MainUI` and `trimui_inputd` disassembly.
- (2026-10-11, device) TrimUI's `adbd` kills a session's processes when the session ends, and sometimes comes up without the USB network link. Source: test card.
- (2026-10-14, device) A freshly written card got its data partition (28 GB) on the first start, with WebDAV up. Source: device check after commit 8f03615.
- (2026-10-18, upstream) BusyBox 1.37's `syslogd -C` logs only to the memory buffer and ignores `-O FILE`. Source: `sysklogd/syslogd.c`, `process_line`'s end.
- (2026-10-18, device) `sqfstar` gives the image's root directory the building user's owner and mode 777 unless told otherwise (`-root-uid`, `-root-gid`, `-root-mode`), as the tar has no entry for `/`. `sshd` checks the owner and mode of every directory above a key file outside the home directory, up to `/`, so release images' `/var/state/ssh/authorized_keys` (really `/system/state/ssh/`) needs `/` to be root's and not writable by others. Source: `ls -ld /` on 20261017-231308-c07c480-dirty (uid 1000, `drwxrwxrwx`); OpenSSH `misc.c` (`safe_path`).
- (2026-10-18, upstream) OpenSSH (without PAM) refuses every login, keys too, to an account whose password field starts with `!`; `*` only means no password matches. Source: OpenSSH 10.2 `platform.c` (`platform_locked_account`), `LOCKED_PASSWD_PREFIX` in its Linux build's `config.h`.
- (2026-10-18, device) The kernel registers the CPU's performance counters (`armv8_pmuv3`, CPUs 0–3) from the device tree's `pmu` node, which gives them one interrupt per CPU (SPI 140–143). They don't appear in `/proc/interrupts` until perf first uses the counters: the driver requests them then. Source: `/sys/bus/event_source/devices/`, `/proc/device-tree/pmu`; `linux/drivers/perf/arm_pmu.c` (`armpmu_reserve_hardware`).

## Open questions

- Do the performance counters' interrupts fire? `perf record` needs them. `perf record -a -- sleep 5` collecting samples, and the `arm-pmu` lines in `/proc/interrupts` counting up on every CPU, would answer it.
