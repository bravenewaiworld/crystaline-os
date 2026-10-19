# Crystaline OS Development Guide

`make help` lists every build and device target. Commands that reach the device take its address from `BRICK` (default `192.168.7.2`, the USB network link).

## Third-party inputs

`tools/fetch-third-party.sh` fetches the inputs `tools/env.sh` lists into `third-party/`, and checks each one against the hash pinned in the script. `--check` only checks what is there.
- An input that doesn't match its pin is reported and left alone: remove it and run again.
- TrimUI's firmware (`trimui_tg3040.awimg` v1.1.1) has no stable download address. Set `TRIMUI_FW_URL` to one, or put the file in `third-party/trimui-firmware-v1.1.1/` yourself; it is checked either way.
- To move an input to a new version, change its pin in the script. A download is pinned by its SHA-256. A git source is pinned by its commit and the tree ID of the directory used (`git rev-parse <commit>:<path>`, or `<commit>^{tree}` for the whole repository).

## Getting onto the device

- **SSH** (root, key only), over the USB network link or WiFi. The build creates the host keys and a development login key once per checkout; every image built from that checkout accepts it, so a reflash never changes the device's identity. Anyone holding that key has root on any image you build. Log in with `ssh -o IdentitiesOnly=yes -i build/ssh-host-keys/dev_key root@192.168.7.2` (without `IdentitiesOnly`, keys from an SSH agent such as 1Password's are offered first, and the device hangs up after a few). Files move with `scp` or SFTP.
- **USB network link.** Plug the bottom USB-C port into a PC. The device appears as a network adapter (USB NCM) and gives the PC an address by DHCP. The Linux driver is built in. On Windows and macOS it is untested.
- **WiFi.** Turn it on from Specular, or over SSH. Networks saved in Specular stay saved, and a `wpa_supplicant.conf` at the root of the SD card is imported once. Specular's default WiFi mode (Auto) turns WiFi off when Specular doesn't need it. Its developer setting "Keep Wi-Fi on" keeps it on for SSH.
- **Serial console.** 115200 baud on the board's UART pads; root login with no password (none at all on release images, below). Kernel messages are limited to warnings, because every console line stalls display updates by about 5 ms.
- **WebDAV and a browser page** serve the SD card's data partition on port 80, over WiFi or the USB link, while Specular's File transfer screen is open, or after `sv up webdav` over SSH (`sv down webdav` stops it). There is no login.
- **ADB is not available.** Our system has no ADB server (`adbd`); use SSH.

## Changing what runs on the device

