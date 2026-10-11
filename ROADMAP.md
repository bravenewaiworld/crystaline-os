# Roadmap

Decisions so far:
- **Kernel:** stay on Allwinner's 4.9 vendor kernel. Mainline Linux lacks this chip's display,
  audio and WiFi drivers and its deep sleep, and the closed GPU libraries depend on vendor display
  code. Userspace sticks to standard interfaces, so a later move stays cheap.
- **Frontend:** our own launcher, and our own clean-room emulation runtime (libretro), using
  GPL-licensed code from muOS's runtime ("Pickles") for the hard parts: audio/video rate
  control, 3D-core rendering, save-state handling. NextUI's tuning for this device serves as a
  reference only (MinUI-derived code has no licence). Cores are chosen system by system later.
- **System image:** our own (not TrimUI's), installable on the SD card or internal storage.
- **User data** (games, saves, settings) lives on the SD card (FAT32), also when the system is
  installed internally.
- **PC transfer:** WebDAV over WiFi first; later our own simple browser page for uploading and
  downloading games and saves. No MTP.

Order of work: battery and charger, then sleep, then our own system image, then the frontend.
Audio, WiFi/Bluetooth and power tuning fit in alongside.

## Hardware: working

| Area | Status |
|---|---|
| CPU speed scaling | 408–2000 MHz, all governors |
| Display | Panel, backlight, panel off/on |
| GPU | TrimUI's closed driver (v1.19), rebuilt from source; 60 fps, vsync-locked |
| Buttons, FN switch, power key | Standard input devices; `padbridge` presents them as the usual gamepad |
| SD card | Works, but at 50 MHz (stock: 150 MHz) |
| USB | Device mode only (adb and a network link to a PC), forced on |
| Power chip voltage outputs | Correct |

## Hardware: missing

Roughly by impact on the goal.

| Area | What's missing | Matters for |
|---|---|---|
| Battery and charger | Driver works (level, status, voltage, current, temperature; charge settings as stock). Missing: input current limit by charger type, as stock does | Charging speed on wall chargers |
| Sleep | Deep sleep works (through Allwinner's firmware, as stock's kernel is configured); power button and alarm wake. To do: measure how deep (overnight drain test), check every device after resume | Battery life |
| Power tuning | Voltage regulators stuck in their least efficient mode; unused clocks left running; rumble, speaker amp and USB-A power always on; CPUs never reach their deepest idle state | Battery life |
| WiFi and Bluetooth (XR829) | Working: WiFi (2.4 GHz only; SSH and WebDAV over it) and Bluetooth audio (pairing kept across reboots, automatic reconnection, a unique address per device). Bluetooth audio uses SBC only | — |
| Audio | Working: speaker and headphones, jack switches between them, amplifiers off when idle, volume controls in the standard direction. To do: the frontend's volume (one level mapped onto the codec's controls; separate levels for speaker and headphones) | Polish |
| Rumble | Working: standard force feedback (FF_RUMBLE), strength as motor voltage (2.0–3.3 V), forwarded from the virtual gamepad so games can use it; motor supply off when idle | — |
| LEDs | Working: 14 LEDs (top bar 0–7, F2, F1, under L1, L2, R2, R1), correct colours, off in sleep and restored after. To do: zone names and effects for the frontend | Polish |
| USB cable detection | Can't tell charger, PC and host mode apart; top USB-A port untested | Charging, PC transfer |
| SD card fast mode | Card runs at a third of stock speed | Load times |
| Thermal limits | Not verified on our kernel | Performance, safety |
| Internal storage | Not visible when booting from the SD card | Installing to internal storage |

## Beyond the kernel

1. **Our own system image**, built with Buildroot: init, our services, Bluetooth stack with audio,
   WiFi tools, SSH, libretro cores. Replaces TrimUI's stock system.
2. **GPU adapter:** our own SDL2 build with a small video backend for TrimUI's closed GPU
   libraries, so nothing else depends on TrimUI's libraries.
3. **Storage layout:** a read-only system partition, plus the SD card's FAT32 data partition for
   games, saves, BIOS files and settings; power-loss-safe saving.
4. **Install, update and recovery:** flash-an-image install, updates from a file on the card or
   over WiFi, and a recovery path.
5. **PC transfer over WiFi:** a WebDAV server for games and saves, then a simple browser page on
   top of it.
6. **Cores:** a curated set, built and tuned for this CPU, with chosen defaults per system.
7. **Power policy:** CPU/GPU profiles, screen dimming and off, sleep, low-battery auto-save and
   shutdown.
8. **Clock:** set from WiFi time, and kept across power-off if the hardware allows.
9. **Dev workflow:** one reproducible build of the whole image; a hardware test checklist.
10. **Bluetooth audio codecs:** build bluealsa with aptX / aptX HD (libopenaptx), AAC (fdk-aac)
    and LDAC (libldac) besides SBC. Check each library's licence for redistribution (fdk-aac's
    is not GPL-compatible) and the CPU cost of encoding, especially LDAC, on this chip.
11. **USB mass storage, done safely:** expose the SD card's data partition to a PC over USB
    without corrupting it (the device must stop using the card while it's shared).
