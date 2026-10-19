# Input

Status: Implemented · Updated: 2026-10-18

The TrimUI Brick's buttons, FN slider and power key, and `padbridge`, which turns the buttons into the virtual gamepad that games and frontends expect. Every game's controls go through this path, and software written for TrimUI's stock system looks for TrimUI's exact gamepad, so it has to look the same.

## Decisions

- **The buttons are a standard kernel input device (`gpio-keys`, named "brick-keys"), described by our device-tree changes** (2026-10-10). The pins raise interrupts, so nothing has to poll, and no program needs raw memory access. Rejected: TrimUI's `trimui_inputd`, which reads the pin registers through `/dev/mem` about 120 times a second and keeps the CPU awake to do it; `gpio-keys-polled` (not needed, because ports B, D and H all have interrupts).
- **`padbridge` presents the buttons as TrimUI's virtual gamepad, unchanged** (2026-10-11). It keeps the name "TRIMUI Player1", the Xbox 360 USB IDs and the event layout, so RetroArch, PortMaster ports and SDL's controller database recognise it without changes. It takes the real device for itself (exclusive grab), so apps don't see each press twice. Rejected: letting apps read "brick-keys" directly (it has no gamepad identity, so SDL wouldn't map it).
- **The FN slider is reported as a switch (`SW_TABLET_MODE`), the way stock reports it** (2026-10-10). A slider has a position, not presses. Specular uses it as Mute.
- **The kernel drops repeated axis values again** (2026-10-10). Allwinner's kernel passes every axis value on, even unchanged ones, so each time padbridge resent its full state, every reader woke up. We restored mainline's behaviour, which is safe because the Brick has no accelerometer.
- **Games get rumble through the virtual gamepad.** padbridge forwards force-feedback requests to the motor's device. See [leds-and-rumble.md](leds-and-rumble.md).
- **Only the power key (and the clock alarm) wakes the Brick from sleep** (2026-10-18), so nothing pressed in a bag or pocket wakes it by accident. Rejected: waking on any button; a setting for it.
- **Beyond the gamepad identity above, apps written for TrimUI's stock system (e.g. PortMaster ports) are out of scope for now** (2026-10-18): no further compatibility shims until running them is a goal. The input interfaces such apps would need, which padbridge leaves out, are trimui_inputd's `dpad2axis_hold_*` options, its rotated table (`/var/trimui_inputd/rotate_270`) and `grab`.

## Design

```
button pins ──► gpio-keys "brick-keys" ──(exclusive grab)──► padbridge ──► uinput "TRIMUI Player1" ──► Specular, games
                                                               │    ▲ rumble requests from games
                                                               └────┴──► "regulator-haptic" motor device
power chip  ──► "axp2202-pek" (KEY_POWER) ─────────────────────────────────────────────────────────► Specular
```

`system/board/brick/dt-tweaks.sh` creates "brick-keys". Every button is active-low and has an external pull-up. padbridge then maps each code onto the virtual gamepad:

| Button (label, position) | Pin | brick-keys code | Virtual gamepad |
|---|---|---|---|
| B, bottom | PD13 | `BTN_SOUTH` | `BTN_SOUTH` (Xbox A) |
| A, right | PD12 | `BTN_EAST` | `BTN_EAST` (Xbox B) |
| X, top | PD18 | `BTN_NORTH` | 0x134 (Xbox Y) |
| Y, left | PD19 | `BTN_WEST` | 0x133 (Xbox X) |
| D-pad up / down / left / right | PD17 / PD14 / PD15 / PD16 | `BTN_DPAD_*` | hat `ABS_HAT0X/Y` −1..1, or the left stick (see options) |
| L1 / R1 | PB4 / PH17 | `BTN_TL` / `BTN_TR` | same |
| L2 / R2 | PB2 / PB5 | `BTN_TL2` / `BTN_TR2` | trigger axes `ABS_Z` / `ABS_RZ`, 0 or 255 |
| SELECT / START | PH15 / PH16 | `BTN_SELECT` / `BTN_START` | same |
| MENU | PH14 | `BTN_MODE` | same |
| F1 / F2 | PH12 / PH13 | `BTN_TRIGGER_HAPPY1/2` | `BTN_THUMBL` / `BTN_THUMBR` |
| VOL+ / VOL− | PD21 / PD20 | `KEY_VOLUMEUP/DOWN` | same |
| FN slider | PH19 | switch `SW_TABLET_MODE` | same |
| Power | power chip | `KEY_POWER` on "axp2202-pek" | not on the gamepad |

