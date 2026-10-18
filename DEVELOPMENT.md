# Crystaline OS Development Guide

`make help` lists every build and device target. Commands that reach the device take its address from `BRICK` (default `192.168.7.2`, the USB network link).

## Getting onto the device

- **SSH** (root, key only), over the USB network link or WiFi. The build creates the host keys and a development login key once per checkout; every image built from that checkout accepts it, so a reflash never changes the device's identity. Anyone holding that key has root on any image you build. Log in with `ssh -o IdentitiesOnly=yes -i build/ssh-host-keys/dev_key root@192.168.7.2` (without `IdentitiesOnly`, keys from an SSH agent such as 1Password's are offered first, and the device hangs up after a few). Files move with `scp` or SFTP.
- **USB network link.** Plug the bottom USB-C port into a PC. The device appears as a network adapter (USB NCM) and gives the PC an address by DHCP. The Linux driver is built in. On Windows and macOS it is untested.
- **WiFi.** Turn it on from Specular, or over SSH. Networks saved in Specular stay saved, and a `wpa_supplicant.conf` at the root of the SD card is imported once. Specular's default WiFi mode (Auto) turns WiFi off when Specular doesn't need it. Its developer setting "Keep Wi-Fi on" keeps it on for SSH.
- **Serial console.** 115200 baud on the board's UART pads; root login with no password. Kernel messages are limited to warnings, because every console line stalls display updates by about 5 ms.
- **WebDAV and a browser page** serve the SD card's data partition on port 80, over WiFi or the USB link. There is no login.
- **ADB is not available.** Our system has no ADB server (`adbd`); use SSH.

## Changing what runs on the device

- **Full update in one command** (`make update-device`): builds a new system version, copies it over SSH, verifies its checksums, switches to it and reboots. The device keeps the new version and the previous one; nothing older. To go back, activate the previous version over SSH (`brick-activate <version>`) and reboot. Nothing rolls back on its own.
- **Developer layer.** A writable layer over the read-only system image. Create it with `mkdir /system/overlay/$(cat /etc/brick-version)`; it is used from the next boot. Changes in it persist across reboots until the next full update, which starts with an empty layer.
- **Specular only:**
  - `make deploy-specular` replaces Specular through the developer layer and restarts it.
  - `make run-specular` runs a build once in the foreground with its output on your terminal, and puts the installed one back afterwards.
- **Services** are supervised and restarted when they exit. They can be stopped, started and restarted individually (`sv`). After 3 failures within a minute, the frontend falls back to a hardware status screen until the next boot.

## Seeing what happened

- **System log.** All service output, Specular's included, goes to the in-memory system log (`logread`). It is lost on reboot.
- **Start-up logs** are kept on the system partition. A copy goes to a FAT partition a PC can read (`brick-log/`: log, kernel messages, process list), refreshed every second during start-up, so a start that ends in a reset still leaves them.
- **Start-up progress codes** are written to a clock-chip register that survives resets. Boot another card and read it to see how far a failed start got.
- **Start-up failures** are shown on screen.
- **Installer logs** go to `logs/` on the SD card.
- **Kernel facilities:**
  - perf events (the kernel side; the `perf` tool isn't in the image yet).
  - debugfs.
  - Magic SysRq.
  - The running kernel's configuration at `/proc/config.gz`.
  - Kernel symbols.
  - `/dev/mem`.
  - I2C device files.
- **Expensive kernel debugging is off by default:** slab, mutex and VM checks. Slab checks cost a GPU-heavy game about 12 %.
- **Not yet available:**
  - A persistent system log.
  - Kernel crash records (built in, but with no storage to write to).
  - `perf`, `gdbserver` and `strace` in the image.

## Testing

- **Installer test harness** (`make test-installer`, after `make sd-card`): runs the internal-storage installer on the PC against image files of a stock device and our SD card. It covers install, backup, restore, and installs and restores cut short. Root is not needed.
- **Overnight power test** (`powertest`): logs battery drain across deep sleep, idle and load to the SD card.

## On-device tools

Built into every image.

| Tool | What it does |
|---|---|
| `dispctl` | Backlight level and panel on/off |
| `glspin` | GPU test that reports fps |
| `rumble` | Rumble test |
| `i2creg` | Read/write a register over I2C |
| `memreg` | Read/write a physical memory register |
| `blkro` | Mark a block device read-only |
| `sleepnow` | Deep sleep now (stops WiFi first) |
| `powertest` | Overnight power test |
| `status` | Hardware status screen; also the fallback frontend and the start-up error screen |

## Hardware research

The probe scripts (`tools/probe/`) take a read-only snapshot of a device running TrimUI's stock firmware over SSH (hardware, drivers, registers, memory dumps), for comparison with ours.
