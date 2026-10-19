# Boot

Status: Implemented · Updated: 2026-10-18

How the Brick gets from power-on to our system: Allwinner's boot ROM, TrimUI's first-stage loader and U-Boot, our kernel and its initramfs, then the system's own start-up. Also where these pieces sit on a disk, how our device-tree changes reach the kernel, the watchdog, and how a start that fails is diagnosed. Getting this wrong bricks nothing (the boot ROM always tries the SD card first) but makes failures silent, so most of the design is about leaving evidence.

## Decisions

- **TrimUI's boot0, U-Boot 2018.05, TF-A and co-processor firmware are used unchanged** (2026-10-10). They are unsigned, start from the SD card or the eMMC, and set up what the vendor kernel relies on: DRAM, every PLL, the panel's identity (`lcd=`) and the deep-sleep firmware. Rejected: a mainline boot chain (mainline U-Boot has no LPDDR3 timings for the A133, there is no open sleep firmware, and the vendor kernel hangs unless boot0 has enabled every PLL; [platform.md](platform.md)).
- **Our kernel makes our device-tree changes itself, to the tree U-Boot hands it, before reading it; TrimUI's boot package is used unchanged** (2026-10-18). Vendor U-Boot hands the kernel the DTB in the boot package (after its own fixups) and ignores one in the boot image, and it reads its own settings from it (`/soc/target`, `card0_boot_para`, `lcd0`, the power chip's nodes), so the tree stays TrimUI's. `dt-tweaks.sh` stays the one description of the changes, as `fdtput`/`fdtget` calls; each kernel build runs it on TrimUI's DTB, records the calls and compiles them in as a table (Design: Device-tree edits). The changes then travel with the kernel, in the boot slot: an update or going back to the previous version brings its own, which a boot package written once at install never could. Rejected: editing the DTB inside the boot package (chosen 2026-10-10; updates never reach the boot package, so installed devices kept the changes of the build they were installed from); our own device-tree source (U-Boot would lose the vendor nodes it reads, and the kernel would have to redo U-Boot's fixups: memory size, DRAM parameters, logo reservation, per-unit eMMC tuning); a device-tree overlay built into the kernel (4.9's overlays can't delete properties, run after early readers of the tree, and would be a second copy of the changes to keep equal); U-Boot `fdt` commands in its boot command (a failing command leaves a half-edited tree with no record, and every device's settings would need changing).
- **If any edit fails, none are applied: the kernel boots TrimUI's tree as U-Boot handed it, and says so** (2026-10-18): a critical kernel message and `/chosen/crystaline,dt-edits = "failed: …"`, which rcS copies into `/system/logs/rcS.log`. A half-edited tree could mix our changes with TrimUI's in ways nobody tested. The device then has no buttons (their input device, `/brick-keys`, is one of the edits), so no recovery menu, but it starts and can be reached over SSH. Rejected: panicking (a reset loop with no record: crash records aren't up yet); keeping the edits made before the failure.
- **Values U-Boot changed from TrimUI's are replaced by ours and logged, except where marked `KEEP_UBOOT_VALUE=1`** (2026-10-18): only the eMMC's per-unit tuning (`sdc_tm4_*`), which U-Boot measures on an eMMC boot. The table records TrimUI's value for each property it sets, so the kernel can tell a value U-Boot changed from TrimUI's own.
- **The kernel and an initramfs go in an Android v0 boot image made from TrimUI's as a template** (2026-10-14), since U-Boot loads it with `sunxi_flash read 45000000 boot; bootm`. We append `rdinit=/init` (runs our initramfs; TrimUI's settings say `/rdinit`), `log_buf_len=1M` (TrimUI's 16 KiB buffer loses the first ~1.5 s) and `loglevel=4`.
- **The boot image decides which system version runs** (2026-10-14): its initramfs carries its version and mounts `images/<that version>/` from the system partition, so the kernel and its modules always match ([install-and-update.md](install-and-update.md)).
- **The system partition is found by its filesystem UUID**, which U-Boot's settings pass as `root=UUID=…` (2026-10-14). The SD card and the eMMC have partitions with the same names, and `mmcblkN` numbers depend on probe order. Rejected: U-Boot's default `root=/dev/mmcblk0pN`, which can name the eMMC's partition.
- **A 16 s hardware watchdog runs from the first second and is never stopped** (2026-10-14). The vendor driver arms it at probe and never resets it; the initramfs starts BusyBox's `watchdog` (reset every 4 s), which survives the hand-over to the system, so there is no unguarded gap and any hang becomes a reset.
- **Start-up progress is written to the clock chip's spare register 7** (2026-10-10 for kernel debugging, 2026-10-14 for start-up). It survives resets and power-off, and stock doesn't use it.
- **The start-up log is copied every second to the FAT "bootloader" partition** of the disk the system is on (2026-10-14), so a PC can read it, and a start that ends in a reset still leaves it.
- **A failed start shows its reason on screen and waits** (2026-10-14), using the `status` program from the initramfs; the watchdog daemon keeps the device from resetting.
- **No framebuffer console** (2026-10-10): it hangs the display driver's take-over of U-Boot's logo.
- **Serial console at warnings only** (2026-10-12). At 115200 baud each line holds a CPU and the console lock for about 5 ms, and the GPU's display module takes that lock on every flip. Rejected: TrimUI's `loglevel=8`.
- **Our boot logo replaces TrimUI's inside the bootloader partition's FAT image** (2026-10-14), by overwriting the stock `bootlogo.bmp` bytes in place (same size: 396×66, 24-bit), so no FAT tools or root rights are needed.
- **The boot logo is the Crystaline OS wordmark: three hexagons beside "CRYSTALINE", in Specular's look** (2026-10-18): Geist SemiBold, letter-spaced, Specular's teal and coral accents on black. It is drawn by `system/board/brick/logo/make-logo.py`, and the resulting `bootlogo.bmp` is committed, so building needs no font or image library. Rejected: TrimUI's logo redrawn (it shows TrimUI's name on our system).
- **No FEL (USB recovery) mode** (2026-10-18). The boot ROM tries the SD card first, so any of our cards recovers a device. Rejected for now: finding the board's FEL pads or using `fel-sdboot.sunxi` (only needed if starting from the SD card stops being enough).
- **Crash records (pstore) go to a small `pstore` partition in our own layout** (2026-10-18), on both the SD card image and the installed eMMC layout, with the kernel's block pstore pointed at it. The installed layout has no such partition today, and the vendor crash writer only knows the eMMC.

