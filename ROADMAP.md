# Crystaline OS Roadmap

## V0

Goals: 
- Full compatibility with all of the TrimUI Brick hardware
- Optimized power consumption
- Available compute fully leveraged

"Built, to test on the device" lists work whose code is written and passes the PC tests, but has not run on a Brick yet.

### Display

Completed:
- Panel image display
- Backlight
- Panel off/on
- `FBIO_WAITFORVSYNC` on `/dev/fb0` waits for the next frame
- Colour (gamma): stock leaves the gamma table off and the colour matrix at identity at its default settings, as we do; nothing to change
- Spare display and video hardware (display layers and scaler, G2D blitter, video decoder): not worth using for now (little latency gain, and shaders, sharp scaling and rotation would be lost)

Built, to test on the device:
- Brightness no longer runs backwards after deep sleep (the backlight PWM's polarity is rewritten on resume)

TODO:
- Stop the display's 60-per-second interrupt while nothing is drawn (designed: masked after 3 idle frames, unmasked on any display change or vsync wait, a 110 µs wake-latency limit while on, a kill switch): first the device experiment in the design, then build. Only saves power once Specular stops presenting still screens
- Run the panel at the game's own refresh rate (designed: `DISP_LCD_SET_FPS`/`GET_FPS` on `/dev/disp`, 40–60.2 Hz by changing the vertical total): first the device experiments for the JD9168's limits and the TCON start delay, then build

### GPU

Completed:
- TrimUI's closed PowerVR GE8300 driver (DDK 1.19), kernel module rebuilt from source; userspace EGL/GLES libraries taken from the stock firmware
- 60 fps, locked to vsync
- Fixed: deadlock between the GPU's display module (`dc_sunxi`) and the framebuffer code (opposite lock order) that hung the display and suspend
- Fixed: `FBIO_WAITFORVSYNC` no longer waits on the framebuffer lock, which a page flip holds (a vsync-paced game beside the UI ran at ~40 fps)
- Kernel slab debugging off by default (cost a game's render thread ~12 % in `drm_ioctl`)
- Why stock rejects 399 and 228 MHz: the GPU clock divider is a power of two, so 399 MHz can't be reached from the 702 MHz PLL; the GPU has no supply rail of its own (it shares the system rail), so lower clocks can't have lower voltage

Built, to test on the device:
- Leftover idle `pvr_misr` threads (155 after a day): the display bridge never freed handles (patch 0002) and each app opened two driver connections (0004)
- Debugfs voltage commands no longer crash without a GPU regulator; unreachable clock points are skipped (0003)
- GPU thermal zone: critical trip at 95 °C (the datasheet allows a 110 °C junction)

TODO:
- GPU clock profiles: measure whether 351 MHz saves 3 % or more of a light game's drain (USB power meter); build the clock control only if it does
- Confirm the GPU's supply rail (likely DC-DC 1, 0.94 V) by watching it under GPU load

### CPU

Completed:
- Frequency scaling 408–2000 MHz with the chip's speed-bin voltages, all governors
- `ondemand` governor by default (`schedutil` held higher speeds at idle)

Built, to test on the device:
- Profiles through `brick-power profile performance|balanced|saver` (1200–2000 / 408–2000 / 408–1200 MHz); the governor now checks every 50 ms instead of every 2 s. Gate: idle power must not rise
- A minimum CPU speed Specular raises during a game: `brick-power cpu-min <MHz>|default` (PS1 games settled near 1.2 GHz and fell short of full speed)

TODO:
- Decide whether to keep the 2.0 GHz step, by a long full-load run at 2.0 GHz with temperature logging; keep it if stable

### Input

Completed:
- Buttons, FN switch and power key as standard input devices
- `padbridge`: presents the buttons as a standard gamepad (Xbox 360 layout, triggers as axes, D-pad as hat), forwards rumble to the motor; FN switch passed through (Specular uses it as Mute)

Built, to test on the device:
- Rumble always offered; the motor is opened when first used and reopened if it goes away
- Fixed: a game's first rumble froze the buttons until a restart (while looking for the motor, padbridge opened its own virtual pad, which the game's rumble request was holding)

### Storage

Completed:
- SD card at its fastest mode (UHS SDR104, 150 MHz, 1.8 V), survives deep sleep
- Data partition (FAT32) created on first boot over the rest of the card, mounted with case-insensitive file names, as on a PC
- Read-only system partition (versioned squashfs images) plus the SD card's data partition
- Internal storage (eMMC) at stock settings (DDR52, 50 MHz)

Built, to test on the device:
- exFAT data cards: mainline's driver (6.18 LTS plus later fixes) backported, and exfatprogs 1.4.3; passed a functional suite and 40 power cuts in a virtual machine. Still to do on the device: power-cut rounds on a real card, cards written by Windows and macOS
- SD card kept mounted: hotplug (insert, remove, swap), up to 5 s wait at start-up, a check before every mount, user folders made, the card's state and a message for the user in `/run/card/state`; the system's own card pulled powers off. Fixed on the way: a stranger's card inserted after the system card was pulled could have been formatted

### USB

Completed:
- Bottom USB-C port switches role by itself: device mode (network link to a PC) with a computer or charger, host with 5 V for USB devices, off when unplugged; cable and charger type readable
- Top USB-C port: host, 5 V always on

Built, to test on the device:
- Top port's 5 V switch while awake (`brick-power usb-top on|off`; refuses while a device is attached)

TODO:
- Find what power chip register 0xE9 holds; if it is the charger's advertised current, use it to set the input limit for USB-C chargers without BC1.2
- Test charger detection and the input limit on a plain PC port (500 mA expected)

### Power and Battery

Completed:
- Power chip (AXP2202) voltage outputs correct; battery and charger drivers: level, status, voltage, current, temperature
- Charging as stock; input current limit from the charger detection, also when booted already plugged in
- Thermal limits as stock: CPU slows from 58/63 °C, shuts down at 90 °C
- Deep sleep (through Allwinner's firmware); power button and alarm wake; SD card, USB, Bluetooth and LEDs restored after resume
- CPU regulator and power chip DC-DC 1/2 in automatic mode (−17 % at idle)
- Top USB-C port's 5 V off in sleep
- Measured: deep sleep 0.9 %/h (~27 mA, ~4.5 days); idle screen on 10–12 %/h; screen off 6 %/h; full load ~40 %/h

Built, to test on the device:
- Battery level is the gauge's own (no driver smoothing; the old lag came from TrimUI's U-Boot setting the smoothing flag)
- LEDs' 5 V supply off while every LED is dark (check nothing else is fed by it)
- Battery guard: powers off at 1 % (checked against the battery voltage); the power chip's low-battery interrupt wakes a sleeping device to do it. Gate: does that interrupt wake it?
- Power mechanisms for Specular's policy: `brick-power` profiles and top-port switch (above); dimming, screen off, the 3 % save-and-quit and the power-saving mode are Specular's

TODO:
- Find what draws ~27 mA in deep sleep (candidates: DRAM self-refresh, the always-on domain, rails the sleep firmware keeps on, the SD card, the WiFi/Bluetooth chip's supply), by a stock-firmware sleep test or a USB power meter on the charge port (the gauge's coulomb counter isn't usable)
- Turn off unused clocks (the vendor clock driver never does: spare video PLLs, video decoder, crypto engine, GPADC): measure first, change only if it saves
- Display refresh and interrupt savings (see Display)

### Wireless

Completed:
- WiFi (XR829, 2.4 GHz), stable MAC address; On/Off/Auto (driven by Specular)
- Bluetooth audio (SBC): pairing, automatic reconnection, pairings and the Bluetooth address kept across reboots
- Sleep with WiFi connected (WiFi is stopped before sleep and restarted after; its driver refuses to suspend while connected)
- Bluetooth controller is Bluetooth 4.1 (HCI version 7, LE features: encryption only): no LE Audio

Built, to test on the device:
- `xr829-attach`, our own Bluetooth start-up, replacing TrimUI's binary `hciattach` (keeps RTS/CTS on at 1.5 Mbaud; logs the controller's version)
- Bluetooth address derived from the chip ID when none is saved (saved addresses are kept)

TODO:
- ~5 s of 20–25 fps after waking while the WiFi firmware reloads (floods the SDIO bus): find the cause by tracing the first seconds after waking with interrupt latencies (serial console bursts vs interrupts held up on CPU0)
- Seen once: after waking, screen updates waited two vsyncs (25–50 fps) until WiFi was restarted again
- Bluetooth audio latency: shrink our buffers, log the headset's reported delay

### Audio

Completed:
- Speaker and headphones; the jack switches between them
- Amplifiers off when idle
- Volume controls in the standard direction; the level is kept across playback starts and sleep

Built, to test on the device:
- Separate levels for speaker and headphones (`Speaker Playback Volume`, `Headphone Playback Volume`; "DAC volume" is gone, so Specular must switch before the next update)

TODO:
- Check whether the speakers are wired as stereo, by playing a tone on the left channel only

### LEDs and Rumble

Completed:
- 14 LEDs with correct colours, off in sleep and restored after
- Rumble as standard force feedback; strength as motor voltage, motor supply off when idle

Built, to test on the device:
- Rumble's top strength 3.5 V, as stock
- Fixed: the motor's supply stayed on while awake (the bootloader left it on and the driver counted it as its own)

### Clock

Completed:
- Clock read from the clock chip at boot; set from network time while WiFi is up, and written back

Built, to test on the device:
- Time zone: `brick-timezone get|set|list` (default UTC; the clock chip stays UTC); files on the SD card stamped in local time. Automatic time zone is Specular's (with the user's consent to an IP lookup)

