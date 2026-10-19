# LEDs and rumble

Status: Implemented · Updated: 2026-10-18

The TrimUI Brick's 14 RGB LEDs and its vibration motor. TrimUI drives both through its own kernel files (an LED animation engine, a motor voltage file and GPIO writes). We present them through standard kernel interfaces instead: LED-class entries for the frontend, and force feedback that games can use.

## Decisions

- **The LEDs are standard LED-class entries, one per colour channel; effects and colours are the frontend's job** (2026-10-11). Rejected: TrimUI's `led_anim` animation engine, which keeps zones, effects and low-battery behaviour in the kernel. Its source isn't public (we know it only from disassembly), and it adds a kernel thread that wakes up to render effects.
- **The device tree states the chain length (14) and which LEDs take red and green swapped** (2026-10-11). The vendor tree says 23, and each LED chip family expects its colours in its own order (`swap-rg-leds` 0–9).
- **A 300 µs reset gap after each frame** (2026-10-14). The LEDs only apply a frame after an idle gap. The vendor tree's 84 ns gap is far too short, so back-to-back writes merged into one long frame and colours landed on later LEDs.
- **The LED driver owns the LEDs' 5 V supply (PD11, a fixed regulator)** (2026-10-11). It switches the supply on at start-up and off in sleep and shutdown. Rejected: driving the pin from a script (the driver then disabled a supply it had never enabled at the first sleep).
- **Rumble is a standard force-feedback device (`regulator-haptic`), forwarded to games by padbridge** (2026-10-11). Strength is set by the motor's supply voltage (power chip rail BLDO3), and PH3 switches the motor. The range is stock's, 2.0–3.5 V (2026-10-18; today's top is still 3.3 V, BLDO3's boot value, kept for no recorded reason). We added an optional enable pin to the driver for PH3. Rejected: `gpio-vibrator` (on/off only, no strength); `pwm-vibrator` (PH3 has no PWM function); TrimUI's `/sys/class/motor/voltage` plus a GPIO write (no game can use it).
- **The virtual gamepad always offers rumble; padbridge opens the motor's device when a game first uses it** (2026-10-18). Games and SDL decide once, when they open the gamepad, whether it can rumble, so offering it only if the motor existed when padbridge started would lose rumble for good after one failed motor start. While the motor's device is missing, uploads fail with EIO, it is looked for again at most once a second, and the absence is logged once. Rejected: ENODEV (from an input device it means the device itself is gone; SDL then drops the gamepad); accepting uploads and playing nothing (a missing motor would go unnoticed).
- **After the motor's device is reopened, padbridge uploads each effect again when it is next played** (2026-10-18). Effects belong to the open file, so they vanish with the old one, while the game still holds its ids on the gamepad. padbridge keeps the game's last successful upload of each effect for this. Rejected: dropping them (games keep playing ids they uploaded once, so rumble would stay silent until they upload again).
- **The motor's supply is off except while rumbling** (2026-10-11). The always-on flags on BLDO3 are removed, so the driver powers it only during an effect.
- **Apps that write TrimUI's `/sys/class/led_anim`, `/sys/class/motor` or GPIO 227 are out of scope for now** (2026-10-18), like other apps written for stock ([input.md](input.md)): no compatibility shim.

## Design

LED numbering. The LED controller sends data out on PE5, and the chain starts at LED 0:

```
index  position                        colour order
0–7    top bar, left to right          red/green swapped (swap-rg-leds)
8      F2                              red/green swapped
9      F1                              red/green swapped
10     under L1                        as sent
11     L2                              as sent
12     R2                              as sent
13     R1                              as sent

/sys/class/leds/sunxi_led<index>{r,g,b}/brightness    0–255 per channel (42 entries)
```

- Each brightness write sends the whole chain as one frame. A single lock serialises the frames. After deep sleep the driver sends the stored colours again, because the controller and the LEDs lose them.
- What Specular uses: it writes all 42 entries. The top bar shows its first accent colour, and F1/F2 and the shoulder LEDs show the second. Like stock, it limits brightness to about 40/255 (the LEDs are very bright at full power).
- Device-tree properties (in `system/board/brick/dt-tweaks.sh`): `led_count 14`, `swap-rg-leds 0..9`, `reset_ns 300000`, and `led_regulator "led-5v"`, a `regulator-fixed` on PD11.

Rumble:

