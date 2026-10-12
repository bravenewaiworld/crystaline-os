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
| SD card | Fastest mode (UHS SDR104, 150 MHz, 1.8 V signalling), as stock; survives deep sleep |
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
| Power tuning | Overnight `powertest` (2026-10-12): deep sleep ~1 %/h; idle with screen on 10–12 %/h; screen off 6 %/h; full load ~40 %/h. Done: CPU regulator and power chip DC-DC 1/2 in automatic mode (−17 % at idle, stable under full load); top USB-C port's 5 V off in sleep (vendor driver). Kept `ondemand`: `schedutil` held the CPU at higher speeds at idle. To do: an 8-hour sleep measurement; unused clocks; the display's 60 Hz interrupt keeps the CPUs out of their deepest idle state whenever the screen is on (see item 14); the LEDs' 5 V supply stays on while awake even with every LED dark | Battery life |
| WiFi and Bluetooth (XR829) | Working: WiFi (2.4 GHz only; SSH and WebDAV over it) and Bluetooth audio (pairing, automatic reconnection, pairings kept across reboots). The XR829 has no Bluetooth address of its own: the first random one is saved in the state area and reused (our own image must keep that file). Missing: Bluetooth audio uses SBC only (see item 10 below). Bug: after `sleepnow` restarts WiFi, the XR829 driver can leave the system so that every screen update waits about two vsyncs (25–50 fps instead of 60), with "miss interrupt" warnings in the kernel log; restarting WiFi again fixes it (found by Specular's spike, 2026-10-12) | Bluetooth headphones |
| Audio | Working: speaker and headphones, jack switches between them, amplifiers off when idle, volume controls in the standard direction. To do: Specular's volume control (one level mapped onto the codec's controls; separate levels for speaker and headphones) | Polish |
| LEDs | Working: 14 LEDs (top bar 0–7, F2, F1, under L1, L2, R2, R1), correct colours, off in sleep and restored after. To do: zone names and effects for Specular (the light bar follows its accent colour) | Polish |
| Internal storage | Not visible when booting from the SD card. Deferred to the install work: the internal storage has partitions with the same names as the card's ("boot", "rootfs"), so scripts must first be limited to the disk the system booted from | Installing to internal storage |

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