TODO:
- Check whether the clock survives power-off, by powering off for an hour and comparing with network time

### Boot

Completed:
- Boot chain: TrimUI's first-stage loader and U-Boot, then our kernel and start-up
- 16 s hardware watchdog from the earliest start-up
- Boot failures shown on screen

Built, to test on the device:
- Device-tree changes applied by our kernel itself, so they ship with each version; TrimUI's boot package unmodified
- Crystaline OS boot logo
- Recovery menu: hold MENU at power-on (or after a failed start): start the previous version, install an update from the card, power off
- Crash records (pstore) on the SD card or eMMC, whichever the system runs from, saved to `/system/logs/crash-*/` at the next start

TODO:
- After the crash-record device test: hang detection (soft lockup panic, 10 s threshold) so hangs leave records too

### Updates

Completed:
- Single command update `make update-device`
- Live system running from SD
- Installable to internal storage

Built, to test on the device (needs a newly written card: the layout changed):
- Two boot slots (A/B), switched through U-Boot's two settings copies, so a power cut during an update never leaves the device unbootable
- Signed update files (Ed25519), installed from the SD card (`brick-install update`) or the recovery menu; older versions allowed with a warning; previous version kept and startable
- Restore TrimUI's system from the installed system (prepared there, finished from the card); restore now checks the battery
- GitHub Actions release workflow (tags `v0.YYYY.MM.DD`): SD-card image, signed update file and checksums in a draft release