```
/brick-rumble   compatible "regulator-haptic"
  haptic-supply  = BLDO3        min-microvolt 2000000, max-microvolt 3300000
  enable-gpios   = PH3, active high      (our addition to the driver)

voltage = 2.0 V + 1.3 V × magnitude / 0xffff    magnitude = strong_magnitude, or weak_magnitude if strong is 0
start: supply on, then PH3 high          stop (magnitude 0): PH3 low, then supply off
```

- Games upload an `FF_RUMBLE` effect to the virtual gamepad and play it. padbridge passes the upload on to the motor's device (found by its name, "regulator-haptic") and maps the gamepad's effect numbers (up to 16) to the motor device's. See [input.md](input.md).
- The driver stops the motor when the last program holding its device closes it. padbridge keeps it open from the first rumble request on, until a request fails with ENODEV (the device is gone).
- `rumble [strength 0–100 [ms [device]]]` plays one effect, for testing.

## Findings

- (2026-10-11, stock) There are 14 LEDs, not 23. The chain order above comes from TrimUI's `led_anim` (`commit_static_frame`). With the generic G-R-B packing, LEDs 0–9 need red and green swapped. Source: checked on the device.
- (2026-10-11, device) With every LED set to red only, the front LEDs lit green and the back LEDs red. This showed that the chain mixes two colour orders.
- (2026-10-10, device) The timings in effect, after the BSP's rounding (n+1)×42 ns: T1H 798, T1L 420, T0H 378, T0L 840 ns. Port E runs at 3.5 V (rail ALDO2).
- (2026-10-14, device) With the 84 ns reset gap, buttons showed random colours and some LEDs stayed lit. 300 µs fixed it. Source: commit 8fe03ce.
- (2026-10-11, stock) TrimUI's `led_anim` has the zones m (top bar), l, r, lr, f1 and f2, and the effects 0 disable, 1 linear, 2 breath, 3 sniff, 4 static, 5–7 blink1–3. It caps brightness per zone ((c×cap)>>8; its render thread sets the top cap to 14) and clamps every cap to 3 at ≤15 % battery. The same driver provides `/sys/class/motor/voltage` and `/sys/class/speaker/mute`. Software that writes these paths does nothing on Crystaline OS.
- (2026-10-10, stock) Stock's start-up script calls PD11 "VCC-5v", so it may feed more than the LEDs.
- (2026-10-10, stock) The power key's charging light isn't on the LED controller. It is probably the power chip's own charge-LED pin, run by the charger (vendor tree: `pmu_chgled_func = 0`, `pmu_chgled_type = 0`). Our battery driver programs that pin only when `pmu_chgled_func` is set, so it stays as the bootloader left it. Source: `axp2202_battery.c`.
- (2026-10-18, device) The power key's charging light works on our system: red while charging, green when charged. What drives it is unconfirmed (most likely the charger itself, as above).
- (2026-10-10, upstream) Mainline's `leds-sun50i-a100` driver drives the same LED controller, with one `multi-led` child per chain index.
- (2026-10-10, stock) Stock switches the motor with sysfs GPIO 227 (PH3) and sets its strength in `/sys/class/motor/voltage`: levels 1–5 are 2.0, 2.5, 3.0, 3.3 and 3.5 V. Its virtual gamepad has no force feedback, so only TrimUI's UI ever rumbles.
- (2026-10-10, stock) A vendor-tree node for an infrared transmitter (`ir1`, enabled) claims PH3, the motor pin, and must stay off. The vendor `sunxi_motor` driver is built in but has no device-tree node, so it does nothing.
- (2026-10-13, device) In deep sleep the LEDs' 5 V supply and the motor's supply are both off.
- (2026-10-18, device) The motor's device is there before any service starts: `regulator-haptic`, the power chip's driver and its regulators are built into the kernel, not modules, and the motor registers as input1, before the power key. If its probe has to wait for BLDO3, the kernel retries it before starting `/sbin/init`. So it is missing only if its probe fails (BLDO3 or PH3 unavailable, e.g. a device-tree change or the vendor IR node claiming PH3 again) or someone unbinds it.
- (2026-10-18, upstream) A uinput force-feedback upload blocks the game until the uinput program answers (Linux 4.9 waits without a time limit), and whatever error the answer carries is what the game's `EVIOCSFF` returns. A gamepad without `EV_FF` fails uploads with ENOSYS. SDL's Linux joystick code checks once, when it opens the gamepad, whether it can rumble; it retries a failed upload once as a new effect and then reports an error whatever the errno; and it marks a joystick as unplugged when it sees ENODEV. Source: `linux/drivers/input/misc/uinput.c`, `linux/drivers/input/ff-core.c`, SDL 3 `src/joystick/linux/SDL_sysjoystick.c`.
