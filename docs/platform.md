# Platform

Status: Implemented · Updated: 2026-10-18

The TrimUI Brick's chip and board, which Linux kernel we run and why, what TrimUI's stock firmware does and what we take from it, and the other projects working on this chip. Everything else rests on these choices: the kernel decides which drivers exist, and the stock firmware supplies the bootloaders and the closed GPU libraries. The Brick Hammer edition is the same hardware in a metal case.

## Decisions

- **We run Allwinner's 4.9 vendor kernel, not mainline Linux** (2026-10-11). Mainline lacks this chip's display engine, its audio codec, an XR829 WiFi driver and deep sleep, and TrimUI's closed GPU libraries need the vendor display code (`dc_sunxi`, see [gpu.md](gpu.md)). Userspace sticks to standard kernel interfaces (input devices, ALSA, fbdev, power supplies, extcon), so a later move stays cheap; facts a mainline port will need are kept in these docs' Findings. Rejected: mainline (gaps listed under Findings); for V0, Allwinner's 5.15 BSP (2026-10-18: it has this chip's codec, display and XR829 drivers but no GPU kernel driver and none of our panels; it is evaluated once the Allwinner code is split out, in V1).
- **Questions that only matter for a mainline kernel or a replacement U-Boot are parked** (2026-10-18) until that work starts. They are kept here:
  - How U-Boot tells the five panel controllers apart (its `check_lcd_module`), and whether the JD9168 fallback for `nv3052` hides a sixth panel ([display.md](display.md)).
  - Whether the live TCON/DSI register values are U-Boot's or the kernel's; the DSI ECC_FIFO bit is 0 though the BSP code sets bit 3 ([display.md](display.md)).
  - Which clock the D-PHY timing counts use: at the D-PHY PLL ÷ 3 (102 MHz) every value meets the MIPI spec, at the 150 MHz module clock two are too short ([display.md](display.md)).
  - Whether the TRIGGER_START, start_delay and FIFO-flush differences explain the Smart Pro mainline RFC's black screen ([display.md](display.md)).
  - What the `allwinner,gpu-pd` power-domain sequence does ([gpu.md](gpu.md)).
  - Whether PocketForge's open-driver route (mainline `powervr.ko` + Mesa) works on screen ([gpu.md](gpu.md)).
- **The kernel is rebuilt from source: Creality's Sonic Pad release of Allwinner's 4.9.191 BSP** (2026-10-10). TrimUI has never published its kernel, U-Boot or boot0 source; the Sonic Pad (Allwinner R818/T800, same sun50iw10 die) source is the same BSP version TrimUI built from. Our tree starts at PocketForge's import of it plus six of their fixes (XR829 MAC address from the chip ID, AXP2202 LDO ranges, a USB NULL check, an `hci_ll` build fix, a `dtc` build fix, WiFi regulator errors). TrimUI's own drivers (panel, LEDs, rumble, codec changes) are re-done by us. Rejected: TrimUI's kernel binary, as Knulli ships it (without source nothing in it can be fixed, and our display, USB, sound and LED changes all need source).
- **The kernel configuration starts from TrimUI's own** (`/proc/config.gz` of stock v1.1.1) (2026-10-10), minus what this tree can't build (`BT_HCIUART_LL`, `BT_HCIUART_3WIRE`) or the Brick lacks (`SUNXI_NAND`). Deep sleep through Allwinner's firmware works with it unchanged ([power.md](power.md)).
- **The kernel is built with the Sonic Pad SDK's cross compiler (GCC 6.4)**, made for the same chip family and vendor kernel (2026-10-10). Userspace uses Buildroot's own toolchain ([system-image.md](system-image.md)).
- **From TrimUI's firmware we take only what has no open replacement** (2026-10-14): the first-stage loader, U-Boot and the rest of the boot package ([boot.md](boot.md)), the GPU libraries and firmware ([gpu.md](gpu.md)), and the XR829's firmware ([wireless.md](wireless.md)).
- **DRAM at 744 MHz, up from TrimUI's 672** (2026-10-20). The clock is a parameter of the first-stage loader, which derives its timings from it and trains the memory at start; `tools/sdboot/boot0-dram.py` sets it when a card image is built (`DRAM_CLK` overrides; 672 is stock), and an install copies the card's loader to the internal storage. Measured with the GameCube race: about 5 % more frames per second at 744, the same at 756; 768 and 792 don't start (the loader hangs in memory training, with the screen dark; the device starts from the internal storage with the card out). Memory tests at 756 ran clean for half an hour, so 744 keeps a step of margin below the edge. Rejected: 756 (no measurable gain for the margin given up); changing the clock from Linux (the vendor DRAM-frequency driver has no A133 support, and the controller's timings are the loader's).

