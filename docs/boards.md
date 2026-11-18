# Boards and families

Status: In progress · Updated: 2026-11-11

How one tree builds Crystaline OS for more than one device. A board is one device model; a family is the boards that share one kernel and one root filesystem; a SoC is a family member's main chip. The Brick is the only board of the brick family (TrimUI's 4.9 kernel); the Powkiddy RGB20 Pro is the first board of the mainline family (mainline Linux, [mainline.md](mainline.md)).

## Decisions

- **Each file lives in the most general layer that is true for it: common, family, SoC, board** (2026-11-11). A board adds data, not code, so a new board of an existing family is a few files. Rejected: a repository per vendor or board as submodules (more moving parts before a second family exists).
- **One kernel and one root filesystem for every board of a family; the board is picked at start-up** (2026-11-11). Images and updates are per family, not per board, and a board's differences are names, not programs. Rejected: an image per board (twice the builds and update files for the same code).
- **Shared programs and paths are named `crystaline-*`, not `brick-*`** (2026-11-11). Names already written on Brick cards and in their U-Boot settings stay as they are: the ext4 label `brick-system`, the FAT label `BRICK`, `brick.boot=`, and the installer's `BRICK-INSTALLING` markers.
- **Each board has its own USB network** (`BOARD_USB_NET`: Brick 192.168.7, RGB20 Pro 192.168.8) (2026-11-11), so two devices can be plugged into one PC.

## Design

```text
system/
  common/                  every board: services, start-up (initramfs, rcS), scripts, web page,
                           update keys, BusyBox fragment, post-build, buildroot.config
  family/<family>/         buildroot.config (CPU, headers, graphics), rootfs-overlay (family-hooks,
                           family-only services and programs), kernel.config (mainline)
  soc/<soc>/kernel.config  mainline: the chip's kernel options
  board/<board>/           board.mk, kernel.config (mainline), rootfs-overlay: boards/<board>.env,
                           card-guides/
  buildroot-patches/       our changes to Buildroot's own package definitions
  package/, patches/       our Buildroot packages, patches to packages' sources
tools/system/parts-<family>.sh   what build-system.sh does differently per family
tools/<family>/ (mainline)       kmake.sh, build-card.sh, build-mali.sh
```

`make DEVICE=<board>` reads `system/board/<board>/board.mk` and builds into `build/<family>/`; the checkout's keys (`build/ssh-host-keys`), Buildroot's source and downloads stay shared in `build/`. Buildroot's configuration is `common/buildroot.config`, then the family's, then the overlays the Makefile adds: common, the family's, and every board of the family's (`tools/system/family-boards.sh`).

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
BOARD_BATTERY=rk817-battery              # /sys/class/power_supply name
BOARD_WIFI_MODULE=rtw88_8821cs           # loaded by the wpa_supplicant service
BOARD_USB_NET=192.168.8                  # the USB link's /24; the device is .2
```

Each family's `/usr/libexec/crystaline/family-hooks` defines what start-up does differently, sourced by the initramfs's init and by rcS:

```sh
progress CODE      # how far start-up got (Brick: clock-chip register; mainline: a kernel log line)
start_hardware     # rcS: drivers and settings before the card is mounted (GPU driver, CPU profile)
rescue             # start-up failed for good: make it visible another way (mainline: status LED blinks)
```

`make test-board-env` tests `board-env` and checks every board file names everything the scripts read.
