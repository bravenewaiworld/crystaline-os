# Power

Status: In progress · Updated: 2026-10-18

Everything that decides how long the TrimUI Brick runs on a charge: the power chip (X-Powers AXP2202) and the separate CPU voltage regulator (TCS4838), the battery gauge and charger, CPU speed and its voltages, thermal limits, deep sleep, the system clock that survives sleep, and how we measure drain. Battery life is one of the project's goals, and most of it is decided here and by the display's idle behaviour ([display.md](display.md)).

## Decisions

- **AXP2202 battery and USB-input drivers ported from Allwinner's BSP, reduced to standard read-only properties** (2026-10-11). Ported from Radxa's public BSP (the same driver family TrimUI runs), reading the battery settings already in TrimUI's device tree. Rejected: the vendor drivers as they are (custom sysfs files, and writes with side effects: a write to the battery status stopped charging, and a charge-limit control would appear as a thermal cooling device whose level 0 stops charging); mainline's AXP717 drivers (the same chip, but they need a mainline kernel and have no gauge-model upload).
- **Input current limit from the chip's stored charger detection at boot** (2026-10-11). The power chip applies its USB charger detection (BC1.2) to the input limit only on plug-in, so a device booted already plugged in kept the bootloader's 500 mA; the detection can't be re-run from software, so the driver applies the stored result at probe.
- **CPU regulator through the standard `fan53555` driver** (2026-10-10). The TCS4838 is register-compatible with the Silergy SYR827. Rejected: TrimUI's own TCS4838 driver (not in any source we have).
- **The A133P's "c0" speed bin in `sun50i-cpufreq-nvmem`** (2026-10-10). The chip reports speed 0x8000, which TrimUI's kernel maps to the c0 voltage column; without the rule the driver would pick a column with the wrong voltages, and TrimUI's tree lacks the `bin_ext` cell the driver required, so the CPU never scaled.
- **Switching regulators in automatic mode** (2026-10-12). TCS4838 and AXP2202 DC-DC 1 and 2 leave forced PWM (always switching at full rate), which the bootloader sets: 17 % less drain at idle with the screen on, stable through 30 min of full CPU and GPU load at 2 GHz. Rejected: forced PWM (no measured benefit).
- **`ondemand` governor, 408–2000 MHz** (2026-10-12). Rejected: `schedutil` (held 1.2–1.6 GHz at idle against 0.4–0.8 GHz, and tripled rescheduling interrupts); stock's 1.2 GHz floor.
- **Thermal limits as stock** (2026-10-11): CPU slows from 58 °C and 63 °C, shutdown at 90 °C. No reason found to differ.
- **Deep sleep through TrimUI's firmware, as stock's kernel is configured** (2026-10-11). The kernel suspends through PSCI `SYSTEM_SUSPEND` into TrimUI's TF-A and the "arisc" power-management firmware, without Allwinner's `SUNXI_SUSPEND` path. Rejected: suspend-to-idle (rails and clocks stay up; the only option without the arisc firmware, since crust has no A133 support).
- **Panel 3.3 V switched with the panel; 1.8 V I/O rail always on** (2026-10-13). CLDO4 feeds only the panel, so the panel driver cuts it with the screen and in sleep; CLDO1 also feeds the eMMC's I/O and the codec. Rumble's BLDO3 is powered only while rumbling (2026-10-11).
- **Clock: the kernel's own clock-chip handling plus `ntpd` while there is a network** (2026-10-14). `ntpd` waits for a default route (checking every 30 s) instead of failing and logging every few seconds while WiFi is off.
- **The battery driver reports the gauge's own level, without smoothing of its own** (2026-10-18). The gauge already smooths; the driver's extra smoothing (below, in register 0x0c) once lagged the gauge by 40 %. Not done yet. Rejected: keeping it and finding what else writes register 0x0c.

## Design

**Chips.** The AXP2202 (I2C 0x34 on S_TWI0, pins PL0/PL1; interrupt through the NMI controller) has the rails, battery charger and gauge, USB-C detection and the power key. The TCS4838 (0x41, same bus) powers the CPUs. Drivers: `axp2101` core (rails, power key), `axp2202_battery`, `axp2202_usb_power`, `fan53555`.

**Rails** (live values; "?" = consumer not confirmed):