- **Full update in one command** (`make update-device`): builds a new system version, signs it as an update file with this checkout's update key (`build/ssh-host-keys/update_key.pem`, made once like the SSH keys; `KEY=<key.pem>` for another), copies it to `/tmp` on the device and runs `brick-install update` there, as Settings does, then reboots. It is written to the boot slot not running, so a power cut leaves the running version starting. The device keeps the new version and the previous one; nothing older. To go back: `brick-install activate <previous version>` over SSH and reboot, or "Start the previous version" in the recovery menu. Nothing rolls back on its own. A device still on the layout from before the two boot slots can't be updated this way: write a card (`make sd-card`) and install from it.
- **Update files** (`make update-file`, `KEY=` as above): `build/updates/crystaline-<version>.update`, for Settings or the recovery menu (put it in `updates/` on the card's data partition). Development images accept files signed with this checkout's key or the release key; release images only the release key (`system/board/brick/update-keys/release.pub`, a placeholder until the release key exists: until then `RELEASE=1` doesn't build). `brick-install slots` (over SSH) shows what each boot slot holds and which starts next.
- **Release images** (`RELEASE=1` with `make system`, `sd-card` or `update-device`) have no development access: no checkout keys, no login on the serial console, and no debugging or hardware test tools ("Debugging a release image", below). SSH is off, and accepts only login keys imported on the device: put an `authorized_keys` at the root of the SD card's data partition, then `brick-ssh import` and `brick-ssh on` on the device (Specular's developer settings will do this; until then a release image can't be reached over SSH). Each device makes its own host keys on its first start, so the PC warns once that the host key changed. A version's `manifest.json` says which kind it is (`"release"`). Once a device runs a release image, `make update-device` needs `KEY=<release key>` (or write a card).
- **Developer layer.** A writable layer over the read-only system image. Create it with `mkdir /system/overlay/$(cat /etc/brick-version)`; it is used from the next boot. Changes in it persist across reboots until the next full update, which starts with an empty layer.
- **Specular only:**
  - `make deploy-specular` replaces Specular through the developer layer and restarts it.
  - `make run-specular` runs a build once in the foreground with its output on your terminal, and puts the installed one back afterwards.
- **Boot logo:** edit `system/board/brick/logo/make-logo.py` and regenerate the committed BMP (needs Pillow): `python3 system/board/brick/logo/make-logo.py specular/assets/fonts/Geist.ttf system/board/brick/logo/bootlogo.bmp /tmp/logo.png` (the PNG is a preview). It lives in the bootloader partition, which updates don't touch: it reaches a device only on a new SD card (`make sd-card`), and an install copies it from the card.
- **Services** are supervised and restarted when they exit. They can be stopped, started and restarted individually (`sv`). After 3 failures within a minute, the frontend falls back to a hardware status screen until the next boot.

## Seeing what happened

- **System log.** All service output, Specular's included, and the kernel's messages go to the system log: `logread` (`-f` to follow) shows this start's, from memory; `/system/logs/messages` and the older `messages.0` keep up to 1 MiB across reboots.
- **Start-up logs** are kept on the system partition. A copy goes to a FAT partition a PC can read (`brick-log/`: log, kernel messages, process list), refreshed every second during start-up, so a start that ends in a reset still leaves them.
- **Start-up progress codes** are written to a clock-chip register that survives resets. Boot another card and read it to see how far a failed start got.
- **Start-up failures** are shown on screen; once the system partition is mounted, as the recovery menu (below).
- **Recovery menu:** hold MENU while turning the device on, until the menu appears (a few seconds after the boot logo). D-pad and A choose, B goes back. It can continue starting, start the previous version, install an update file from `updates/` on the SD card's data partition (signed with the release key or, on development images, this checkout's key), or power off; it powers off by itself after 10 minutes without a press. Its log is `/system/logs/recovery-<time>.log`, and brick-install's is in `logs/` on the card ([docs/boot.md](docs/boot.md)).
- **Installer logs** go to `logs/` on the SD card: every task (install, restore, update, activate), with each write to a boot slot or the start-up settings and the settings' state before and after.
- **Start-up settings:** `tools/sdboot/uboot-env.py <image or /dev/mmcblkN> [key]` shows which copy of U-Boot's settings U-Boot will use and what it says (it runs on the PC; on the device, `brick-install slots` gives the slot that starts next).
- **SD card:** `cat /run/card/state` says how the card stands (docs/storage.md); `/run/card/check.log` has the last check's output; `logread | grep mount-card` shows each run (why it ran, what it chose, the check, each state); `logs/card-check.log` on the card keeps every repair. `touch /run/card/trace` traces every following run command by command into that file (`rm` it to stop). `touch /dev/mdev.log` makes mdev log each device event there (`rm` to stop). After pulling a card or a test, `/usr/libexec/brick/mount-card` makes the mount match the slot again.
- **Power settings and the battery:** `brick-power` (no arguments) prints the CPU profile, the CPU speeds and thermal step in effect, the governor's sampling, the GPU clock, the top USB port and the battery guard's verdict. `/usr/libexec/brick/battery-guard state` takes one battery sample. The guard logs (tag `battery-guard`) every sample while the battery is low; `logread | /usr/libexec/brick/battery-guard replay` (or the same on the PC, from a copy of the log) shows what it decided and why. To watch a discharge without the guard powering off: `sv stop battery-guard; setsid sh -c 'DRY_RUN=1 /usr/libexec/brick/battery-guard | logger -t battery-guard' &` (until the next start-up).
- **Kernel facilities:**
  - perf events: hardware counters and sampling (below). Tracepoints and probes are not available (so no `perf trace`, `perf sched`, `perf probe`): kernel tracing (`FTRACE`, `KPROBES`, `UPROBES`) is off.
  - debugfs.
  - Magic SysRq.
  - The running kernel's configuration at `/proc/config.gz`.
  - Kernel symbols.
  - `/dev/mem`.
  - I2C device files.
- **Expensive kernel debugging is off by default:** slab, mutex and VM checks. Slab checks cost a GPU-heavy game about 12 %.
- **Kernel crash records:** after an oops or panic (the device resets within 16 s), the next start copies the kernel log saved at the time to `/system/logs/crash-<UTC time>/dmesg-pstore_blk-<n>`; the newest 10 are kept. `dmesg | grep pstore_blk` should show "attached mmcblkXpN"; otherwise nothing is recorded ([docs/boot.md](docs/boot.md)). To try it on a development build: `echo c > /proc/sysrq-trigger`.
- **Device-tree edits:** the kernel makes our device-tree changes (`system/board/brick/dt-tweaks.sh`) itself at start-up ([docs/boot.md](docs/boot.md)). `cat /proc/device-tree/chosen/crystaline,dt-edits` says `ok <table>: <counts>` or why it failed (then none of the edits were applied, so the buttons don't work: reach the device over SSH); `dmesg | grep dt-edits` has the same and each value U-Boot had set first; rcS copies both into `/system/logs/rcS.log`. From the PC, `tools/system/dt-check.sh` checks that the device's tree is what this checkout's edits make of U-Boot's (`/sys/firmware/fdt-bootloader`) and saves both in `build/dt-samples/`. A change to `dt-tweaks.sh` is built into the kernel, so it reaches a device with `make update-device` like any other.

## Debugging programs

`strace`, `gdbserver` and `perf` are in development images; a release image gets them with `make debug-running-release` (below).

- **strace:** `strace -p <pid>`, or `strace <command>`; `-k` adds each call's stack.
- **perf:** `perf stat -p <pid>` counts CPU events; `perf record --call-graph dwarf -p <pid> -- sleep 10` then `perf report` samples where time goes (`-g` instead of `--call-graph dwarf` is cheaper, but our programs are built without frame pointers, so its stacks are cut short); `perf top` shows it live. Programs in the image are stripped, so perf names only the functions a program exports; for the rest, run a build that keeps its symbols (below).
- **gdb**, from the PC, with the cross gdb Buildroot builds:
  1. On the device: `gdbserver --attach :2345 <pid>`, or `gdbserver :2345 <program> <args>`.
  2. On the PC: `build/buildroot/host/bin/aarch64-buildroot-linux-gnu-gdb -x build/buildroot/staging/usr/share/buildroot/gdbinit <program>`, then `target remote 192.168.7.2:2345`. `<program>` is the PC's copy of what runs on the device, with its symbols. The gdbinit points gdb at Buildroot's copies of the device's libraries (in `build/buildroot/staging`); those have function names but no line numbers. TrimUI's GPU libraries aren't there; `set solib-search-path $PWD/build/stock-root/usr/lib` finds them.
- **Builds that keep symbols:**
  - Our C programs: `rm build/tools/<tool>; make DEBUG=1 $PWD/build/tools/<tool>` (or `build/userspace/padbridge`; the Makefile names each program by its full path, so give that), then copy the result to the device: to `/tmp` to run it from there, or into the developer layer to replace the installed one. gdb's copy is the same file. It is still built with `-O2`, so gdb shows some variables as optimized out. `make system` would pack this build into the image; rebuild it the same way without `DEBUG=1` first.
  - Specular: `CARGO_PROFILE_RELEASE_STRIP=false CARGO_PROFILE_RELEASE_DEBUG=true make deploy-specular`; gdb's copy is `build/specular/aarch64-unknown-linux-gnu/release/specular`.
  - Buildroot's programs keep theirs in `build/buildroot/build/<package>/`.

## Debugging a release image

What a release image leaves out, and whether it can come back on a running device, without a rebuild or a reflash:

| Left out | Brought back |
|---|---|
| strace, gdbserver, perf, and the hardware test tools ("On-device tools", below) | `make debug-running-release`, until the device restarts |
| SSH with the checkout's key, always on | No. SSH with your own key instead, switched on on the device with `brick-ssh` (above; not possible until Specular's developer settings run it); `make debug-running-release` needs it |
| Login on the serial console | No: root has no usable password (`*` in `/etc/shadow`, on the read-only root filesystem) |
| Updates signed with the checkout's key | No. To get back to a development image, start the previous version from the recovery menu (if that is a development image), or write a card |

The kernel is the same in both kinds of image, with the same facilities ("Kernel facilities" above).

`make debug-running-release` (`BRICK=` as usual; `SSH_KEY=<private key file>` unless ssh offers your key by itself) copies the tools from this checkout's build (Buildroot's, and the device tools) to `/run/debug` on the device. That is memory (about 9 MB): nothing on the device's storage changes, and they are gone at the next restart, when it can simply be run again. Then, in an SSH session on the device, `. /run/debug/env` puts them on `PATH`, and they work as in "Debugging programs" above. It refuses, and removes the copy, if the device's dynamic loader finds that a program needs a library or library version the device lacks; to fix that, check out the commit at the end of the device's version (`/etc/brick-version`) and run it again (it builds Buildroot and the device tools first). gdb on the PC uses this checkout's copies of programs and libraries, which for a release built elsewhere (the GitHub release workflow) may not match the device's: `set sysroot target:` makes it read the device's own instead, which are stripped, so it names only exported functions; for more, build from the release's commit.