TODO:
- Generate the offline release key; set up the `release` environment, its secret and `TRIMUI_FW_URL`; run the workflow once on `main` to fill the caches

### Userspace

Completed:
- `padbridge` (see Input)
- `brick-install`: install to internal storage, with an optional backup of TrimUI's system to the card, and restore; an install or restore cut short is recognised and can simply be run again
- Service manager restarts any service that exits; the frontend falls back to a status screen after 3 failures within a minute
- Services: SSH, USB network link, WebDAV file server, WiFi, Bluetooth and Bluetooth audio, network time, system log
- WiFi networks imported once from a `wpa_supplicant.conf` on the card

Built, to test on the device:
- WebDAV runs only while Specular's file-transfer screen is open, as an unprivileged user
- Fixed: the file server couldn't listen as that user (the vendor kernel let only root and an Android group create network sockets; that restriction is now off)
- Our own browser page for uploading and downloading games, saves and BIOS (uploads go to a temporary name first)

### Development and Debugging

Completed:
- SSH (key only) over the USB network link or WiFi
- Serial console
- Developer layer: a writable layer over the read-only system, kept until the next update
- Replace and restart Specular on the device in one command, or run a build once in the foreground
- Installer test harness that runs on the PC against image files
- Start-up logs kept on the system partition, and on a partition a PC can read (survives a reset during start-up)
- Start-up progress codes in a clock-chip register that survives resets
- On-device tools: backlight/panel, GPU test, rumble test, I2C and physical register access, block device read-only switch, deep sleep, overnight power test, hardware status screen
- Kernel: perf events, debugfs, magic SysRq, kernel config at `/proc/config.gz`, symbols, `/dev/mem`, I2C device files
- Kernel slab, mutex and VM debugging off by default
- PC test harnesses: installer and updates (with simulated power cuts), SD card mounting, battery guard, time zone, Bluetooth start-up (simulated chip), device-tree edits, exFAT (virtual machine)