| Rail | Voltage | Feeds | Our handling |
|---|---|---|---|
| TCS4838 | 0.9–1.25 V | CPUs | per CPU speed; automatic mode |
| DCDC1 | 0.94 V | nothing in the tree; SoC or GPU? | automatic mode |
| DCDC2 | 0.90 V | nothing in the tree; ? | automatic mode |
| DCDC3 | 1.2 V | DRAM? | on |
| ALDO2 | 3.5 V | port E (LED data, anti-clone chip) | on |
| ALDO3 | 3.3 V | port L | on |
| ALDO4 | 1.8 V | codec analog | on |
| BLDO1 | 3.3 V | XR829 WiFi/Bluetooth | its driver |
| BLDO2 | 1.8 V | nothing in the tree; port G (WiFi SDIO/UART)? | on |
| BLDO3 | 2.0–3.3 V | rumble motor (voltage = strength) | only while rumbling |
| CLDO1 | 1.8 V | panel I/O, eMMC I/O, codec | always on |
| CLDO3 | 3.3 V | main 3.3 V (SD card, USB, eMMC) | on |
| CLDO4 | 3.3 V | panel | with the panel |
| CPUSLDO | 0.9 V | always-on domain | on |
| Boost | 5.1 V | bottom USB-C port as host | in host role ([usb.md](usb.md)) |
| PL8 switch | 5 V | top USB-C port | off in sleep |
| PD11 switch | 5 V | LEDs | LED driver; off in sleep |
| ALDO1, BLDO4, DCDC4, CLDO2 | – | unused | off |

**Device tree changes** (`dt-tweaks.sh`, power part, written as the equivalent source):

```dts
tcs@41 {
	compatible = "ti,tcs4838", "silergy,syr827";	/* U-Boot looks for the first */
	regulator-name = "vdd-cpu";
	regulator-min-microvolt = <712500>;
	regulator-max-microvolt = <1500000>;
	fcs,suspend-voltage-selector = <1>;	/* fan53555 then writes VSEL0, the one in effect */
	regulator-initial-mode = <2>;		/* REGULATOR_MODE_NORMAL: automatic */
};
cpu@0 { cpu-supply = <&tcs0>; };
dcdc1 { x-powers,dcdc-workmode = <0>; };	/* 0 = automatic; anything else = forced PWM */
dcdc2 { x-powers,dcdc-workmode = <0>; };
cldo1 { regulator-always-on; };
usb_power_supply { pmu_bc12_en = <1>; };	/* chip sets the input limit from charger type */
```

**Battery reporting** (`/sys/class/power_supply/axp2202-battery`, `axp2202-usb`; standard properties only). The gauge needs a 128-byte battery model (in TrimUI's device tree); the driver uploads it only when the chip's "model loaded" flag is clear, since both survive reboots while the chip stays powered. If at boot the gauge claims over 60 % with the battery under 3.5 V while charging, the driver restarts the gauge and reports a level that climbs slowly from 1 % ("smoothing"), kept in chip register 0x0c (bit 7 active, bits 6:0 level) across reboots; at 3.5 V or more it cancels any smoothing left over.

**Sleep.** Specular decides when (after 30 s untouched, never during a running game, or a tap on the power button) and calls `sleepnow`, which stops WiFi (its driver refuses to suspend while connected), optionally sets the clock chip's alarm, and writes `mem` to `/sys/power/state`. Drivers turn off what they own: panel (display-off, sleep-in, CLDO4), LEDs' 5 V, rumble, speaker amplifier, both USB ports, WiFi chip (power-cycled); Bluetooth is brought down. The arisc firmware then decides the remaining rails from the device tree's `standby_param` (`vdd-cpu` 1, `vdd-sys` 2, `vcc-pll` 0x80, `osc24m-on` 1) and keeps the 24 MHz oscillator running. The power key (through the power chip's interrupt) and the clock chip's alarm wake it.

**Clock.** The SoC's own real-time clock (`rtc0`, `RTC_DRV_SUNXI`). The kernel sets the system time from it at boot (`CONFIG_RTC_HCTOSYS`) and copies the system time back while it is network-synchronised (`CONFIG_RTC_SYSTOHC`); BusyBox `ntpd -n -p pool.ntp.org` runs as a service whenever a default route exists.

**Measuring.** The gauge reports whole percent only (about 30 mAh) and no discharge current, so drain is measured over long phases. `powertest` runs an unattended sequence (deep sleep, idle screen-on with base and tuned settings, screen off, full load), logging battery, temperatures, CPU speed, interrupts, idle-state residency and per-process wakeups to the SD card.

## Findings