## Testing

Each test prints PASS, or FAIL and the first failure. `make test-battery-guard`, `test-mount-card` and `test-timezone` run their script under a PC build of the device's BusyBox (`tools/system/pc-busybox.sh`, into `build/pc-busybox/`, rebuilt when Buildroot's BusyBox configuration changes), so it sees BusyBox's shell and tools, as on the device. Before `make buildroot` they use the PC's, and say so.

- **Installer test harness** (`make test-installer`, after `make sd-card`): runs the installer on the PC against image files of a stock device and our SD card. It covers the card's layout and settings, install, backup, restore (prepared from the installed system, and cancelled), installs and restores cut short, update files (good, wrongly signed and damaged ones, and versions whose kernel doesn't make the device-tree changes), updates cut short at every write that matters (`BRICK_INSTALL_CUT`, in its own build only), going back to the previous version, and the battery check. Root is not needed.
- **Battery guard test** (`make test-battery-guard`): runs the low-battery guard on the PC over sequences of samples (confused gauge, voltage dips, charging, a weak cable, a missing or unreadable battery) and against a fake battery.
- **SD card test harness** (`make test-mount-card`): runs `mount-card` on the PC against a fake device (sysfs, mount table) and image files for cards: first start, PC-formatted and exFAT cards, damaged and read-only cards, removal, swaps, the system's own card pulled, a first start cut short, and runs overlapping. Needs dosfstools on the PC, and exfatprogs for the exFAT cases (skipped without it). Root is not needed.
- **Bluetooth start-up test** (`make test-xr829-attach`, about 40 s): runs a PC build of `xr829-attach`, with every path under a fake root (`-DTEST_ROOT`), against a fake XR829 on a pty (`tools/system/test-xr829-attach.py`). The fake checks the boot ROM checksums, the port's speed and flow control at each stage, the uploaded firmware and the HCI commands. It covers the address (derived, kept, replaced), a boot ROM that answers late, reports an error or never answers, unexpected and refused HCI commands, the 20 s limit, and a missing chip ID or rfkill switch. Needs gcc and Python 3; root is not needed.
- **Time zone test** (`make test-timezone`): runs `brick-timezone` on the PC against a fake root with the PC's zone files and a stub `hwclock`. It covers zone names refused and accepted, the link glibc reads, the kernel's offset given only on a change and retried after a failure, and a zone file that has gone. Under BusyBox, the script sees only BusyBox's tools and the stubs. Needs the PC's tzdata.
- **Device-tree edits test** (`make test-dt-edits`, a few seconds): generates the kernel's edits table from `dt-tweaks.sh` and applies it on the PC with the kernel's own code. It checks the result against `dt-tweaks.sh` run directly, that applying it again or to an already-patched tree changes nothing, that U-Boot's eMMC tuning is kept and other values set before the kernel are replaced and logged, that a mismatch applies nothing, and that the recorder refuses what the kernel can't redo. Trees saved from devices in `build/dt-samples/` (by `tools/system/dt-check.sh`) are applied too, with their log lines printed. Needs dtc and `build/stock-fw` (`make stock-fw`). `KERNEL_SRC=<kernel tree>` tests another tree than `linux/`.
- **exFAT driver test** (`make test-exfat`, after `make buildroot`; the first run also builds QEMU, about 15 minutes, and the test kernel; after that about 4 minutes): boots our kernel, with lock checking, in QEMU on an initramfs made from the device's root filesystem, against a virtual disk, using the device's `mkfs.exfat`/`fsck.exfat` and mount-card's mount options. The functional suite covers file operations, names matched regardless of case, saves by rename, preallocated files (as Windows and macOS write them) read through the page cache, `O_DIRECT` and `mmap`, timestamps outside exFAT's range, loop images and which remounts the driver accepts. Then `ROUNDS` power cuts (default 10): writes, saves and mkdir/rm reset 3–14 s in, then `fsck.exfat -n`, a repair with `-p` if it finds errors, and a check that the last save is whole. Any kernel warning fails it. QEMU (`build/qemu`) and the test kernel (`build/test-exfat/`) are kept for the next run. Logs are in `build/test-exfat/logs/`. `KERNEL_SRC=<kernel tree>` tests another tree than `linux/`. Not part of the release workflow: too slow.
- **Overnight power test** (`powertest`): logs battery drain across deep sleep, idle and load to the SD card. The settings it compares are chosen from the environment (`TUNED_PROFILE`, `TUNED_USB_TOP`, `TUNED_SAMPLING`; see its header).

