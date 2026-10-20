# Display

Status: In progress · Updated: 2026-10-18

The TrimUI Brick's 3.2" 1024×768 IPS panel, connected over 4-lane MIPI DSI and driven by Allwinner's vendor display driver (`disp2`) on our 4.9 kernel: the panel and its five possible controller chips, the display engine behind it, and how userspace gets frame timing (vsync) and, planned, sets the refresh rate. Frame timing decides input latency, and the display's per-frame interrupt keeps the CPUs out of their deepest idle state, so this matters both for how games feel and for battery life. The GPU that draws into the display is in [gpu.md](gpu.md); the choice of the vendor kernel is in [platform.md](platform.md).

## Decisions

- **One panel driver for all five controllers, picked by U-Boot's `lcd=`** (2026-10-10). Units ship with one of five panel controllers; TrimUI's U-Boot probes which one is fitted and passes `lcd=<model>` on the kernel command line. Our `trimui_brick.c` holds all five start-up tables (copied from TrimUI's kernel by disassembly) and registers as `otm1289a`, the `lcd_driver_name` TrimUI's device tree uses for every variant (U-Boot reads that tree too). Unknown names get JD9168 and a missing `lcd=` gets OTM1289A, as stock. Rejected: running on U-Boot's initialisation alone (shows a picture, but the panel can never be powered down and back up); one driver per controller (only a mainline DRM port needs that split).
- **GC9702C's two 120 ms waits are real delays** (2026-10-10). TrimUI's table has the delay marker in the command field, so stock sends two junk 120-byte DCS writes instead of waiting. Rejected: copying the bug. Untested: our unit has a JD9168.
- **Panel off is a full power-down** (2026-10-10; 3.3 V rail since 2026-10-13). `DISP_DEVICE_SWITCH` to "none" runs the panel's close flow, including display-off, sleep-in and cutting CLDO4 (3.3 V, feeds only the panel); on resume or "on" the full power-up and start-up table run again. CLDO1 (1.8 V) stays always-on because it also feeds the eMMC's I/O and the codec's charge pump. Rejected: stock's "screen off", which is backlight 0 with the panel still powered.
- **Vsync through the standard `FBIO_WAITFORVSYNC` on `/dev/fb0`** (2026-10-12), served without the framebuffer lock (2026-10-13). Specular paces its frames by it. Rejected: a Brick-specific `/dev/disp` ioctl (not portable); inferring vsync from when a blocking buffer swap returns (Specular's fallback on other devices; a frame later).
- **No framebuffer console** (2026-10-10). With `CONFIG_FRAMEBUFFER_CONSOLE` the kernel hangs while the console attaches during display start-up. Boot errors are shown by our own start-up instead (see [boot.md](boot.md)).
- **Mask the vblank interrupt while nothing is drawn** (2026-10-18; experiments first, then build). With the screen on, that interrupt keeps the CPUs out of cluster sleep. Any display change or vsync waiter unmasks it; after 3 idle on-time frames the handler masks it; while it is unmasked a CPU wake-up limit (PM QoS) of 110 µs is held; a module parameter turns gating off, and it is on by default once the experiments pass. Rejected: a limit of 104 µs or less, such as cluster sleep's 74 µs exit latency (the idle governor compares entry + exit, so this also blocks cpu-sleep on all four CPUs through every game, where CPUs 1–3 spend 42–73 % of their time); no limit (relies on the 3-frame wait alone and accepts rare one-frame slips).
- **Refresh rate set by `DISP_LCD_SET_FPS`/`GET_FPS` on `/dev/disp`, in millihertz, 40–60.2 Hz, by changing only the vertical total** (2026-10-18; experiments first, then build). The rate is kept through panel off/on and sleep; only `SET_FPS 0` or a reboot restores 60.2 Hz, and Specular decides when to change it. Rejected: `FBIOPUT_VSCREENINFO` with a new `lower_margin` (the driver treats it as a full mode set, and callers would work in porches); a sysfs attribute (a second interface to keep); changing the pixel clock (the lane rate is exactly 51 MHz × 24 / 4, so the D-PHY's PLL would re-lock and the link restart); also changing the horizontal total (six DSI blanking packets with ECC/CRC to rewrite, to get errors under 100 ppm rather than under 0.05 %); resetting the rate at every panel power-up.
- **TCON start delay untouched when the vertical total grows, if the picture stays clean; otherwise the DSI video start delay moves instead** (2026-10-18). Rejected: the BSP formula clamped to its 16-bit field (unknown whether a clamped value works; the register-write window grows by up to 82 lines and `judge_line` must be recomputed); a lower DE clock (global, and costs layer and scaler bandwidth).
- **Colour: nothing to change** (2026-10-18). At stock's default settings its TCON gamma is off and its DE colour matrix is the built-in default, as ours (Findings). Rejected: a stock register dump (it would only confirm this). Anything that later turns on TCON gamma must write the table first.
- **No spare display or video hardware for now; everything goes through the GPU** (2026-10-18). Rejected: showing a core's frame directly on a DE layer (the paced GPU path already reaches the screen about 6 ms after a frame starts; it loses shaders, sharp or integer filtering and rotation, and adds a second presentation path to Specular; revisit only if a power test, a 60 fps blit against an idle GPU at the same CPU load, shows the GPU path costs a lot); the G2D blitter (duplicates the GPU; at most for screenshots or format conversion); the Cedar video decoder (no use in emulation).
- **Three framebuffers, so GPU swapchains get three images** (2026-10-20). The GPU's display-class driver (`dc_sunxi`) flips by panning `/dev/fb0` and hands the replaced buffer back as soon as the pan returns; the sunxi pan waits for the next vsync tick, which can come a refresh before the display engine latches the new address, so with two buffers a program's next frame lands on the buffer still on the panel: tearing, seen in the GameCube recompiler and dark bands when it cleared the whole image. `fb0_buffer_num = 3` in the device-tree edits allocates the third buffer (3 MiB more) and `tools/gpu-patches/0005` raises the driver's preferred count to match; a program that asks for two images keeps the old behaviour. Costs one frame of display latency for every GPU program, Specular included. Rejected: making the pan wait for the refresh at which the address is latched (keeps two buffers and today's latency, but a program's acquire then blocks until the previous frame is on the panel, up to a refresh per frame, on the thread that renders); a vsync wait in each program before it draws into a swapchain image (the same stall, fixed per program).

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

### Planned: vblank gating and refresh rate

Not built yet: waits on the experiments in Open questions. Paths are under `linux/drivers/video/fbdev/sunxi/disp2/disp/`.

**Vblank gating.** A new `de/disp_vblank_gate.c` owns the DSI vblank enable bit, so the rest of the driver only reports "I need the next vblank":

- *Want* (any context): if masked, clear only the stale vblank flag, set the enable bit and queue the QoS work; always reset the idle count.
- *Idle frame*: an on-time vblank (registers written) with no *want* since the last one, no `FBIO_WAITFORVSYNC` waiter, `vsync_event_en == 0` and no rate change pending. Late vblanks don't count: their registers aren't written yet.
- *Mask*: after `idle_frames` (3) idle frames in a row, in the handler.
- *Lock*: one spinlock, taken with irqsave by every writer of DSI +0x04 (the handler, *want*, mask, panel enable/disable). This also closes today's unlocked read-modify-writes (Findings).
- *QoS*: one `PM_QOS_CPU_DMA_LATENCY` request, set by a work item (the update calls a blocking notifier, so not from the handler) to `qos_us` while the panel is on and the interrupt unmasked, and to the default otherwise. 110 µs blocks cluster sleep (121 µs entry + exit) but not cpu-sleep (105 µs). Until the work runs, the first vblank after an unmask can find CPU0 asleep: at most one late frame.
- *Reset*: `disp_lcd_enable`, `disp_lcd_sw_enable` (boot takeover) and resume (through enable) start the gate unmasked with the limit held; `disp_lcd_disable` (panel off, suspend) stops it, releasing the limit, and *want* does nothing until the next start.
- While masked, these also stop: the enhance histogram and auto-contrast tasklets (channel 0 only, unused), smart backlight (off), capture (unused), ESD checks (not configured); the `attr/sys` fps reads low.

```c
/* de/disp_vblank_gate.h */
enum disp_vblank_reason {   /* why the next vblank is wanted; indexes the counters */
	VBLANK_APPLY,     /* disp_mgr_apply: layer/mixer change, including pan */
	VBLANK_ENHANCE,   /* disp_enhance_apply, disp_smbl_apply */
	VBLANK_GAMMA,     /* after each `panel_extend_dirty = 1` in disp_lcd.c */
	VBLANK_WAIT,      /* fb_wait_for_vsync, before it reads wait_count */
	VBLANK_REFRESH,   /* a refresh-rate change is pending */
	VBLANK_REASONS,
};
void disp_vblank_gate_start(struct disp_device *lcd);  /* from the panel enable paths */
void disp_vblank_gate_stop(struct disp_device *lcd);   /* from disp_lcd_disable */
void disp_vblank_want(u32 disp, enum disp_vblank_reason why);
/* Handler side: tests and clears the vblank flag under the lock (instead of the bare
 * disp_al_lcd_query_irq), and records cur_line in the histogram. */
bool disp_vblank_claim(struct disp_device *lcd, int cur_line);
/* Handler side, at its end: counts idle frames, masks after idle_frames of them. "No waiter"
 * comes from dev_fb.c through a has_waiters(disp) callback in disp_bsp_init_para, like
 * disp_int_process. */
void disp_vblank_frame_done(struct disp_device *lcd, bool on_time);

/* Kill switch: /sys/module/<disp's module name>/parameters/vblank_gate, or disp.vblank_gate=0
 * on the command line (check the name on the device). Off = never mask; counters still count. */
static bool vblank_gate = true;

/* de/lowlevel_v2x/de_dsi.c, called with the gate lock held. The flags are write-1-to-clear:
 * clear only the vblank flag, so an unmask doesn't fire at once for a stale vblank. */
void dsi_vblank_irq_set(u32 sel, bool enable)
{
	u32 en = dsi_dev[sel]->dsi_gint0.bits.dsi_irq_en;

	en = enable ? en | BIT(DSI_IRQ_VIDEO_VBLK) : en & ~BIT(DSI_IRQ_VIDEO_VBLK);
	dsi_dev[sel]->dsi_gint0.dwval = en | BIT(16 + DSI_IRQ_VIDEO_VBLK);
}

/* de/disp_lcd.c disp_lcd_event_proc */
	int cur_line = disp_al_lcd_get_cur_line(...);          /* moved before the flag test */
	if (disp_vblank_claim(lcd, cur_line)) {
		on_time = cur_line <= start_delay - lcdp->judge_line;
		sync_event_proc(mgr->disp, !on_time);
		disp_lcd_apply_pending_vt(lcd, on_time);         /* refresh rate, below */
	}
	disp_vblank_frame_done(lcd, on_time);
```

Diagnostics, in debugfs `disp_vblank/` (always built in; this kernel has no ftrace): `stats` (masks, unmasks per reason, time and share masked, idle runs, late and err counts since start, QoS held, switch values); `cur_line` (histogram of the line at handler entry, 0–15 and 16+, separately for the first interrupt after an unmask); `events` (the last 128 `{ktime_ns, want/mask/unmask/late/qos, reason, cur_line}`, enough to replay a missed-frame report); `force` (`masked`/`unmasked`/`auto`; `masked` ignores *want*, so waits time out after 50 ms: experiments only); tunables `idle_frames` and `qos_us`.

**Refresh rate.** Only the vertical total (VT) changes, through the front porch; pixel clock (51 MHz) and horizontal total (1080) stay.

```c
/* include/video/sunxi_display2.h already has the numbers (0x107, 0x108); dev_disp.c gets handlers.
 * DISP_LCD_SET_FPS: { screen, millihertz (0 = panel default), 0, 0 }. Picks the nearest VT in
 *     [784, vt_max], returns the millihertz achieved (> 0) or -errno. Takes effect at the next
 *     on-time vblank; returns at once. vt_max from the experiments; proposed 1181 (40 Hz).
 * DISP_LCD_GET_FPS: { screen, 0, 0, 0 }; returns the current millihertz.
 * `dispctl fps <mHz>` wraps both. */

/* de/disp_lcd.c. set_fps computes vt = round(51e6 / (1080 * mHz / 1000)), stores it in
 * lcdp->pending_vt under lcd_data_lock and calls disp_vblank_want(VBLANK_REFRESH). */
static void disp_lcd_apply_pending_vt(struct disp_device *lcd, bool on_time)
{
	/* Handler, right after the commit: the scan is in the old frame's front porch, short of
	 * line 784, so any VT >= 784 is still ahead and raising or lowering it here is safe.
	 * Only if on_time && pending_vt. */
	disp_al_lcd_set_vt(lcd->hwdev_index, &lcdp->panel_info, vt);
	lcdp->panel_info.lcd_vt = vt;     /* source of truth: power-up programs from it, so the rate lasts */
	disp_lcd_cal_fps(lcd);            /* frame_per_sec */
	lcd->timings.ver_total_time = vt;
	lcd->timings.ver_front_porch = vt - lcdp->panel_info.lcd_vbp - lcdp->panel_info.lcd_y;
	lcd->timings.frame_period = ...;  /* as cal_real_frame_period */
	lcdp->pending_vt = 0;
	schedule_work(&lcdp->fb_var_work);  /* dev_fb: var.lower_margin under lock_fb_info */
}

/* de/lowlevel_v2x/disp_al.c: DSI +0x1C bits 28:16 (dsi_basic_size1.bits.vt); TCON TRI2 left
 * as is (or, if that fails, the DSI video start delay set to vt - 6); al_priv.output_fps and
 * de_update_device_fps(). */
int disp_al_lcd_set_vt(u32 screen_id, struct disp_panel_para *panel, u32 vt);
```

The minimum is VT 784 because a shorter front porch makes the TCON start-delay formula too small. Above VT 859 that formula overflows its 16-bit field (Findings), hence the decision to leave TRI2 at 5558: the TCON then starts 7 lines after the DSI's ready point and is held back by the DSI's FIFO, and the register-write window and `judge_line` stay as they are. The fallback, DSI video start delay = VT − 6, keeps the TCON's timing exact relative to the visible lines, but only works if the vblank interrupt stays at the porch's start (the `cur_line` histogram shows this). `FBIO_WAITFORVSYNC` returns at the new rate; its 50 ms timeout covers anything down to 20 Hz.

| Target (Hz) | VT (front porch) | Achieved (Hz) | Error |
|---|---|---|---|
| NES/SNES NTSC 60.0988 | 786 (9) | 60.0792 | −327 ppm |
| NTSC 59.94 | 788 (11) | 59.9267 | −223 ppm |
| Genesis NTSC 59.9228 | 788 (11) | 59.9267 | +65 ppm |
| GB/GBA 59.7275 | 791 (14) | 59.6994 | −471 ppm |
| NES PAL 50.0070 / PAL 50 | 944 (167) | 50.0235 | +331 / +471 ppm |
| Genesis PAL 49.7015 | 950 (173) | 49.7076 | +123 ppm |
| Menus 40 | 1180 (403) | 40.0188 | +471 ppm |

A core runs at the achieved rate and its audio is resampled (0.05 % is under 1 cent of pitch). With gating, a still screen already costs no CPU wake-ups; a lower rate saves only scanout (the DE reads 189 MB/s at 60 Hz) and panel and link power.

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
- (2026-10-19, device) Brightness ran backwards from the first deep sleep after each boot until the next reboot: the PWM channel control register (0x0300A100) read 0x00000000 after sleep, its active-state bit back at the reset value (active low). The driver's resume restored polarity through the core's `pwm_set_polarity()`, which writes nothing when the remembered polarity (normal) already matches. Resume now writes it to the register directly. Source: linux `drivers/pwm/pwm-sunxi-group.c`.
- (2026-10-10, stock) TrimUI's kernel forces fb0 to 64 MiB. Stock userspace also uses extra DE hardware layers for its overlay menu (`/dev/disp` 0x47/0x48), the G2D blitter (0x06480000, `/dev/g2d`) for copies and rotation, and DE colour controls (`/sys/devices/virtual/disp/disp/attr/enhance_*`, `color_temperature`). We use none of these.
- (2026-10-10, stock) Stock never powers the panel down while running; panel power-down only happens around suspend. The BSP's fb "blank" only hides the layer.
- (2026-10-10, stock) TrimUI's panel driver builds a gamma table, while the device tree has gamma disabled; ours builds none. Every gamma point table in TrimUI's kernel (`boot.fex`, image offsets 0x780430, 0x780da4, …) is Allwinner's identity template, 18 points 0, 15, …, 255 (2026-10-18), so even with gamma on it would change nothing. Source: the template in `lcd/bp101wx1-206.c`.
- (2026-10-18, stock) Stock's colour settings: `libtwindow.so` writes `(v − 10) · 5` (v 0–20) to `attr/color_temperature` and `v · 10` (v 0–10) to `attr/enhance_bright`, `enhance_contrast` and `enhance_saturation`. Stock's `/mnt/UDISK/system.json` defaults (10, 5, 5, 5) write 0 / 50 / 50 / 50. `MainUI`, `hardwareservice`, `keymon`, `libtmenu.so`, `moonlightui` and `mediaplayer` also use these paths.
- (2026-10-18, bsp) Colour temperature 0 leaves TCON gamma off (`disp_lcd_update_gamma_tbl_set` turns it on only for a non-zero temperature or inversion). Bright/contrast/saturation 50 feed the DE's device colour matrix and are also its built-in defaults (`_csc_enhance_setting` in `de/lowlevel_v2x/de_dcsc.c`), which we run with. Sharpness and auto contrast exist only on channel 0; our framebuffer is on channel 1.
- (2026-10-18, device) TCON +0x000 = 0x80000000: gamma off (bit 30). The gamma RAM (+0x400–0x7FC) holds uninitialised values, all different. The device colour matrix (DE 0x061B0000) is about identity (0x400 / 0x400 / 0x401 on the diagonal, 0 or −1 elsewhere).
- (2026-10-18, bsp) DE mixer 0 has 4 channels of 4 layers: 0 and 1 video (VSU scaler; channel 0 also has the enhance block), 2 and 3 UI (GSU scaler); every channel scales; line buffer 2560. The DE reads through the IOMMU, so any dma-buf could be a layer. G2D (`/dev/g2d`) and the Cedar decoder (`cedar_dev`, IRQ 94, H.264/H.265) are built in. Source: `de/lowlevel_v2x/de_feat.c`.
- (2026-10-10, stock) The device tree's panel size (135 × 216 mm) is wrong; the panel is about 65 × 49 mm.
- (2026-10-10, device) Panel off/on with our driver re-runs the JD9168 power-up and the picture returns, also with the GPU rendering throughout. Source: linux 40042cf29.
- (2026-10-12, device) The display raises its vblank interrupt 60 times a second whenever it is on, even with nothing drawing. With the display on, the CPUs never enter cluster sleep; with it off they spend 36–75 % of the time there.
- (2026-10-12, device) Specular's measurements (details in Specular's docs): draw-then-swap puts a frame on screen 32 ms (two vsyncs) after it starts; starting each frame at the vsync takes 16 ms; adding a 10 ms frame delay takes 6 ms at 60 fps (13 ms misses vsyncs). `FBIO_WAITFORVSYNC` returns when the display takes a new frame; buffer switches follow by a median 0.1 ms. An emulator on its own clock (60.0988 Hz) drifts against the panel's 60.2 Hz. Source: Specular ROADMAP, "Brick spike".
- (2026-10-13, device) Before the lock change, `FBIO_WAITFORVSYNC` waited for the framebuffer lock, which a GPU flip holds while it waits for the same vsync; a vsync-paced thread beside a presenting UI ran at about 40 fps. Source: linux 4d81ab5d7.
- (2026-10-18, bsp) The only display interrupt in use is DSI SPI 68 (`dispaly` in `/proc/interrupts`, all on CPU0); its handler is `disp_lcd_event_proc`. It reads the DSI line counter (lines since the front porch started) and counts the frame on time if that is ≤ start delay − `judge_line` = 7 − 3 = 4 lines (about 85 µs). Only then does `sync_event_proc` write the cached layer, mixer and enhance registers and wake the `FBIO_WAITFORVSYNC` and pan waiters; a late frame (counted as `skip`) does neither, so both slip a frame. So an interrupt held up on CPU0 costs a frame. Separately, an update past the start delay is counted in `err_cnt`; what that costs is unverified. Source: `de/disp_lcd.c`, `de/disp_display.c`, `de/disp_manager.c` (`err_cnt`), `disp_lcd_is_in_safe_period()` in `de/disp_lcd.c`.
- (2026-10-18, bsp) `disp_mgr_apply` only fills a register cache; changes, including the panel's gamma table (`panel_extend_dirty`), reach the hardware only in the vblank handler. Pan display = apply, then `fb_wait_for_vsync`, which gives up after 50 ms (`-ETIMEDOUT`). The vsync uevent fires only with `vsync_event_en`. Source: `de/disp_manager.c`, `de/disp_lcd.c`, `dev_fb.c`.
- (2026-10-18, bsp) DSI +0x04: interrupt enables in bits 15:0, flags in 31:16 (write 1 to clear); vblank is enable bit 2, flag bit 18. `dsi_irq_enable/disable/query` are bit-field read-modify-writes of the whole word, so each also clears every set flag, and nothing locks them. Source: `de/lowlevel_v2x/de_dsi.c`.
- (2026-10-18, bsp) What depends on VT: the DSI video start delay (`vt − vfp + 1` = 778 for any VT) and VBLK (4 for any VT, as 1080 × 3 bytes is a multiple of 4) don't change with the front porch. The TCON's TRI2 start delay `(vt − y − 9) · ht · de_clk / dclk / 8` is a 16-bit field and overflows above VT 859. `judge_line` and `usec_per_line` are computed only while 0, so they stay fixed after the first enable. Software values from VT: `panel_info.lcd_vt`, `frame_per_sec`, `timings.{ver_total_time, ver_front_porch, frame_period, start_delay}` (`cal_real_frame_period` assumes dclk 300 / 6 = 50 MHz, about 2 % off), `al_priv.output_fps` (only the scaler's bandwidth check uses it, so a lower real rate is safe) and fb `var.lower_margin` (dc_sunxi's reported refresh comes from var and reads 62 Hz today, as the pixclock is rounded). Source: `de/lowlevel_v2x/de_dsi.c` `dsi_basic_cfg`, `de/lowlevel_v2x/de_lcd_sun50iw10.c`, `de/disp_lcd.c`, `de/lowlevel_v2x/de_hal.c`.
- (2026-10-18, bsp) `DISP_LCD_SET_FPS` (0x107) and `DISP_LCD_GET_FPS` (0x108) are declared but have no handler in `dev_disp.c`. Source: `include/video/sunxi_display2.h`.
- (2026-10-18, bsp) cpuidle runs driver `arm_idle` with governor `menu`, which compares the `PM_QOS_CPU_DMA_LATENCY` limit (applies to all CPUs) with `exit_latency`, set to entry + exit: cpu-sleep-0 46 + 59 = 105 µs (minimum residency 3570 µs), cluster-sleep-0 47 + 74 = 121 µs (5000 µs). `pm_qos_update_request` calls a blocking notifier, so it can't run in interrupt or atomic context. Source: `arch/arm64/boot/dts/sunxi/sun50iw10p1.dtsi`, `drivers/cpuidle/dt_idle_states.c`, `kernel/power/qos.c`.
- (2026-10-18, device) Baseline after 23.5 h up: DSI +0x04 = 0x00020004, +0x14 = 0x30a7 (start delay 778), +0x1C = 0x03100300 (VT 784, VACT 768); TCON TRI2 (+0x168) = 0x15b6000a. `attr/sys`: irq 5 188 602, skip 1856 (0.036 %), mgr err 9804, vsync events 0. cpuidle: CPU0 4.5 % in cpu-sleep, CPUs 1–3 42–73 %, cluster sleep 0 on all. The DSI line counter (+0x2E0) is live and readable from userspace (0xa5–0x2bf at random moments); `/dev/cpu_dma_latency` exists.
- (2026-10-18, inferred) The JD9168 table (`lcd/trimui_brick.c`) writes 0xB2/0xB3 (`00 7e`), 0xC1, 0xC3 and 0xC4 (timing- or GIP-like values) and 0xC8 (analog gamma). No datasheet was found, so the panel's lowest rate and porch limits are known only by experiment.
- (2026-10-10, upstream) Mainline gaps, from the live registers: the `sun50i-a100` D-PHY matches every value except ANA1 bit 5; `sun6i_mipi_dsi` matches except HSA length (mainline minimum 10 vs 2, +8 B/line) and VBLK (0 vs 4); `sun4i_tcon` CPU mode matches the layout but computes start_delay 1972 vs 5558 and safe period 3000 vs 765, and sets FIFO flush and IO_TRI 0xe0000000 where stock doesn't; there is no A100/A133 TCON variant. The block at 0x06510000 matches `sun8i_tcon_top` (port select 0x1C, DSI gate bit 16 of 0x20). No mainline driver for the newer PWM block. Mainline would also need the IOMMU in pass-through or a DE IOMMU binding. Source: mainline's `sun50i-a100` D-PHY, `sun6i_mipi_dsi` and `sun4i_tcon`.
- (2026-10, upstream) Mainline has the A100 DSI and D-PHY (since 6.2) but no A100/A133 mixer or TCON. Parthiban's LVDS series stalled (2024-12); leow149's RFC v8 for the TrimUI Smart Pro (2026-09) gives a black screen with TRIGGER_START never clearing. PocketForge reports private 6.x/7.x kernels with an A133 DE/TCON/DSI stack and an OTM1289A driver, scanout unverified; the Smart Pro's tree also names `otm1289a`, so TrimUI's multi-panel driver likely serves both devices.
- (2026-10-10, bsp) Allwinner's 5.15 BSP (github.com/radxa/allwinner-bsp) supports sun50iw10 in `disp2` (`lowlevel_v2x`, DSI "IP version 40") and is a better register reference than the 4.9 code.

## Open questions

Device experiments for the planned work, in this order. Helpers (from the repo root):

```sh
D='ssh -o BatchMode=yes -o IdentitiesOnly=yes -i build/ssh-host-keys/dev_key root@192.168.7.2'
snap() { $D 'for c in 0 1 2 3; do for s in 0 1 2; do printf "%s " $(cat /sys/devices/system/cpu/cpu$c/cpuidle/state$s/time); done; echo; done; grep dispaly /proc/interrupts; grep -E "err|skip" /sys/class/disp/disp/attr/sys'; }
```

- **Does masking free cluster sleep with the screen on?** (E1, no kernel change; decides whether gating is worth building.) `sv stop frontend` (the last picture stays); `snap`, 60 s, `snap`; `memreg 0x06504004 0x00000000` to mask (writing 0 to the flags leaves them set) and read it back with `memreg 0x06504004` for bit 2 clear (write again if the handler raced); `snap`, 60 s, `snap`; `memreg 0x06504004 0x00040004` (clears the stale flag and unmasks), `sv start frontend`. Expect the interrupt count frozen, the picture stable, and cluster-sleep time rising towards screen-off's 36–75 %. If cluster sleep stays at 0, something else blocks it and gating saves little: find that first (powertest's per-process wake-ups).
- **Is 110 µs enough for the commit window?** (E2, after E1, with Specular and glspin.) Note `skip`/`err` around `glspin 60`; repeat while holding a limit (`exec 3>/dev/cpu_dma_latency; printf '\156\000\000\000' >&3` holds 110 µs until `exec 3>&-`; `'\150\000\000\000'` holds 104 µs); also check pacing with Specular's s5_scanout `vsync 10`. If 110 µs shows more skips than 104 µs, revisit `qos_us`.
- **What does gating save?** (E3, after the build.) powertest's idle-screen-on phase, 1 h each with the switch on and off, in %/h; today 12.1 %/h with the screen on, 6.0 %/h off.
- **Does Specular stop presenting when nothing changes?** Gating only masks then; if it presents every frame on a still screen, the interrupt never masks.
- **Is the picture clean with VT raised and the TCON start delay untouched?** (E4.) With `$D 'glspin 30 & sleep 3; memreg 0x06504000'` running, raise VT step by step: `memreg 0x0650401c 0x03200300` (VT 800, 59.0 Hz), `0x03500300` (848, 55.7 Hz), `0x035b0300` (859), `0x03b00300` (944, 50.02 Hz), `0x049c0300` (1180, 40.0 Hz). Only raise VT this way: the write lands at a random line, and a VT below the current line could let the counter run on towards 8191; go back with `dispctl off; dispctl on` (reprograms VT 784). At each step check the picture (shift, rolling, tearing, flicker), the rate (`/proc/interrupts` over 10 s, ≈ 500 at 50 Hz), the `skip`/`err` deltas, `dmesg`, and that glspin's fps follows. Clean: keep TRI2. Not clean: try the fallback below.
- **Does the fallback work: DSI video start delay at VT − 6?** (Only if E4 fails.) The field is DSI +0x14 bits 16:4 (low bits 0x7 are mode flags), so after raising VT to 944, `memreg 0x06504014 0x3aa7` sets 938; check as in E4. It is only usable if the vblank interrupt still fires at the front porch's start rather than at the start delay; the built kernel's `cur_line` histogram shows which, and if it moves, the on-time test needs rework.
- **What is the JD9168's lowest rate, and does a lower rate save power?** (E5.) VT 1181 (40 Hz), 1574 (30 Hz) and 1890 (25 Hz), looking for flicker on mid-grey and dark scenes; sets `vt_max`. Then 1 h of powertest idle at 60 Hz and at 40 Hz (with gating, if built by then).
