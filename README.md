# Crystaline OS

A simple, polished, handheld gaming experience.

## Ethos

1. No Compromises.
   All hardware features must be supported and function to the best of the hardware's ability. No known issues to be left in a release, no matter how small.
   
2. Performance and Efficiency
   An extension/callout of "No Compromises" above - specifically to always aim to extract the maximum performance when needed, but maintain the lowest required power draw.
   
3. First-class Debugging and Development.
   Developing for hardware is hard enough. Development tools, flags, and features are to be weighted as importantly as all other user-facing features. In-place updates, fast builds, no SD Card Swapping.


## Installing on your device

### Supported Devices

- TrimUI Brick (TG3040), including the Brick Hammer edition

### Installation

> No release has been published yet. Until then, build the SD card image yourself (see [Developer setup](#developer-setup)).

Crystaline OS runs from a microSD card. TrimUI's own system stays on the device untouched until you choose to install to internal storage.

You need:
- A microSD card. **Everything on it will be erased.**
- A card reader for your computer.
- [balenaEtcher](https://etcher.balena.io/), which runs on Windows, macOS and Linux.

1. Download the latest `crystaline-os-sd-card.img` from the Releases page.
2. Open balenaEtcher. Choose **Flash from file** and pick the image. Choose your SD card as the target, then **Flash**.
   If your computer then asks to format the card, click **Cancel**. Some of the card's partitions are ones your computer can't read.
3. Put the card in the Brick and turn it on. The first start takes a little longer while it prepares the card's storage space.
4. Turn the Brick off and put the card back in your computer. It shows up as a drive named `BRICK`.
5. Make a folder named `roms` on it and copy your games into it. Any sub-folders are fine. BIOS files go in a folder named `bios`.

**Going back to TrimUI's system:** take the card out and restart.

**Installing onto the device itself.** This frees the card for games and saves only.
1. Open **Settings → Internal storage**.
2. Choose to back up TrimUI's system to the card first. The backup is your way back to TrimUI's system.
3. Once installed, any card you use must be formatted FAT32. Most cards over 32 GB come formatted exFAT, which doesn't work yet.

**Going back to TrimUI's system after installing.** Restoring only works when the Brick has started from a Crystaline OS SD card.
1. Copy the card's `backups` folder to your computer.
2. Flash the card again as above (this erases it). Start the Brick from it once, then turn it off.
3. Copy the `backups` folder back onto the card.
4. Turn the Brick on with the card in, open **Settings → Internal storage**, and restore the backup.

**While Crystaline OS is in development:** anyone on your WiFi network can read and change the card's files while WiFi is on.

## Developer setup

Building needs a Linux PC (on Windows, use WSL 2).

You need:
- **Host tools:** make, gcc/g++, git, curl, rsync, cmake, python3, dtc (`fdtget`/`fdtput`), e2fsprogs (a `mke2fs` that supports `-d` and `orphan_file`, plus `debugfs`), sfdisk (util-linux), and OpenSSH (`ssh`, `scp`, `ssh-keygen`). Also everything [Buildroot requires](https://buildroot.org/downloads/manual/manual.html#requirement-mandatory).
- **Rust**, through [rustup]. The pinned toolchain and the `aarch64-unknown-linux-gnu` target are installed on first build.
- **Third-party inputs** that are not downloaded automatically yet. `tools/env.sh` lists where each is expected in `third-party/`, and each location can be overridden by an environment variable:
  - The cross compiler from Creality's Sonic Pad SDK ([CrealityTech/sonic_pad_os]; GCC 6.4, glibc 2.23).
  - The PowerVR GPU kernel driver source ([pocketforge-os/gpu-km-tsp]).
  - TrimUI's stock firmware v1.1.1 (`trimui_tg3040.awimg`). It supplies the first-stage loader, U-Boot, the GPU libraries and the WiFi/Bluetooth firmware.
  - dufs v0.46.0 (static aarch64 binary), the WebDAV server.
- **Submodules:** clone with `--recurse-submodules`. The kernel ([Crystaline Linux], a fork of PocketForge's kernel-tsp) and the [Specular] frontend are separate repositories.

Buildroot is downloaded and checked automatically.

`make sd-card` builds an SD card image. `make help` lists everything else. See [DEVELOPMENT.md](DEVELOPMENT.md) for working with a device.

[rustup]: https://rustup.rs
[Crystaline Linux]: https://github.com/bravenewaiworld/crystaline-linux
[Specular]: https://github.com/bravenewaiworld/specular
[pocketforge-os/gpu-km-tsp]: https://github.com/pocketforge-os/gpu-km-tsp
[CrealityTech/sonic_pad_os]: https://github.com/CrealityTech/sonic_pad_os
