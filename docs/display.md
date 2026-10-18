# Display

Status: In progress · Updated: 2026-10-18

The TrimUI Brick's 3.2" 1024×768 IPS panel, connected over 4-lane MIPI DSI and driven by Allwinner's vendor display driver (`disp2`) on our 4.9 kernel: the panel and its five possible controller chips, the display engine behind it, and how userspace gets frame timing (vsync). Frame timing decides input latency, and the display's per-frame interrupt keeps the CPUs out of their deepest idle state, so this matters both for how games feel and for battery life. The GPU that draws into the display is in [gpu.md](gpu.md); the choice of the vendor kernel is in [platform.md](platform.md).

## Decisions

- **One panel driver for all five controllers, picked by U-Boot's `lcd=`** (2026-10-10). Units ship with one of five panel controllers; TrimUI's U-Boot probes which one is fitted and passes `lcd=<model>` on the kernel command line. Our `trimui_brick.c` holds all five start-up tables (copied from TrimUI's kernel by disassembly) and registers as `otm1289a`, the `lcd_driver_name` TrimUI's device tree uses for every variant (U-Boot reads that tree too). Unknown names get JD9168 and a missing `lcd=` gets OTM1289A, as stock. Rejected: running on U-Boot's initialisation alone (shows a picture, but the panel can never be powered down and back up); one driver per controller (only a mainline DRM port needs that split).
- **GC9702C's two 120 ms waits are real delays** (2026-10-10). TrimUI's table has the delay marker in the command field, so stock sends two junk 120-byte DCS writes instead of waiting. Rejected: copying the bug. Untested: our unit has a JD9168.
- **Panel off is a full power-down** (2026-10-10; 3.3 V rail since 2026-10-13). `DISP_DEVICE_SWITCH` to "none" runs the panel's close flow, including display-off, sleep-in and cutting CLDO4 (3.3 V, feeds only the panel); on resume or "on" the full power-up and start-up table run again. CLDO1 (1.8 V) stays always-on because it also feeds the eMMC's I/O and the codec's charge pump. Rejected: stock's "screen off", which is backlight 0 with the panel still powered.
- **Vsync through the standard `FBIO_WAITFORVSYNC` on `/dev/fb0`** (2026-10-12), served without the framebuffer lock (2026-10-13). Specular paces its frames by it. Rejected: a Brick-specific `/dev/disp` ioctl (not portable); inferring vsync from when a blocking buffer swap returns (Specular's fallback on other devices; a frame later).
- **No framebuffer console** (2026-10-10). With `CONFIG_FRAMEBUFFER_CONSOLE` the kernel hangs while the console attaches during display start-up. Boot errors are shown by our own start-up instead (see [boot.md](boot.md)).

## Design

**Start-up.** TrimUI's boot0 and U-Boot power up the panel, send its start-up table, show the logo and reserve its memory (`disp_reserve`, `boot_disp*` in the device tree). The kernel's `disp2` driver takes over that running setup without restarting it, so the logo stays up. The panel driver is first used on the next panel off/on or sleep.

**Picture path.**

```
/dev/fb0  1024×768 ARGB8888, 4096 B stride; 64 MiB virtual (1024×16384) so the GPU can flip by panning
  → display engine (DE, 0x06000000) mixer 0, video channel 1 (UI channels 2/3: stock's overlay layers)
  → TCON-LCD0 (0x06511000), CPU/"8080" trigger mode with output to DSI
  → DSI (0x06504000), video mode, RGB888, 4 lanes → D-PHY (0x06505000), 306 Mbit/s per lane
  → panel (PD0–PD9); reset PD22; backlight PWM0 on PD23 (50 kHz) + enable PH18
```

The frame interrupt (vblank) comes from the DSI controller, not the TCON. Each flip waits in the driver's pan for the next vblank.

**Timings** (device tree `lcd0`; Allwinner's `hbp` includes the sync width):

| | Active | Sync start | Sync end | Total |
|---|---|---|---|---|
| Horizontal | 1024 | 1060 | 1064 | 1080 |
| Vertical | 768 | 775 | 779 | 784 |

Pixel clock 51 MHz → 51 000 000 / (1080 × 784) ≈ 60.2 Hz.

**Panel power-up** (from TrimUI's driver; each step then waits): CLDO1 1.8 V on (10 ms) → CLDO4 3.3 V on (10 ms) → DSI pins (50 ms) → reset high 20 ms, low 120 ms, high 20 ms → DSI high-speed clock and start-up table (60 ms) → TCON on (50 ms) → backlight. Power-down: backlight off, TCON off, display-off (25 ms) and sleep-in (150 ms), pins off, reset low, CLDO4 off, CLDO1 off (its always-on flag keeps it up).

**Panel controllers.** Start-up table entries are `{u8 cmd; u32 len; u8 data[64]}`; `len` 0xFE = wait `data[0]` ms, 0xFF = end; each entry is one DCS write.

| `lcd=` | Entries | Notes | Mainline DRM driver | Run on hardware |
|---|---|---|---|---|
| `gc9702c` | 69 | Stock's two delays are junk writes (above) | none | no |
| `otm1289a` | 72 | Orise style: command 0x00 sets the register offset for the next write; ends sleep-out, 50 ms, display-on, 120 ms. Default without `lcd=` | none (leow149 RFC; PocketForge, private) | no |
| `er68576` | 29 | | none | no |
| `st7703` | 25 | | `panel-sitronix-st7703` (table-driven; needs a Brick entry) | no |
| `jd9168` | 31 | Also used for any unknown name, including U-Boot's `nv3052` and `default` | none (`jd9365da` is a different chip) | yes (our unit) |

**Userspace interface** (there is no `/sys/class/backlight` in this kernel):

```c
/* /dev/disp ioctls, from include/video/sunxi_display2.h. The argument is always
 * unsigned long[4] = { screen (0), value, 0, 0 }. */
#define DISP_DEVICE_SWITCH      0x0f   /* value: 0 = off (panel powered down), 1 = LCD on */
#define DISP_LCD_SET_BRIGHTNESS 0x102  /* value: 0–255; the driver caps it at lcd_pwm_max_limit = 200 */

/* /dev/fb0: blocks until the display takes its next frame. */
ioctl(fb, FBIO_WAITFORVSYNC, &(__u32){0});
```

`dispctl` wraps the `/dev/disp` calls. U-Boot hands over at backlight 4 (nearly black); Specular sets its own level (10 steps on a logarithmic curve, 16–255).

## Findings

- (2026-10-10, device) Registers confirm the mode above (≈60.2 Hz). This unit gets `lcd=jd9168`, and the DSI command buffer still holds the tail of the JD9168 table and display-on, so U-Boot really sent it.
- (2026-10-10, stock) How U-Boot identifies the controller ("check_lcd_module") is not decoded.
- (2026-10-10, device) The TCON runs in CPU ("8080") trigger mode with CPU-mode output = DSI while the DSI link runs video mode (non-burst, sync pulses). Stock never sets TRIGGER_START or flushes the FIFO; the "trigger finish" flag fires each frame anyway. TE off, all TCON interrupts off, TCON normal-mode timing registers 0. TRI0 block size 1023, gap 556; TRI1 767 lines; TRI2 start 10, start_delay 5558; safe period 765, mode 3.
- (2026-10-10, device) Clocks: TCON from PLL_VIDEO0×4 = 300 MHz (BSP asked for 306; the PLL steps by 12 MHz), divided by 4 → 75 MHz; DSI module clock 150 MHz (periph0/4); DE 300 MHz. The DSI lane rate comes from the D-PHY's own PLL: +0x104 = 0x00f76682 → 24 MHz × 102 / 8 = 306 Mbit/s = 51 MHz × 24 bit / 4 lanes.
- (2026-10-10, device) DSI: RGB888 (format 8, packet 0x3E, 3072 B/line), ECC and CRC on, EoTp off, video start delay 778, VSA 4 / VBP 5 / VACT 768 / VT 784; blanking packets HSA 2, HBP 42, HFP 92, HBLK 3218, VBLK 4 bytes; line = 3240 B = 1080 × 3. DSI +0x000 = 0x01010001 (bits 16 and 24 unknown).
- (2026-10-10, device) D-PHY: continuous high-speed clock. lpx 14, hs_prepare 6, hs_trail 10, clk_prepare 7, clk_zero 50, clk_pre 3, clk_post 10, clk_trail 30, hs_stop_dly 20. Analog: ANA0 0x44, ANA1 0x80000020, ANA2 0x0f000012, ANA3 0xff040000, ANA4 0x844635ee, COMBO0 0xb. Chip revision (0x03000024 & 7) = 6, so the BSP sets ANA1 bit 5.
- (2026-10-10, device) DE mixer 0 has the DE2-style layout (global 0x0, blender 0x1000, video channels 0x2000/0x3000, UI channels 0x4000/0x5000). The framebuffer is read through IOMMU addresses (0xfc000000+). Blender pipes 0–2 = channels 1–3, black background.
- (2026-10-10, stock) Display block clocks: de0, display_top, dpss_top0, tcon_lcd0, mipi_host; IRQs SPI 68/69/70. On a running device the display_top gate (CCU 0xB5C) is 0 and dpss_top0 (0xABC) gates 0x06510000. CCU bus gates: DE 0x60C, DSI 0xB4C, TCON-LCD 0xB7C.
- (2026-10-10, device) Backlight PWM uses Allwinner's newer PWM block (channel control 0x100, period 0x104, gate 0x40, enable 0x80): 24 MHz, period 480 → 50 kHz; duty 202/480 at stock UI level 107/255.
- (2026-10-10, stock) TrimUI's kernel forces fb0 to 64 MiB. Stock userspace also uses extra DE hardware layers for its overlay menu (`/dev/disp` 0x47/0x48), the G2D blitter (0x06480000, `/dev/g2d`) for copies and rotation, and DE colour controls (`/sys/devices/virtual/disp/disp/attr/enhance_*`, `color_temperature`). We use none of these.
- (2026-10-10, stock) Stock never powers the panel down while running; panel power-down only happens around suspend. The BSP's fb "blank" only hides the layer.
- (2026-10-10, stock) TrimUI's panel driver builds a gamma table from 17 points, while the device tree has gamma disabled; ours builds none.
- (2026-10-10, stock) The device tree's panel size (135 × 216 mm) is wrong; the panel is about 65 × 49 mm.
- (2026-10-10, device) Panel off/on with our driver re-runs the JD9168 power-up and the picture returns, also with the GPU rendering throughout. Source: linux 40042cf29.
- (2026-10-12, device) The display raises its vblank interrupt 60 times a second whenever it is on, even with nothing drawing. With the display on, the CPUs never enter cluster sleep; with it off they spend 36–75 % of the time there.
- (2026-10-12, device) Specular's measurements (details in Specular's docs): draw-then-swap puts a frame on screen 32 ms (two vsyncs) after it starts; starting each frame at the vsync takes 16 ms; adding a 10 ms frame delay takes 6 ms at 60 fps (13 ms misses vsyncs). `FBIO_WAITFORVSYNC` returns when the display takes a new frame; buffer switches follow by a median 0.1 ms. An emulator on its own clock (60.0988 Hz) drifts against the panel's 60.2 Hz. Source: Specular ROADMAP, "Brick spike".
- (2026-10-13, device) Before the lock change, `FBIO_WAITFORVSYNC` waited for the framebuffer lock, which a GPU flip holds while it waits for the same vsync; a vsync-paced thread beside a presenting UI ran at about 40 fps. Source: linux 4d81ab5d7.
- (2026-10-18, bsp) In the vblank interrupt the BSP writes the new layer settings, then checks the scan line against the TCON's start delay; past it, the update is flagged as an error (`err_cnt`). So a late-handled interrupt (e.g. held up on CPU0) can make a flip miss its frame; what a flagged update costs is unverified. Source: linux `disp_manager.c`, `disp_lcd_is_in_safe_period()`.
- (2026-10-10, upstream) Mainline gaps, from the live registers: the `sun50i-a100` D-PHY matches every value except ANA1 bit 5; `sun6i_mipi_dsi` matches except HSA length (mainline minimum 10 vs 2, +8 B/line) and VBLK (0 vs 4); `sun4i_tcon` CPU mode matches the layout but computes start_delay 1972 vs 5558 and safe period 3000 vs 765, and sets FIFO flush and IO_TRI 0xe0000000 where stock doesn't; there is no A100/A133 TCON variant. The block at 0x06510000 matches `sun8i_tcon_top` (port select 0x1C, DSI gate bit 16 of 0x20). No mainline driver for the newer PWM block. Mainline would also need the IOMMU in pass-through or a DE IOMMU binding. Source: mainline's `sun50i-a100` D-PHY, `sun6i_mipi_dsi` and `sun4i_tcon`.
- (2026-10, upstream) Mainline has the A100 DSI and D-PHY (since 6.2) but no A100/A133 mixer or TCON. Parthiban's LVDS series stalled (2024-12); leow149's RFC v8 for the TrimUI Smart Pro (2026-09) gives a black screen with TRIGGER_START never clearing. PocketForge reports private 6.x/7.x kernels with an A133 DE/TCON/DSI stack and an OTM1289A driver, scanout unverified; the Smart Pro's tree also names `otm1289a`, so TrimUI's multi-panel driver likely serves both devices.
- (2026-10-10, bsp) Allwinner's 5.15 BSP (github.com/radxa/allwinner-bsp) supports sun50iw10 in `disp2` (`lowlevel_v2x`, DSI "IP version 40") and is a better register reference than the 4.9 code.