The mapping table in `padbridge.c`:

```c
enum kind { KEY, TRIGGER, DPAD };
struct mapping {
	unsigned short in;   /* brick-keys code */
	enum kind kind;
	unsigned short out;  /* KEY: gamepad key code; TRIGGER: ABS_Z/ABS_RZ; DPAD: UP..RIGHT */
	const char *turbo;   /* option file that turns on auto-fire for this button, or NULL */
};
/* Virtual gamepad: "TRIMUI Player1", bus USB, 045e:028e, version 0x0114 (Xbox 360).
 * It also declares ABS_RX/ABS_RY and KEY_F1/KEY_F2, as trimui_inputd does, but never sends them.
 * It always declares EV_FF/FF_RUMBLE (16 effects), whether or not the motor's device exists. */
```

Runtime switch files. These are trimui_inputd's own, kept for software written for stock. Specular doesn't use them.

```
/tmp/trimui_inputd/           an option is on while its file exists; padbridge re-reads them every second
  turbo_{a,b,x,y,l,r,l2,r2}   auto-fire that button while held, about 15 presses a second (Brick labels: a = right)
  input_no_dpad               the D-pad is not reported
  input_dpad_to_joystick      the D-pad is reported as the left stick (ABS_X/ABS_Y ±32767), not the hat
```

Behaviour worth knowing:
- padbridge sends the gamepad's full state whenever anything changes, and the kernel passes on only the values that changed. After the kernel reports dropped events (`SYN_DROPPED`), it reads the buttons' state again.
- On any error, such as "brick-keys" disappearing, it exits. The service supervisor (`/etc/sv/padbridge`) then restarts it. Rumble errors are the exception: a missing motor only makes rumble fail ([leds-and-rumble.md](leds-and-rumble.md)).
- The power key is a separate device. Specular reads both "TRIMUI Player1" and "axp2202-pek". The power chip turns the device off by itself if the key is held for 10 s.

## Findings

- (2026-10-10, stock) Every button except power is a plain GPIO on ports B, D or H. None of them is in TrimUI's device tree. `trimui_inputd` sets the pins as inputs, sets no pull, and reads them through `/dev/mem` every 8.3 ms (a pin reading 0 means pressed).
- (2026-10-10, device) The button pins idle high with no internal pull, so the pull-ups are on the board. Stock's input devices are `axp2202-pek`, the codec's headphone jack, an unused `sunxi-keyboard` (resistor-ladder buttons, 0 interrupts) and trimui_inputd's virtual gamepad.
- (2026-10-10, stock) trimui_inputd's gamepad is "TRIMUI Player1", 045e:028e. F1 and F2 are sent as `BTN_THUMBL`/`BTN_THUMBR`. The FN slider is read every second from sysfs GPIO 243 (PH19) and sent as `SW_TABLET_MODE`. It also has an A/B-swapped table and a rotated one (`/var/trimui_inputd/rotate_270`), plus the options `dpad2axis_hold_*`, `grab` and `/tmp/system_suspend`, which padbridge does not implement.
- (2026-10-10, stock) The vendor device tree claims some button pins for other things. The power chip's USB node names PH12 and PH13 (F1 and F2), and the board config enables JTAG on PH9–PH12. Our device tree claims these pins for the buttons.
- (2026-10-10, stock) The power key is the power chip's key input: 1.5 s counts as a long press, 10 s forces power-off, and both press and release can wake the device.
- (2026-10-10, upstream) The kernel's gamepad codes go by position: 0x133 (`BTN_NORTH`) is the top button. SDL's Xbox mapping reads 0x133 as X (left) and 0x134 as Y (top). That's why padbridge swaps those two codes. Source: `userspace/padbridge/padbridge.c`, Linux `Documentation/input/gamepad.rst`.
- (2026-10-10, bsp) Allwinner's input core passes repeated axis values on to readers, for accelerometer drivers. Source: kernel commit f0a5642dd.