## Making a release

1. Tag the commit with today's date and push the tag: `git tag v0.2026.10.18 && git push origin v0.2026.10.18`. A second release on the same day is `v0.2026.10.18.2`, then `.3`, and so on. The workflow refuses any other form of tag, and a date more than a day ahead or more than a week old.
2. GitHub Actions (`.github/workflows/release.yml`) runs `make system sd-card RELEASE=1` and the PC tests (every `make test-*` in "Testing" but `test-exfat`, which takes too long), then waits for a reviewer to approve the `release` environment. Once approved, it signs the update file and makes a draft release named after the tag. The draft holds `crystaline-<tag>-sd-card.img.xz`, `crystaline-<tag>.update` and `SHA256SUMS`; its notes give the system version, commit and build time.
3. Check the draft and publish it.

Running the workflow by hand (Actions → Release → Run workflow) builds and tests without releasing; the results stay with the run for 30 days. Runs on `main` save the caches (third-party inputs, Buildroot's downloads and its output), because a tag's run can use only caches made on `main`. A push to `main` that changes Buildroot's configuration, the `Makefile` or a pin starts such a run by itself; without it, the next release would build Buildroot from scratch, which takes about an hour longer.

One-time setup of the GitHub repository:
- **Variable `TRIMUI_FW_URL`** (Settings → Secrets and variables → Actions → Variables): a download address of TrimUI's `trimui_tg3040.awimg` v1.1.1.
- **The release key.** Make it on your PC: `openssl genpkey -algorithm ed25519 -out release.pem`. Put its public half in place with `tools/system/sign-update.sh --public-key release.pem >system/board/brick/update-keys/release.pub`, and commit it before tagging: devices accept only updates signed with the key their system was built with. Keep `release.pem` safe offline; GitHub never shows a secret again.
- **Environment `release`** (Settings → Environments): a required reviewer, deployments limited to tags matching `v*`, and the secret `UPDATE_SIGNING_KEY` holding the whole of `release.pem`. Before signing, the workflow checks that the secret matches `release.pub`.

## On-device tools

In development images. Release images have only `sleepnow` and `status`; `make debug-running-release` brings the rest.

| Tool | What it does |
|---|---|
| `dispctl` | Backlight level and panel on/off |
| `glspin` | GPU test that reports fps |
| `rumble` | Rumble test |
| `i2creg` | Read/write a register over I2C |
| `memreg` | Read/write a physical memory register |
| `blkro` | Mark a block device read-only |
| `sleepnow` | Deep sleep now (stops WiFi first; powers off instead with the battery empty) |
| `powertest` | Overnight power test |
| `status` | Hardware status screen; also the fallback frontend, the start-up error screen and the recovery menu |

## Hardware research

The probe scripts (`tools/probe/`) take a read-only snapshot of a device running TrimUI's stock firmware over SSH (hardware, drivers, registers, memory dumps), for comparison with ours.