## Design

### Boot chain

```
boot ROM ─ SD card first, then eMMC; boot0 at sector 16, copy at 256
 └ boot0 (eGON, TrimUI's): DRAM, PLLs
    └ boot package at sector 32800 (TOC1): U-Boot 2018.05, TF-A BL31, arisc firmware, DTB
       └ U-Boot: settings from "env"/"env-redund", logo from "bootloader", DTB fixups,
         `sunxi_flash read 45000000 boot; bootm`
          └ our kernel (4.9.191) + initramfs /init; device-tree edits before it reads the tree
             └ /sbin/init (BusyBox) → /etc/init.d/rcS → runsvdir (services)
```

### Device-tree edits

```
build: tools/kmake.sh → tools/system/dt-edits.sh build/stock-fw/boot_package.fex <kernel build>/dt-edits.c
         runs dt-tweaks.sh on TrimUI's DTB with fdtput/fdtget replaced by dt-edits-record, which runs
         the real tool and logs each step with the bytes it left in the tree (and TrimUI's value
         before a set); the log becomes the table (CONFIG_OF_EDITS_TABLE, linux/drivers/of/fdt_edits.h)
boot:  unflatten_device_tree() → copy U-Boot's tree with 64 KiB to spare → apply the table in order
         set      already ours: in place · TrimUI's: applied · something else: replaced (logged),
                  or kept (logged) when marked KEEP_UBOOT_VALUE
         delete   absent is fine
         node     made with any missing parents; existing is fine
         expect   a value dt-tweaks.sh read (the phandles it copies into cells) must be the same
       → success: /chosen/crystaline,dt-edits = "ok <table id>: <n> applied, <n> in place, <n> kept, <n> replaced"
         failure: U-Boot's tree unedited but for "failed: edit <n> (<kind> <path> <prop>): <error>; table <id>"
         either: "; the bootloader's tree already had these edits …" added when it has a node they add
         table id: "dt-tweaks <sha256:12> on stock <sha256:12>", the first 12 hex digits of the SHA-256
                   of dt-tweaks.sh and of TrimUI's DTB
       → the copy becomes the kernel's tree: /sys/firmware/fdt; U-Boot's is /sys/firmware/fdt-bootloader
```