- (2026-10-10, device) The AXP2202's registers match mainline's AXP717 layout exactly (chip-ID register 0x03 reads 0xff); Allwinner's AXP2202 is X-Powers' AXP717, as Andre Przywara also reported.
- (2026-10-10, device) TCS4838: ID1 = 0x88 → die 8, which `fan53555` treats as SYR82X (12.5 mV steps). VSEL0 is in effect; VSEL1 holds a 1.0 V suspend setting, output off.
- (2026-10-10, bsp) The BSP's AXP2202 regulator and power-key cells were named so their drivers never bound: no rail was managed and the power key was missing. Its BLDO4/CLDO1–4 ranges were also wrong (0.5–1.4 V; the part does 0.5–3.5 V in 100 mV steps, PocketForge's fix). Source: linux 3d3862beb, 49f60224e.
- (2026-10-12, bsp) The vendor regulator driver's work-mode setter read the regulator's delay data as the PMIC, so forced-PWM/automatic settings never worked for any AXP variant. Source: linux a2f8d4029.
- (2026-10-10, device) Stock charger: 4.2 V target, 960 mA charge, 128 mA pre-charge (the tree asks 450 mA, not applied), 128 mA termination, input limit 500 mA ("PC" detection), power-off at 3.2 V, JEITA on. Battery 3000 mAh, 147 mΩ.
- (2026-10-11, device) With charger detection on, a USB-C charger or dock reports "DCP" and the chip sets a 3000 mA input limit itself; with nothing connected the limit reads 2000 mA. The stored detection result (0x05) is read-only and can't be re-run. Source: tests with a dock, a MacBook charger and a drive.
- (2026-10-10, device) CPU speed bin c0. Speeds and voltages (MHz @ mV): 408–1008 @ 900, 1200 @ 937.5, 1416 @ 1020, 1608 @ 1100, 1800 @ 1180, 2000 @ 1250. TrimUI sells the A133P as 1.8 GHz but enables 2.0 GHz; mainline's table stops at 1.464 GHz.
- (2026-10-10, stock) Stock CPU policy: `ondemand`, with a 1.2 GHz floor while TrimUI's menu runs and 408 MHz once a game starts (`preload.sh`); its function-key editor offers performance (2.0 GHz fixed), power-save (1.0–1.2 GHz) and balanced modes. Stock never enters cluster sleep.
- (2026-10-10, stock) Stock's idle sequence: dim after a set time, screen off (backlight 0, WiFi stopped) 60 s later, suspend 10 s after that unless `/tmp/stay_alive` exists. Below 10 % it shows warnings and the LED driver dims the LEDs from 15 %; at 1 % it powers off. On the unit we snapshotted (on a cable) suspend counts were all 0 with a `usb_connecting` wakelock held.
- (2026-10-10, stock) Thermal: CPU zone trips 58 °C and 63 °C (passive), 90 °C (critical); the GPU zone has none.
- (2026-10-10, device) The SoC's 32 kHz clock is derived from the 24 MHz oscillator (no external 32 kHz crystal in use), so sleep must keep the 24 MHz oscillator running.
- (2026-10-11, device) Deep sleep works on our kernel with stock's configuration: secondary CPUs off, RTC alarm and power key wake. Source: tools/device/sleepnow.
- (2026-10-12, device) Drain (gauge 1 % ≈ 30 mAh, ±1 % per phase): deep sleep 1.0 %/h; idle with the screen on 12.1 %/h base, 10.0 %/h tuned; screen off and frontend stopped 6.0 %/h (so panel, backlight and frontend ≈ 4 %/h ≈ 120 mA); full load 38–41 %/h (≈1.2 A). Load phases aren't comparable with each other (one reached 2 GHz, the other started hotter and held 1.6 GHz). TrimUI quotes "up to 5 hours".
- (2026-10-12, device) Wakeups at idle with the screen on: display vsync 60/s, timer 40–60/s, WiFi (SDIO ~20/s, driver thread ~33/s), RCU 15/s. The power-chip I2C traffic is only the status screen's and the sampler's reads (0/s with the frontend stopped).
- (2026-10-12, device) The battery driver once reported 43 % while the gauge read 86 %; after a reboot it reported 86 %. Smoothing (register 0x0c) was active and lagging; our probe sets it only in the case above and logs "resetting gauge", and no log of how it got set survived. Source: linux `axp2202_battery.c`.
- (2026-10-13, device) The first read of some SoC temperature sensors after waking (DDR, sometimes GPU) fails with EAGAIN; userspace reading temperatures must tolerate it.
- (2026-10-13, device) Deep sleep with the regulators in automatic mode: 88 → 81 % in 8 h, → 77 % after 4.4 h more: 0.9 %/h ≈ 27 mA, about 4.5 days from full. Barely different from forced PWM: the regulator modes matter awake, not asleep.
- (2026-10-13, device) `regulator-off-in-suspend` has no effect here: in this kernel only Exynos and Rockchip platform code applies it, and the arisc firmware decides rails from `standby_param`. The gauge's coulomb counter isn't usable (only its high word is exposed; gauge memory reads 0). Source: linux `regulator_suspend_prepare()` callers; register reads on our unit.
- (2026-10, upstream) The AXP717 can't measure discharge current. Stock's power-off left the power chip in a state that drained and heated the battery; NextUI/MinUI fixed it with their own power-off sequence (masking the chip's interrupts, registers 0x40–0x4C, 0x22, 0x27). Source: github.com/Helaas/nextui-brick-poweroff-hook.
- (2026-10-10, device) The power chip's charge-LED output is disabled on stock (register 0x70 = 0), and the device tree has `pmu_chgled_func = 0`, so our battery driver leaves it alone too. Yet the power key's charging light works on our system (red while charging, green when charged, 2026-10-18), so something outside our software drives it; see [leds-and-rumble.md](leds-and-rumble.md). Source: linux `axp2202_battery.c`.
