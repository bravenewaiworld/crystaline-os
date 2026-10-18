# Crystaline OS Roadmap

## V0

Goals: 
- Full compatibility with all of the TrimUI Brick hardware
- Optimized power consumption
- Available compute fully leveraged

### Display

Completed:
- Panel image display
- Backlight
- Panel off/on
- `FBIO_WAITFORVSYNC` on `/dev/fb0` waits for the next frame

TODO:
- Check the other four panel controllers. Units ship with one of five (U-Boot detects which and passes `lcd=`); our driver has all five start-up tables, but only `jd9168` has run on real hardware
- Stop the display's 60-per-second interrupt while nothing is drawn, so the CPUs reach their deepest idle state: try masking it between flips, after checking what in `disp2` depends on it
- Run the panel at the game's own refresh rate (e.g. 50 Hz for PAL), and lower it for menus and still screens: try changing the vertical total on the live JD9168 first, then the pixel clock
- Colour (gamma) table as stock sets it: compare the display engine's gamma registers on stock and ours
- Decide which unused display and video hardware is worth using: spare display layers and scaler, the 2D blitter (G2D), the video decoder; whether they can scale and place game frames instead of the GPU

### GPU

Completed:
- TrimUI's closed PowerVR GE8300 driver (DDK 1.19), kernel module rebuilt from source; userspace EGL/GLES libraries taken from the stock firmware
- 60 fps, locked to vsync
- Fixed: deadlock between the GPU's display module (`dc_sunxi`) and the framebuffer code (opposite lock order) that hung the display and suspend
- Fixed: `FBIO_WAITFORVSYNC` no longer waits on the framebuffer lock, which a page flip holds (a vsync-paced game beside the UI ran at ~40 fps)
- Kernel slab debugging off by default (cost a game's render thread ~12 % in `drm_ioctl`)

TODO:
- Each GPU app run leaves an idle `pvr_misr` kernel thread behind: find where the workqueue is created and whether process teardown destroys it
- Find the GPU's supply rail and actual voltage at 702 MHz, by watching each rail's register while changing the GPU clock
- GPU frequency/power profiles: find why stock rejects the 399 and 228 MHz points (`sunxi_decide_pll`), and whether lower clocks need lower voltage
- GPU thermal zone has no trip points: find safe GPU temperature limits before adding them

### CPU

Completed:
- Frequency scaling 408–2000 MHz with the chip's speed-bin voltages, all governors
- `ondemand` governor by default (`schedutil` held higher speeds at idle)

TODO:
- Decide whether to keep the 2.0 GHz step, by a long full-load run at 2.0 GHz with temperature logging; keep it if stable
- CPU performance/power profiles (see Power)

### Input

Completed:
- Buttons, FN switch and power key as standard input devices
- `padbridge`: presents the buttons as a standard gamepad (Xbox 360 layout, triggers as axes, D-pad as hat), forwards rumble to the motor; FN switch passed through (Specular uses it as Mute)

TODO:
- Rumble is only offered if the motor is present when `padbridge` starts

### Storage

Completed:
- SD card at its fastest mode (UHS SDR104, 150 MHz, 1.8 V), survives deep sleep
- Data partition (FAT32) created on first boot over the rest of the card, mounted with case-insensitive file names, as on a PC
- Read-only system partition (versioned squashfs images) plus the SD card's data partition
- Internal storage (eMMC) at stock settings (DDR52, 50 MHz)

TODO:
- exFAT data cards (most cards over 32 GB): backport mainline's exFAT driver and stress-test it against power cuts

### USB

Completed:
- Bottom USB-C port switches role by itself: device mode (network link to a PC) with a computer or charger, host with 5 V for USB devices, off when unplugged; cable and charger type readable
- Top USB-C port: host, 5 V always on

TODO:
- USB audio output (gaming headset dongles, USB-C DACs): kernel driver present, needs a third sound output in Specular
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

TODO:
- Find what draws ~27 mA in deep sleep (candidates: DRAM self-refresh, the always-on domain, rails the sleep firmware keeps on, the SD card, the WiFi/Bluetooth chip's supply), by a stock-firmware sleep test or a USB power meter on the charge port (the gauge's coulomb counter isn't usable)
- Turn off unused clocks; LEDs' 5 V supply stays on while awake even with every LED dark
- Display refresh and interrupt savings (see Display)
- Power policy: CPU/GPU profiles, screen dimming and off, low-battery autosave and shutdown, top USB-C port 5 V while awake
- Power-saving mode: lower CPU/GPU limits, dimmer screen, WiFi and Bluetooth off when unused, LEDs off, lower refresh rate
- Drop the battery driver's level smoothing and report the gauge's own level (the smoothing once lagged the gauge by 40 %)
- Test the 90 °C shutdown
- Charging while powered off: check on a charger from power-off
- Check that a powered-off device draws nothing (stock had a fault that drained and heated the battery when off), by comparing the power chip's registers after our power-off with stock's, and checking the battery after a day off

### Wireless

Completed:
- WiFi (XR829, 2.4 GHz), stable MAC address; On/Off/Auto (driven by Specular)
- Bluetooth audio (SBC): pairing, automatic reconnection, pairings and the Bluetooth address kept across reboots
- Sleep with WiFi connected (WiFi is stopped before sleep and restarted after; its driver refuses to suspend while connected)

TODO:
- ~5 s of 20–25 fps after waking while the WiFi firmware reloads (floods the SDIO bus): find the cause by tracing the first seconds after waking with interrupt latencies (serial console bursts vs interrupts held up on CPU0)
- Seen once: after waking, screen updates waited two vsyncs (25–50 fps) until WiFi was restarted again
- Bluetooth codecs beyond SBC: aptX / aptX HD, AAC, LDAC (check each library's licence and encoding cost)
- Bluetooth audio latency: shrink our buffers, log the headset's reported delay
- Read the Bluetooth controller's HCI version (`btmgmt info`) and check the XR829 datasheet for LE Audio
- Derive the Bluetooth address from the chip ID
- Measure current with the Bluetooth adapter on and off; if it matters, stop and power down the Bluetooth side when Bluetooth is off
- Replace TrimUI's binary `hciattach` (Bluetooth start-up) with source
- WiFi access point mode (the XR829 offers a second interface), e.g. for file transfer without a router

### Audio

Completed:
- Speaker and headphones; the jack switches between them
- Amplifiers off when idle
- Volume controls in the standard direction; the level is kept across playback starts and sleep

TODO:
- Separate levels for speaker and headphones
- Microphone: the codec has inputs and stock enables them, but nothing records; find which input it is on, by recording with only MIC1's boost on, then only MIC2's, with and without "MainMic Bias"
- Check whether the speakers are wired as stereo, by playing a tone on the left channel only

### LEDs and Rumble

Completed:
- 14 LEDs with correct colours, off in sleep and restored after
- Rumble as standard force feedback; strength as motor voltage, motor supply off when idle

TODO:
- Raise the rumble's top strength to 3.5 V, as stock

### Clock

Completed:
- Clock read from the clock chip at boot; set from network time while WiFi is up, and written back

TODO:
- Check whether the clock survives power-off, by powering off for an hour and comparing with network time
- Time zone setting

### Boot

Completed:
- Boot chain: TrimUI's first-stage loader and U-Boot (with our device tree changes), then our kernel and start-up
- 16 s hardware watchdog from the earliest start-up
- Boot failures shown on screen

### Updates

Completed:
- Single command update `make update-device`
- Live system running from SD
- Installable to internal storage

TODO:
- A power cut while an update writes the boot image leaves that disk unbootable until an SD card repairs it
- Updates from a file on the SD card, and a recovery path that needs no PC; signed update files using the existing version folder and manifest
- Restore TrimUI's system from the installed system: Settings → Internal storage → Restore writes the card's first-stage loader back, restarts from the card and continues the restore there
- Restore doesn't check the battery level, as install does

### Userspace

Completed:
- `padbridge` (see Input)
- `brick-install`: install to internal storage, with an optional backup of TrimUI's system to the card, and restore; an install or restore cut short is recognised and can simply be run again
- Service manager restarts any service that exits; the frontend falls back to a status screen after 3 failures within a minute
- Services: SSH, USB network link, WebDAV file server, WiFi, Bluetooth and Bluetooth audio, network time, system log
- WiFi networks imported once from a `wpa_supplicant.conf` on the card

TODO:
- Crystaline OS boot logo branding
- Ensure SD Card is mounted on start
  - The user folders (`roms/`, `bios/`, …) aren't created on a new card
  - Mounted once at start only: no wait for a slow card, no card inserted later, no removal
  - No FAT check before mounting; a damaged card silently becomes read-only
  - A failed mount is only logged; Specular just shows "No SD card"
- WebDAV file server has no login, and writes files as root
- Our own browser page for uploading and downloading games and saves

### Development and Debugging

Completed:
- SSH (key only) over the USB network link or WiFi
- Serial console
- Developer layer: a writable layer over the read-only system, kept until the next update
- Replace and restart Specular on the device in one command, or run a build once in the foreground
- Installer test harness that runs on the PC against image files
- Start-up logs kept on the system partition, and on a partition a PC can read (survives a reset during start-up)
- Start-up progress codes in a clock-chip register that survives resets
- System log (in memory)
- On-device tools: backlight/panel, GPU test, rumble test, I2C and physical register access, block device read-only switch, deep sleep, overnight power test, hardware status screen
- Kernel: perf events, debugfs, magic SysRq, kernel config at `/proc/config.gz`, symbols, `/dev/mem`, I2C device files
- Kernel slab, mutex and VM debugging off by default

TODO:
- `perf` tool in the image (the kernel side is ready)
- `gdbserver` and `strace` in the image
- Persistent system log (today it is lost on reboot)
- Crash records: kernel crash storage (pstore) is built in but has nowhere to write; add a `pstore` partition to the card and install layouts and point the kernel at it
- Development access (SSH key, passwordless serial login) switched off in release images
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

### Updates

TODO:
- OTA Updates from Github Releases
- Automatic rollback: fall back to the previous version after failed starts (V0 recovers by hand, or with an SD card)

### Storage

TODO:
- File transfer over a USB cable (MTP or USB mass storage), once there is a safe way to hand the SD card to a PC: either can race with the system's own writes and corrupt the card
- USB drives plugged into either port: when to mount them and safe removal; decide once there's a use (e.g. games on a drive)