## Design

### The hardware

| Part | What it is | Doc |
|---|---|---|
| SoC | Allwinner A133P (sun50iw10p1), 4× Cortex-A53, 408–2000 MHz | [power.md](power.md) |
| RAM | 1 GiB LPDDR3, 744 MHz on our cards (672 stock) | |
| GPU | PowerVR GE8300 (BVNC 22.102.54.38) | [gpu.md](gpu.md) |
| Power | AXP2202 power chip (= X-Powers AXP717), TCS4838 CPU regulator | [power.md](power.md) |
| Display | 1024×768 MIPI DSI panel, one of five controller chips | [display.md](display.md) |
| WiFi, Bluetooth | XR829 (SDIO + UART), 2.4 GHz only | [wireless.md](wireless.md) |
| Storage | 8 GB eMMC, microSD slot | [storage.md](storage.md) |
| USB | Two USB-C ports: bottom (charging, device or host), top (host only) | [usb.md](usb.md) |
| Co-processor | OpenRISC core running Allwinner's `arisc` firmware (power-off, deep sleep) | [power.md](power.md) |

### Our kernel tree

```
CrealityTech/sonic_pad_os lichee/linux-4.9 (4.9.191)
└─ PocketForge kernel-tsp import + 6 fixes (2026-06)
   └─ ours (2026-10-10 on): Brick defconfig, AXP2202 rails/power key/battery/USB drivers,
      CPU speed bin, panel driver, FBIO_WAITFORVSYNC, LED chain, rumble, codec,
      SD 1.8 V supply switch, USB roles from cable detection, regulator modes
```

The GPU kernel driver is built outside the tree from PocketForge's `gpu-km-tsp` (DDK 1.19, [gpu.md](gpu.md)).

### TrimUI's stock firmware

Tina Linux 1.1.1 (OpenWrt-based, `procd`), kernel 4.9.191. Releases: 1.0.5 (2024-11-05), 1.0.6 (2024-12-15), 1.1.0 (2025-06-10), 1.1.1 (2025-11-26); we use 1.1.1 (`trimui_tg3040.awimg`). How it works, in short:

- Start-up: OpenWrt `rc.d` scripts (module loading, mounts, `adbd`, `hciattach`, `wpa_supplicant`, `MtpDaemon`), then `runtrimui.sh`, which sets GPIOs (5 V rail, rumble off, FN switch), runs user hooks from the card and loops between the launcher (`MainUI`) and the chosen game.
- Hardware is mostly driven from userspace: `trimui_inputd` polls the buttons through `/dev/mem` and makes a virtual gamepad; `keymon` handles hotkeys, dimming, sleep and low battery; `hardwareservice` takes commands as files under `/tmp/system`. Shared state sits in a SysV shared-memory block; settings in `/mnt/UDISK/system.json`.
- TrimUI's kernel additions are sysfs classes (`led_anim`, `motor`, `speaker`, `usbc0/axp_5v`), the multi-panel driver selected by `lcd=`, and an anti-clone chip driver.

## Findings