Built, to test on the device:
- `perf`, `gdbserver` and `strace` in development images; `make debug-running-release` copies them (and the hardware test tools) into a running release image's memory
- System log kept across reboots (`/system/logs/messages`, 1 MiB at most), with kernel messages
- Release images (`make system RELEASE=1`): no development key, no serial login, per-device host keys, SSH off unless switched on with keys imported on the device (`brick-ssh`)

TODO:
- Test the USB network link on Windows and macOS; add RNDIS only if one of them needs it

## V1

Goals: 
- Brick-specific code compartmentalized

### Code

TODO:
- Pull out all Allwinner-specific implementations (display, audio, WiFi, deep sleep, GPU libraries, etc) and configs into a separate crystaline-allwinner repo -> submodule
- Pull out all Brick-specific kernel code and configs into a separate crystaline-brick repo -> submodule
- Investigate existing A133 display and open-GPU work (PocketForge? That projects seems dead though), before starting the kernel evaluation below
- Evaluate Allwinner's 5.15 BSP as the kernel base (it has this chip's codec, display and XR829 drivers; no GPU kernel driver, none of our panels)

### Display

TODO:
- Check the other four panel controllers. Units ship with one of five (U-Boot detects which and passes `lcd=`); our driver has all five start-up tables, but only `jd9168` has run on real hardware

### Storage

TODO:
- File transfer over a USB cable (MTP or USB mass storage), once there is a safe way to hand the SD card to a PC: either can race with the system's own writes and corrupt the card
- USB drives plugged into either port: when to mount them and safe removal; decide once there's a use (e.g. games on a drive)

### USB

TODO:
- USB audio output (gaming headset dongles, USB-C DACs): kernel driver present, needs a third sound output in Specular

### Power and Battery

TODO:
- Test the 90 °C shutdown
- Charging while powered off: check on a charger from power-off
- Check that a powered-off device draws nothing (stock had a fault that drained and heated the battery when off), by comparing the power chip's registers after our power-off with stock's, and checking the battery after a day off

### Wireless

TODO:
- Bluetooth codecs beyond SBC: aptX / aptX HD, AAC, LDAC (check each library's licence and encoding cost)
- Measure current with the Bluetooth adapter on and off; if it matters, stop and power down the Bluetooth side when Bluetooth is off
- WiFi access point mode (the XR829 offers a second interface), e.g. for file transfer without a router

### Audio

TODO:
- Microphone: the codec has inputs and stock enables them, but nothing records; find which input it is on, by recording with only MIC1's boost on, then only MIC2's, with and without "MainMic Bias"

### Updates

TODO:
- OTA Updates from Github Releases
- Automatic rollback: fall back to the previous version after failed starts (V0 recovers by hand: the recovery menu, or an SD card when the kernel dies before the menu)

### Development and Debugging

TODO:
- Harden release kernels: `/dev/mem`, debugfs, magic SysRq and kernel symbols are on in release images too, because both kinds of image share one kernel
- Keep debug symbols for CI-built releases (Buildroot's staging files and our unstripped programs), so a release can be debugged with symbols
