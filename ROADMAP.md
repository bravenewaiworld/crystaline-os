# Roadmap

Decisions so far:
- **Kernel:** stay on Allwinner's 4.9 vendor kernel. Mainline Linux lacks this chip's display,
  audio and WiFi drivers and its deep sleep, and the closed GPU libraries depend on vendor display
  code. Userspace sticks to standard interfaces, so a later move stays cheap.
- **Frontend:** Specular (`specular/`), our own launcher and libretro runtime, built as a
  separate product that also runs on other devices. Its plans and decisions are in
  `specular/ROADMAP.md`; the Brick-specific parts live in `specular/devices/brick`.
- **System image:** our own (not TrimUI's), installable on the SD card or internal storage.
- **User data** lives on the SD card (FAT32), also when the system is installed internally:
  `roms/`, `bios/`, `saves/`, `configs/` and `cache/` (downloaded box art and indexes, safe to
  delete).
- **PC transfer:** WebDAV over WiFi first; later our own simple browser page for uploading and
  downloading games and saves. No MTP.

Order of work: hardware support (nearly done), power tuning (after the overnight power test),
then our own system image, then the frontend (Specular).

## Hardware: working

| Area | Status |
|---|---|
| CPU speed scaling | 408–2000 MHz, all governors |
| Display | Panel, backlight, panel off/on; `FBIO_WAITFORVSYNC` on `/dev/fb0` waits for the next frame (it was a no-op; Specular paces its frames by it) |
| GPU | TrimUI's closed driver (v1.19), rebuilt from source; 60 fps, vsync-locked |
| Buttons, FN switch, power key | Standard input devices; `padbridge` presents them as the usual gamepad |
| SD card | Fastest mode (UHS SDR104, 150 MHz, 1.8 V signalling), as stock; survives deep sleep. The data partition is mounted with file names matched regardless of case, as on a PC (`utf8` with `iocharset=iso8859-1`; `iocharset=utf8` made lookups case-sensitive, so `roms/` didn't find a card's `Roms/`) |
| USB | Bottom USB-C port switches by itself: PC mode (adb, network link) with a computer or charger, host with 5 V for USB devices, off when unplugged; the cable and charger type are readable (`/sys/class/extcon`). Top USB-C port: host, 5 V always on |
| Power chip voltage outputs | Correct |
| Battery and charger | Level, status, voltage, current, temperature; charge settings as stock; input current limit set by the chip's charger detection (also when booted already plugged in). Open: the reported level once lagged the gauge by 40 % (the driver's level smoothing was left active, cause unknown) |
| Rumble | Standard force feedback (FF_RUMBLE), strength as motor voltage (2.0–3.3 V), forwarded from the virtual gamepad so games can use it; motor supply off when idle |
| Thermal limits | As stock: CPU slows from 58/63 °C, shuts down at 90 °C (shutdown not tested) |

## Hardware: missing

Roughly by impact on the goal.

| Area | What's missing | Matters for |
|---|---|---|
| Sleep | Deep sleep works (through Allwinner's firmware, as stock's kernel is configured); power button and alarm wake; SD card, USB, Bluetooth and LEDs come back after resume. The WiFi driver refuses to suspend while connected, so `sleepnow` stops WiFi first and restarts it after. To do: measure how deep (overnight `powertest`) | Battery life |
| Power tuning | Overnight `powertest` (2026-10-12): deep sleep ~1 %/h; idle with screen on 10–12 %/h; screen off 6 %/h; full load ~40 %/h. Done: CPU regulator and power chip DC-DC 1/2 in automatic mode (−17 % at idle, stable under full load); top USB-C port's 5 V off in sleep (vendor driver). Kept `ondemand`: `schedutil` held the CPU at higher speeds at idle. Deep sleep with these settings: 0.9 %/h (~27 mA, ~4.5 days from full; 12 h measurement), high for deep sleep. To do: find what draws power in sleep (candidates: panel rails left on, Bluetooth chip, SD card); unused clocks; the display's 60 Hz interrupt keeps the CPUs out of their deepest idle state whenever the screen is on (see item 14); the LEDs' 5 V supply stays on while awake even with every LED dark | Battery life |
| WiFi and Bluetooth (XR829) | Working: WiFi (2.4 GHz only; SSH and WebDAV over it) and Bluetooth audio (pairing, automatic reconnection, pairings kept across reboots). The XR829 has no Bluetooth address of its own: the first random one is saved in the state area and reused (our own image must keep that file). Missing: Bluetooth audio uses SBC only (see item 10 below). Seen once (Specular's spike, 2026-10-12): after `sleepnow` restarted WiFi, screen updates waited about two vsyncs (25–50 fps instead of 60) until WiFi was restarted again. Not reproduced in about 48 further sleeps. Normal after waking: about 5 s of 20–25 fps while the WiFi firmware reloads, which floods the SDIO bus. Likely causes, unproven: kernel log bursts to the 115200-baud serial console (was `loglevel=8`, now 4: warnings only; each line holds a CPU and the console lock about 5 ms, and the GPU's display module takes that lock on every flip), or interrupts held up on CPU0 (the display driver skips a flip if its vblank interrupt waits more than about 100 µs) | Bluetooth headphones |
| Audio | Working: speaker and headphones, jack switches between them, amplifiers off when idle, volume controls in the standard direction. Specular sets one level as the codec's `DAC volume` (2 dB per step, 0 dB at the top); the codec's driver keeps that level through playback starts and sleep (TrimUI's reset it to the device tree's default). TrimUI's ALSA software volume ("Soft Volume Master") refuses writes. To do: separate levels for speaker and headphones | Polish |
| LEDs | Working: 14 LEDs (top bar 0–7, F2, F1, under L1, L2, R2, R1), correct colours, off in sleep and restored after. To do: zone names and effects for Specular (the light bar follows its accent colour) | Polish |
| GPU display module | Fixed (2026-10-12): a deadlock between `dc_sunxi`'s flip and the kernel's framebuffer code, which took two locks in opposite orders; a second program touching the framebuffer while a GPU app presented hung the display and suspend. `tools/gpu-patches/` now fixes the lock order; checked with the status screen starting during a GPU app, and sleep during one. Also fixed (2026-10-14): `FBIO_WAITFORVSYNC` waited for the framebuffer lock, which a page flip holds while it waits for the same vsync, so a game paced by the vsync beside the UI ran at about 40 fps; the wait now runs without the lock (in `fbmem.c`). Left: each GPU app run leaves an idle `pvr_misr` kernel thread behind | Reliability |
| Internal storage | Works from the SD card (2026-10-14): enabled in the card's device tree at stock's settings (DDR52, 50 MHz), detached by `sdinit` before TrimUI's start-up scripts run (their `/dev/by-name` links would point at it), attached read-only on request by `emmc` (`emmc survey` saves its identity, partition table, small partitions and a read check to the card). It has partitions with the same names as the card's ("boot", "rootfs"), so scripts must be limited to one disk. To do: writing to it (the installer) | Installing to internal storage |

