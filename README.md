# Crystaline OS

A simple, polished, handheld gaming experience.

## Ethos

1. No Compromises.
   All hardware features must be supported and function to the best of the hardware's ability. No known issues to be left in a release, no matter how small.
   
2. Performance and Efficiency
   An extension/callout of "No Compromises" above - specifically to always aim to extract the maximum performance when needed, but maintain the lowest required power draw.
   
3. First-class Debugging and Development.
   Developing for hardware is hard enough. Development tools, flags, and features are to be weighted as importantly as all other user-facing features. In-place updates, fast builds, no SD Card Swapping.

4. No Manuals.
   All features, errors, configurations, menus, etc. that the user is exposed to or needs to make a decision or act on are either very obvious, or are explained directly in the UI where they are presented (or in an adjacent file, e.g. a schema file for file-based interfaces such as configs and cores).


## Installing on your device

### Supported Devices

- TrimUI Brick (TG3040), including the Brick Hammer edition

### Installation

> No release has been published yet. Until then, build the SD card image yourself (see [Developer setup](#developer-setup)).

Crystaline OS runs from a microSD card. TrimUI's own system stays on the device untouched until you choose to install to internal storage.

You need:
- A microSD card of at least 2 GB. **Everything on it will be erased.**
- A card reader for your computer.
- [balenaEtcher](https://etcher.balena.io/), which runs on Windows, macOS and Linux.

1. Download the SD card image (`crystaline-<release>-sd-card.img.xz`) of the latest release from the Releases page. balenaEtcher reads it as it is: no need to unpack it.
2. Open balenaEtcher. Choose **Flash from file** and pick the image. Choose your SD card as the target, then **Flash**.
   If your computer then asks to format the card, click **Cancel**. Some of the card's partitions are ones your computer can't read.
3. Put the card in the Brick and turn it on. The first start takes a little longer while it prepares the card's storage space.
4. Turn the Brick off and put the card back in your computer. It shows up as a drive named `BRICK`.
5. Copy your games into its `roms` folder. Any sub-folders are fine. BIOS files go in the `bios` folder.

**Going back to TrimUI's system:** take the card out and restart.

**Installing onto the device itself.** This frees the card for games and saves only.
1. Open **Settings → Internal storage**.
2. Choose to back up TrimUI's system to the card first. The backup is your way back to TrimUI's system.
3. Once installed, any card formatted FAT32 or exFAT (as most cards come) works for your games.

**Going back to TrimUI's system after installing.** You need a Crystaline OS SD card with the backup in its `backups` folder, such as the card you installed from.
1. With that card in, open **Settings → Internal storage** and choose to restore the backup.
2. The Brick restarts from the card and asks you to confirm the restore.
3. Once it is done, take the card out and restart.

**File transfer has no password:** while its screen is open, anyone on your network can read and change the card's files.

## Developer setup

Building needs a Linux PC (on Windows, use WSL 2).

You need:
- **Host tools:** make, gcc/g++, git, curl, rsync, cmake, python3, dtc (`fdtget`/`fdtput`), 7z, pkg-config and fontconfig's development files, e2fsprogs (a `mke2fs` that supports `-d` and `orphan_file`, plus `debugfs`), sfdisk (util-linux), and OpenSSH (`ssh`, `scp`, `ssh-keygen`). Also everything [Buildroot requires](https://buildroot.org/downloads/manual/manual.html#requirement-mandatory).
- **Rust**, through [rustup]. The pinned toolchain and the `aarch64-unknown-linux-gnu` target are installed on first build.
- **Third-party inputs**, fetched and checked by `tools/fetch-third-party.sh` ([DEVELOPMENT.md](DEVELOPMENT.md#third-party-inputs)). `tools/env.sh` lists where each is expected in `third-party/`, and each location can be overridden by an environment variable:
  - The cross compiler from Creality's Sonic Pad SDK ([CrealityTech/sonic_pad_os]; GCC 6.4, glibc 2.23).
  - The PowerVR GPU kernel driver source ([pocketforge-os/gpu-km-tsp]).
  - TrimUI's stock firmware v1.1.1 (`trimui_tg3040.awimg`). It supplies the first-stage loader, U-Boot, the GPU libraries and the WiFi/Bluetooth firmware. It has no stable download address: set `TRIMUI_FW_URL` to one, or put the file in place yourself.
  - dufs v0.46.0 (static aarch64 binary), the WebDAV server.
- **Submodules:** clone with `--recurse-submodules`. The kernel ([Crystaline Linux], a fork of PocketForge's kernel-tsp) and the [Specular] frontend are separate repositories.

Buildroot is downloaded and checked automatically.

`make sd-card` builds an SD card image. `make help` lists everything else. See [DEVELOPMENT.md](DEVELOPMENT.md) for working with a device.

## License

GPL-3.0-only (see [LICENSE](LICENSE)), except files whose header says otherwise: some on-device tools are GPL-2.0, as is the kernel in its own repository.

[rustup]: https://rustup.rs
[Crystaline Linux]: https://github.com/bravenewaiworld/crystaline-linux
[Specular]: https://github.com/bravenewaiworld/specular
[pocketforge-os/gpu-km-tsp]: https://github.com/pocketforge-os/gpu-km-tsp
[CrealityTech/sonic_pad_os]: https://github.com/CrealityTech/sonic_pad_os
