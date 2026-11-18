# Boards and families

Status: In progress · Updated: 2026-11-18

How one tree builds Crystaline OS for more than one device. A board is one device model; a family is the boards that share one kernel and one root filesystem; a SoC is a family member's main chip. The Brick is the only board of the brick family (TrimUI's 4.9 kernel); the Powkiddy RGB20 Pro is the first board of the mainline family (mainline Linux, [mainline.md](mainline.md)).

## Decisions

- **Each file lives in the most general layer that is true for it: common, family, SoC, board** (2026-11-11). A board adds data, not code, so a new board of an existing family is a few files. Rejected: a repository per vendor or board as submodules (more moving parts before a second family exists).
- **One kernel and one root filesystem for every board of a family; the board is picked at start-up** (2026-11-11). Images and updates are per family, not per board, and a board's differences are names, not programs. Rejected: an image per board (twice the builds and update files for the same code).
- **Shared programs and paths are named `crystaline-*`, not `brick-*`** (2026-11-11). Names already written on Brick cards and in their U-Boot settings stay as they are: the ext4 label `brick-system`, the FAT label `BRICK`, `brick.boot=`, and the installer's `BRICK-INSTALLING` markers.
- **Each board has its own USB network** (`BOARD_USB_NET`: Brick 192.168.7, RGB20 Pro 192.168.8) (2026-11-11), so two devices can be plugged into one PC.
- **The mainline family's floor is the Cortex-A55 (ARMv8.2)** (2026-11-12): Buildroot builds for it (`BR2_cortex_a55`) and so do Specular and its cores (`SPECULAR_CPU_mainline`), so the RK3566, RK3588 and later fit, but Cortex-A53 and A72 boards (RK3328, RK3399) can't join this root filesystem. Rejected: an ARMv8.0 build (slower code on every board for boards no one has asked for).
- **What a board needs is data in its own folder; the shared layers read it** (2026-11-18): hardware names in its board file, linux-firmware sets in its `buildroot.config`, other firmware in `parts.sh` (and its download in `fetch.sh`), modules nothing else loads in `BOARD_MODULES`, its GPU's open driver in `BOARD_GPU_MODULE`; a SoC's kernel options and ARM GPU library in `system/soc/<soc>/`. Rejected: lists of boards' chips in family code (the next board would edit shared files).
- **Shaped for the boards that exist; known limits, each lifted when a board needs it** (2026-11-18):
  - The kernel's console is `console=ttyS2,1500000` in the mainline family's one `extlinux.conf` (Rockchip's debug UART). A board of another vendor wants it from U-Boot's settings (`${console}`) or the device tree's `stdout-path`.
  - CPU speed is one cpufreq policy (`policy0`, in `crystaline-power` and the status screen) and one `BOARD_CPU_EFFICIENT_MHZ`: right where all cores share a clock (the Brick, the RK3566). A big.LITTLE SoC (the RK3588: `policy0`, `policy4`, `policy6`) wants each policy handled, with a speed per policy.
  - The status screen (`tools/device/status.c`, also the recovery menu) is laid out for 1024x768 at scale 2 (64 by 24 cells); a smaller panel cuts its menus, a TV shows small text. It wants the scale and rows from the screen's size.
  - The loader's SoC facts are in `tools/mainline/build-loader.sh` (`case $SOC`), `build-card.sh` (`u-boot-rockchip.bin` at sector 64) and `tools/env.sh` (`RK3566_DDR`, `RK3566_BL31`). A second SoC wants them in `system/soc/<soc>/loader.sh`.
  - ARM's GPU driver is one per family image: one libmali (the SoC's `BR2_PACKAGE_LIBMALI_LIB`) and one Bifrost `mali_kbase` (`tools/mainline/build-mali.sh`), and `crystaline-gpu` names the choices `panfrost` and `mali`. Two SoCs with different Malis want one of each per SoC, picked at start-up.
  - The start-up log (the initramfs's `crystaline-log/`) is saved on the Brick card's `bootloader` partition; mainline cards have none, so it isn't saved there.
  - Installing onto internal storage is the Brick family's only (`crystaline-install`): its layout is TrimUI's eMMC.
  - The Makefile's family rules are `ifeq ($(FAMILY),mainline) ... else` (the Brick's); a third family wants them per family.