- (2026-10-10, stock) The anti-clone chip ("ALPU"/ARELINK, NEOWINE) sits on bit-banged I2C at PE1/PE2, address 0x1C. The kernel reads its serial (shown as `hwserial` in `/proc/cpuinfo`) but enforces nothing; only TrimUI's `MainUI` checks it, through `/dev/mem`, and exits without a genuine chip. A system that doesn't run `MainUI` needs no driver for it. Source: stock kernel and `MainUI` disassembly.
- (2026-10-10, stock) TrimUI builds the Brick's kernel from the same source as the Smart Pro's (TG5040): the image contains TG5040 strings and references to the Smart Pro's IO board. Source: stock kernel image.
- (2026-10-10, upstream) The Smart Pro's stock device tree also names the `otm1289a` panel driver, so TrimUI's multi-panel driver likely serves both. Source: PocketForge's public documentation.
- (2026-10-10, stock) Stock kernel config enables 148 options that don't exist in mainline 4.9 (Allwinner drivers for clocks, pins, display, PMIC, MMC, USB, WiFi, audio). Source: stock kernel config.
- (2026-10-10, upstream) Mainline (v7.3-rc6) for A100/A133: merged are clocks, pins, I2C, MMC, USB, DMA, watchdog, thermal, CPU frequency (OPP table only to 1.464 GHz, none of the A133P's 1.6–2.0 GHz steps), LED controller, MIPI DSI and D-PHY; the AXP717 has regulators, battery, USB power, ADC and power key. Missing: display engine and TCON (two unmerged attempts; leow149's Smart Pro RFC v8 of 2026-09-12 shows a black screen), GPU (GE8300 "unsupported" in Mesa, `exp_hw_support=1` in the kernel), the audio codec, PWM, IOMMU, an XR829 driver. Source: torvalds/linux, patchwork series 921100 and 1164009.
- (2026-10-10, upstream) Mainline U-Boot (v2025.10+) can initialise A133 DRAM but has timings only for DDR4 and LPDDR4, not the Brick's LPDDR3. TF-A has an A133 port on master only (2026-06-11), with no SCP firmware support; crust has no A133 support, so a mainline system could only use s2idle sleep. Source: u-boot `dram_sun50i_a133.c`, TF-A `plat/allwinner/sun50i_a133`, crust.
- (2026-10-10, upstream) AXP2202 is Allwinner's name for the AXP717. Source: Andre Przywara's AXP717 series cover letter; register layout matches mainline `axp20x.h`.
- (2026-10-10, bsp) Allwinner's newer out-of-tree `bsp/` (Linux 5.10/5.15) supports sun50iw10: display (`disp2`, none of the Brick's panels), the audio codec, `xr829`, AXP2202 and LEDs, but no GPU kernel driver; it has no sun50iw10 config for 6.x. Copies: radxa/allwinner-bsp, AvaotaSBC/linux `linux-5.15`, chainsx/kernel-sun50iw10. Source: those repositories.
- (2026-10-10, upstream) Related projects. Source: their repositories.

  | Project | Device(s) | Kernel | Use to us |
  |---|---|---|---|
  | PocketForge (Matthew Burke) | Smart Pro | 4.9 BSP (public, archived); 6.x/7.x (private) | Our kernel base and GPU driver source; reports open GPU rendering and an A133 display stack on newer kernels, unverified |
  | leow149 mainline port | Smart Pro | Mainline U-Boot, TF-A, Linux ~7.2 | Fully mainline boot chain works; display doesn't |
  | Knulli | Brick, Smart Pro, other A133P | TrimUI's binary | GPU libraries of DDK 1.11 (`knulli-cfw/ge8300-drivers`) |
  | NextUI, MinUI | Brick + Smart Pro (`tg5040`) | Stock | Stock sysfs interfaces; power-off fix for a battery-draining stock shutdown |
  | muOS, spruceOS, CrossMix-OS | A133P devices | Stock | – |
  | ROCKNIX | No A133 | Mainline | Its H700 port: mainline Allwinner handheld with AXP717 |
  | DongshanPI | A133/R818 boards | Mainline 6.13 Buildroot; Tina5 SDK overlay | A second mainline A133 + AXP717 bring-up |
  | StarFive JH7110 kernels | – | 5.15, 6.6, 6.12 | PowerVR DDK 1.19 kernel source with GE8300 definitions ([gpu.md](gpu.md)) |

- (2026-10-10, upstream) No Brick mainline attempt, device tree or postmarketOS port was found. Source: mainline, patchwork, GitHub search.