## Beyond the kernel

1. **Our own system image**, built with Buildroot: init, our services, Bluetooth stack with audio,
   WiFi tools, SSH, libretro cores. Replaces TrimUI's stock system.
2. **Frontend:** Specular; see `specular/ROADMAP.md`. Its Brick device crate is the only code
   that touches TrimUI's closed GPU libraries (EGL straight to the display).
3. **Storage layout:** a read-only system partition, plus the SD card's FAT32 data partition
   with the user-data folders above; power-loss-safe saving.
4. **Install, update and recovery:** flash-an-image install, updates from a file on the card or
   over WiFi, and a recovery path.
5. **PC transfer over WiFi:** a WebDAV server for games and saves (running on the test card:
   `dufs`, no login yet), then a simple browser page on top of it.
6. **Cores:** a curated set, built and tuned for this CPU, in the system image (which cores and
   their defaults per system: `specular/ROADMAP.md`).
7. **Power policy:** CPU/GPU profiles, screen dimming and off, sleep, low-battery auto-save and
   shutdown; whether the top USB-C port's 5 V stays on while awake. A **power-saving mode** the
   user can switch on: lower CPU/GPU limits, dimmer screen, WiFi and Bluetooth off when unused,
   LEDs off, and a lower display refresh rate where the game allows it.
8. **Clock:** set from WiFi time, and kept across power-off if the hardware allows.
9. **Dev workflow:** one reproducible build of the whole image; a hardware test checklist. Today:
   `make test-card` builds a development SD card and `make update-card` rewrites a running one
   over adb.
10. **Bluetooth audio codecs:** build bluealsa with aptX / aptX HD (libopenaptx), AAC (fdk-aac)
    and LDAC (libldac) besides SBC. Check each library's licence for redistribution (fdk-aac's
    is not GPL-compatible) and the CPU cost of encoding, especially LDAC, on this chip.
11. **USB mass storage, done safely:** expose the SD card's data partition to a PC over USB
    without corrupting it (the device must stop using the card while it's shared).
12. **USB drives:** when to mount a drive plugged into either port, and safe removal. Nothing is
    mounted automatically for now (stock's automounting covered the SD card's data partition).
13. **WiFi toggle: On, Off, Auto.** Auto means WiFi is on only while the frontend asks for it for
    a specific use (file transfer, time sync, an update download), then off again. Connected WiFi
    wakes the CPU about 30 times a second and blocks deep sleep, so Auto should be the default.
14. **Display refresh rate:** run the panel at the game's own rate (e.g. 50 Hz for PAL games, or
    arcade rates near 60 Hz) instead of always 60 Hz, as close to variable refresh as the panel
    and display engine allow; check how far the panel's refresh can be lowered (blanking or pixel
    clock) for menus and still screens; and stop the display engine's 60-per-second interrupt
    while nothing is being drawn, so the CPUs can reach their deepest idle state.
15. **exFAT data cards:** most cards over 32 GB come formatted exFAT, which our 4.9 kernel can't
    read; for now the data partition must be FAT32 (an installed system uses the card's first
    FAT32 partition). Options: a backported exFAT driver, or reformatting from the device.
16. **Bluetooth audio latency:** headsets add about 150–250 ms with SBC, most of it the headset's
    own buffer. The codec barely matters: aptX Low Latency and aptX Adaptive are closed
    (libopenaptx has neither), FastStream is supported by bluealsa but by almost no headphones,
    and LE Audio (LC3) probably needs a newer Bluetooth controller than the XR829 (check its
    datasheet). What we can do:
    - Shrink our part: Specular's sound queue and bluealsa's buffer, as small as they go without
      dropouts.
    - Measure first: log the headset's reported delay (BlueZ's `MediaTransport1.Delay`, for
      headsets that report it) in the wireless trace.
    - Point users to their headset's own low-latency ("game") mode where it has one.
17. **USB audio output:** gaming headsets' 2.4 GHz USB dongles and USB-C DACs on either USB-C
    port (about 20–40 ms, unlike Bluetooth's 150–250 ms). Needs the kernel's USB audio driver
    (`snd-usb-audio`) and a third kind of sound output in Specular, beside the device's own and
    Bluetooth.