## Design

```text
system/
  common/                  every board: services, start-up (initramfs, rcS), scripts, web page,
                           update keys, BusyBox fragment, post-build, buildroot.config
  family/<family>/         buildroot.config (CPU, headers, graphics), rootfs-overlay (family-hooks,
                           family-only services and programs), kernel.config (mainline)
  soc/<soc>/                kernel.config: the chip's kernel options; buildroot.config (optional,
                           e.g. its ARM GPU library) (mainline)
  board/<board>/           board.mk, kernel.config (mainline), rootfs-overlay: boards/<board>.env,
                           card-guides/; optional: buildroot.config (its chips' linux-firmware),
                           parts.sh (other files for the root filesystem, e.g. firmware),
                           fetch.sh (their downloads)
  buildroot-patches/       our changes to Buildroot's own package definitions
  package/, patches/       our Buildroot packages, patches to packages' sources
tools/system/parts-<family>.sh   what build-system.sh does differently per family
tools/<family>/ (mainline)       kmake.sh, build-card.sh, build-mali.sh
```

`make DEVICE=<board>` reads `system/board/<board>/board.mk` and builds into `build/<family>/`; the checkout's keys (`build/ssh-host-keys`), Buildroot's source and downloads stay shared in `build/`. Buildroot's configuration is `common/buildroot.config`, then the family's, then each SoC's and board's of the family that has one, then the overlays the Makefile adds: common, the family's, and every board of the family's (`tools/system/family-boards.sh`). The root filesystem holds every board's parts, since every board of the family runs it.

```make
# system/board/rgb20pro/board.mk: read with grep and sed by tools/, one "NAME := value" per line
FAMILY := mainline
SOC := rk3566
DTB := rockchip/rk3566-powkiddy-rgb20-pro.dtb
```

At start-up `board-env` matches `/proc/device-tree/compatible` against the installed `boards/*.env` (device's most specific string first); rcS copies the match to `/run/crystaline/board.env`, which scripts source, and the initramfs runs it itself.

```sh
# system/board/<board>/rootfs-overlay/usr/share/crystaline/boards/<board>.env
BOARD_COMPATIBLE=powkiddy,rgb20-pro      # unquoted: board-env greps for the line
BOARD_NAME='RGB20 Pro'                   # shown to people
BOARD_CARD_CONTROLLER=fe2b0000.mmc       # the boot SD slot, as /sys/bus/platform/devices names it
BOARD_CARD_LABEL=RGB20PRO                # FAT label mount-card gives the games partition (≤ 11)
BOARD_USB_NET=192.168.8                  # the USB link's /24; the device is .2
# The names above are required; the rest are for hardware a board may not have, e.g.:
BOARD_WIFI_MODULE=rtw88_8723ds           # loaded by the wpa_supplicant service
BOARD_MODULES=hci_uart                   # loaded at start-up (family-hooks)
BOARD_GPU_MODULE=panfrost                # the GPU's open driver (family-hooks)
```

Each family's `/usr/libexec/crystaline/family-hooks` defines what start-up does differently, sourced by the initramfs's init and by rcS:

```sh
progress CODE      # how far start-up got (Brick: clock-chip register; mainline: a kernel log line)
start_hardware     # rcS: drivers and settings before the card is mounted (GPU driver, CPU profile)
rescue             # start-up failed for good: make it visible another way (mainline: status LED blinks)
```

`make test-board-env` tests `board-env` and checks every board file gives the required names. The battery and the charger are found by their power-supply type, not named.