- **What dt-tweaks.sh may do:** `fdtput` with `-c`, `-d`, `-p`, `-t`, and `fdtget` with `-t`; nothing under `/chosen`, `/memory` or `/reserved-memory`, which the kernel has read before it edits. Anything else fails the kernel build, naming the command.
- **Log:** `dmesg | grep dt-edits`: the status above (critical on a failure), after a line for each kept or replaced value. A tree that already had the edits comes from a boot package patched by an older build, on devices installed before 2026-10-18.
- **Old patched boot packages** get the same edits on top, which change nothing already there; a change a later dt-tweaks.sh drops stays on such a device until it is installed again from a new SD card, so dt-tweaks.sh undoes a change by writing the undo (TrimUI's value, or deleting a property TrimUI lacks), not by dropping the line; a node added there stays.
- **Checking:** `make test-dt-edits` on the PC applies the table with the kernel's own code (`tools/system/dt-edits-apply.c`); `tools/system/dt-check.sh` compares a running device's two trees with this checkout's table.

### SD card layout (512-byte sectors)

```
0            protective MBR
1            GPT header
2-5          GPT entries (16 only, so they end before boot0)
16           boot0                      (byte 8 KiB: where the boot ROM looks first)
256          boot0 copy                 (byte 128 KiB: if the first is bad)
32800        boot package               (fixed in boot0 and U-Boot; at most 8160 sectors)
40960        bootloader  24 MiB  FAT    boot logo, battery pictures; brick-log/
90112        env          1 MiB         U-Boot settings
92160        env-redund   1 MiB         copy (U-Boot falls back to it on a bad CRC)
94208        boot        64 MiB         boot.img
225280       system    1040 MiB  ext4   1 GiB filesystem, label brick-system
…            sdcard      rest     FAT32  added on first start, label BRICK
```

Vendor U-Boot adds 40960 sectors (20 MiB) to partition offsets it looks up by name, so nothing can start below that. The eMMC's layout after an install is in [install-and-update.md](install-and-update.md).

### U-Boot's settings

TrimUI's `env.fex` with `mmc_root=UUID=<system partition>` set and `root_partition` and `blkoops_partition` removed (the latter names an eMMC crash partition the card lacks). Written twice in U-Boot's redundant format: CRC-32 of bytes 5…0x20000 at 0, a flags byte at 4, then `key=value` strings separated by NULs. The kernel command line is U-Boot's `bootargs` (built from these settings: `root=${mmc_root}`, `rdinit=/rdinit`, `loglevel=8`, `cma=64M`, …), then U-Boot's additions (`partitions=`, `androidboot.serialno=`, `lcd=`, …), then the boot image's command line last, so ours wins for repeated keys.

### Initramfs

`/init` does, in order: mount `/proc`, `/sys`, `/dev`; start the watchdog daemon; find the system partition by UUID (retrying 5 s); start copying its log, `dmesg` and `ps` to `brick-log/` on the bootloader partition every second; run `e2fsck -p` (exit 2: reboot; 4 or more: fail); mount the system partition; loop-mount `images/<version>/rootfs.squashfs`; put a developer layer over it if `overlay/<version>/` exists ([system-image.md](system-image.md)); save the log to `/system/logs/init.log`; move `/system`, `/dev`, `/proc`, `/sys` and `switch_root`. It holds only BusyBox, `e2fsck`, `status` and their libraries.

### Progress codes

```
register 0x0700011C (clock chip, general-purpose register 7) = 0xB007XXYY

YY  stage                              XX
01  initramfs started                  00  stage reached
02  watchdog running                   03  checking the system partition; YY = seconds so far (to 255)
03  system partition found             EE  stage YY failed
04  system partition checked
05  system partition mounted
06  system image mounted
07  handing over
10  rcS started
11  data card mounted (or not present)
12  services starting
```

No `B007` prefix after a failed start means the initramfs never ran. Read it from another card with `memreg 0x0700011C`.

## Findings

- (2026-10-10, device) The command line's order is U-Boot's `bootargs`, U-Boot's additions, then the boot image's command line.
- (2026-10-10, stock) No secure boot: boot0 is an unsigned eGON image and TOC0 is an empty placeholder. The same `boot0_sdcard.fex` serves the SD card and the eMMC; the boot package sits at sector 32800 on both. Source: stock firmware v1.1.1.
- (2026-10-10, device) With TrimUI's system on the eMMC, a card with boot0 starts first; the kernel then sees only the card, because U-Boot leaves the eMMC's device-tree node disabled when booting from the card. Source: stock kernel and system run from SD.
- (2026-10-10, bsp) U-Boot runs its flasher instead of booting when the `work_mode` byte in its header (U-Boot + 0xE0) is non-zero (e.g. 0x11, PhoenixCard "card product", which rewrites the eMMC), or a `misc` partition says "sysrecovery". `toc1.py` refuses a package that isn't in normal mode. Source: Sonic Pad U-Boot source.
- (2026-10-10, device) U-Boot's device-tree fixups: memory 512 MiB → 1 GiB, DRAM parameters, a 3 MiB logo reservation so the logo carries into Linux, `bootargs`, and for an eMMC boot: enables the eMMC, strips HS200/HS400, caps it at 50 MHz and fills per-unit tuning values. The panel is chosen only by `lcd=` on the command line. Source: live device tree on stock.
- (2026-10-10, stock) The vendor device tree claims pins for hardware the Brick lacks: the IR transmitter claims PH3 (the rumble pin), the power chip's USB node names PH12–PH14 (F1, F2, MENU), a test node claims PL4 (Bluetooth wake), the board config enables JTAG on PH9–PH12; leftover nodes (PCIe, e-ink, AC200, a hall sensor, a second LCD) are enabled. Source: stock `sunxi.fex` DTB and `sys_config.fex`.
- (2026-10-10, device) The framebuffer console hangs our kernel inside the display driver's start (`fb_init`, while it attaches). Without it, the display take-over completes. Found by writing each init call's address to RTC register 7 on a debug kernel.
- (2026-10-10, device) The first boot loops of our kernel were the root filesystem never mounting (no power-chip rails registered) plus the 16 s watchdog: any hang before userspace is a silent reset.
- (2026-10-10, device) RTC general-purpose registers on stock: 0 (0x80000002) and 3 (0x0000b00f) are in use, 2 (FEL flag) and 6 (boot mode) are read by U-Boot; 7 is unused. Source: register dump on stock.
- (2026-10-10, bsp) The vendor clock driver never sets a PLL's enable bit; it relies on boot0 having enabled and locked them all, so any other first-stage loader must do the same. Source: PocketForge commit 2ea631f.
- (2026-10-10, bsp) The vendor crash-to-disk writer (`sunxi-mmc-panic.c`) is hard-wired to the eMMC controller, so it can't write crash logs to an SD card. Source: Sonic Pad kernel source.
- (2026-10-18, device) U-Boot's changes to the tree, besides those above: `/memreserve/` entries (initrd, logo), `/chosen`, the 32 `/dram` properties named `dram_para[NN]` (not valid source names: `dtc` needs `-f`), `boot_disp*`/`boot_fb0`; on an eMMC boot also per-unit eMMC tuning (`sdc_tm4_sm1_freq0 = 0xff16ffff`, `sdc_tm4_sm2_freq0 = 0xff0c13ff` on our device), the only values U-Boot sets that dt-tweaks.sh also sets differently. Source: the device's `/sys/firmware/fdt` against the boot package's DTB.
- (2026-10-18, device) The installed device's tree came from a boot package patched by an older dt-tweaks.sh: it lacked the GPU's critical trip, the LED supply's start-up delay, battery warning 2 at 1 % and the rumble's 3.5 V maximum. The kernel's edits applied to it: 6 set, 103 in place, 2 kept (the tuning above). Source: `tools/system/dt-check.sh`.
- (2026-10-18, bsp) Kernel 4.9 on arm64 reads the flat tree before unflattening only for memory, `/chosen` and reserved memory (`setup_machine_fdt`, `arm64_memblock_init`); nothing reads it after `unflatten_device_tree()` except `/sys/firmware/fdt`, which is created only if the tree's CRC still matches the one `early_init_dt_verify()` took. The full libfdt (including `fdt_rw.c`) is in `lib/`. 4.9's overlays (`of_overlay_create`) can't delete properties. Source: `arch/arm64/kernel/setup.c`, `drivers/of/fdt.c`, `drivers/of/overlay.c`.
- (2026-10-10, upstream) `sunxi-tools` FEL mode supports the A133. On the Smart Pro, FEL can be entered from TrimUI's settings or by shorting pads on the board. Source: sunxi-tools `soc_info.c`, linux-sunxi wiki.
