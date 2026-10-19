# Power

Status: In progress · Updated: 2026-10-18

Everything that decides how long the TrimUI Brick runs on a charge: the power chip (X-Powers AXP2202) and the separate CPU voltage regulator (TCS4838), the battery gauge and charger, CPU speed and its voltages, thermal limits, deep sleep, the system clock that survives sleep and its time zone, and how we measure drain. Battery life is one of the project's goals, and most of it is decided here and by the display's idle behaviour ([display.md](display.md)).

## Decisions

- **AXP2202 battery and USB-input drivers ported from Allwinner's BSP, reduced to standard read-only properties** (2026-10-11). Ported from Radxa's public BSP (the same driver family TrimUI runs), reading the battery settings already in TrimUI's device tree. Rejected: the vendor drivers as they are (custom sysfs files, and writes with side effects: a write to the battery status stopped charging, and a charge-limit control would appear as a thermal cooling device whose level 0 stops charging); mainline's AXP717 drivers (the same chip, but they need a mainline kernel and have no gauge-model upload).
- **Input current limit from the chip's stored charger detection at boot** (2026-10-11). The power chip applies its USB charger detection (BC1.2) to the input limit only on plug-in, so a device booted already plugged in kept the bootloader's 500 mA; the detection can't be re-run from software, so the driver applies the stored result at probe.
- **CPU regulator through the standard `fan53555` driver** (2026-10-10). The TCS4838 is register-compatible with the Silergy SYR827. Rejected: TrimUI's own TCS4838 driver (not in any source we have).
- **The A133P's "c0" speed bin in `sun50i-cpufreq-nvmem`** (2026-10-10). The chip reports speed 0x8000, which TrimUI's kernel maps to the c0 voltage column; without the rule the driver would pick a column with the wrong voltages, and TrimUI's tree lacks the `bin_ext` cell the driver required, so the CPU never scaled.
- **Switching regulators in automatic mode** (2026-10-12). TCS4838 and AXP2202 DC-DC 1 and 2 leave forced PWM (always switching at full rate), which the bootloader sets: 17 % less drain at idle with the screen on, stable through 30 min of full CPU and GPU load at 2 GHz. Rejected: forced PWM (no measured benefit).
- **`ondemand` governor, 408–2000 MHz** (2026-10-12). Rejected: `schedutil` (held 1.2–1.6 GHz at idle against 0.4–0.8 GHz, and tripled rescheduling interrupts); stock's 1.2 GHz floor.
- **The OS provides the power settings; Specular holds the policy** (2026-10-18). `brick-power` offers CPU profiles and the top USB port's 5 V. Specular chooses between them (per game, or in a power-saving mode), dims and switches off the screen, dims or switches off the LEDs, and warns about the battery. Nothing persists in the OS: start-up applies the balanced profile with the top port on, and Specular applies its choice when it starts, so a bad setting can't outlive a reboot and the policy lives in one place. Rejected: an LED brightness cap in the OS (only Specular drives the LEDs, and it already limits them).
- **CPU profiles: performance 1200–2000 MHz, balanced 408–2000 (the start-up profile), saver 408–1200** (2026-10-18). 1200 MHz is the fastest speed near the lowest voltage (937.5 mV against 900), so performance's floor costs little and spares games slow speed-ups. Energy per cycle goes with the voltage squared: against 1200 MHz, 1416 costs 18 % more and 2000 78 % more, hence saver's cap. Rejected: stock's performance mode, 2.0 GHz fixed (1250 mV even at idle, hot, slowed by the thermal limits); stock's power-save floor of 1.0 GHz; capping balanced at TrimUI's rated 1.8 GHz (20 % less energy per cycle) before the 2.0 GHz stability run decides it.
- **`ondemand` re-evaluates the CPU speed every 50 ms, in every profile** (2026-10-18). Its default here is 2 s: a game starting at 408 MHz could wait 2 s for full speed, and the CPU stayed fast for up to 2 s after the load ended. In this kernel `ondemand` samples only from the scheduler's updates on a busy CPU, so a shorter interval should cost no wake-ups at idle; a device test confirms it before release. Rejected: a value per profile (no reason found).
- **Low battery: Specular saves and quits a game at 3 %; the OS's battery guard powers off at 1 %** (2026-10-18). `battery-guard`, a service, powers off cleanly (rcK: Specular saves) after two samples in a row, 30 s apart, find the battery empty: the gauge at 1 % or less with the voltage at 3.70 V or less, or the voltage at 3.30 V or less whatever the gauge says, and never while the battery receives at least 50 mA of charge current. The voltage check keeps a confused gauge (0–1 % at 3.9 V after a gauge restart) from powering off; the voltage floor covers a gauge that reads too high, above the power chip's own 3.2 V cut-off, which cuts the power with nothing saved. It goes by the charge current rather than the charger's status, because the status says Charging even when a weak cable can't keep up with the load. The levels are first guesses, to be refined from a logged discharge. Rejected: the guard also telling Specular when to save, through a state file (two places deciding about the battery; Specular reads it every 10 s anyway); stock's power-off at 1 % with no voltage check.
- **Asleep, the power chip's low-battery interrupt wakes the device at 1 %, and `sleepnow` powers off** (2026-10-18). Warning level 2 is set to 1 %, the guard's level; TrimUI's device tree already keeps that interrupt on in sleep. The chip's levels go in 1 % steps and the gauge reports whole percent, so the wake can match the guard's level exactly, and 1 % (about 30 mAh) lasts about an hour asleep, time enough to wake and power off. `sleepnow` also powers off instead of sleeping whenever the guard finds the battery empty, before sleeping (the interrupt fires only on the way down) and after waking. Warning level 1 (5 %) doesn't wake the device. Rejected: a wake alarm set from the battery level (needed only if the interrupt turns out not to wake the device); waking at 2 % (needed only if the interrupt fires below its level rather than at it). Caveat: a device put to sleep at 1 % while the guard distrusts the gauge (voltage above 3.70 V), or unplugged while asleep at 1 %, gets no wake.
- **CPU thermal limits as stock** (2026-10-11): slows from 58 °C and 63 °C, shutdown at 90 °C. No reason found to differ. The GPU's critical trip is in [gpu.md](gpu.md).
- **Unused clocks are left running until measuring shows they matter** (2026-10-18). Several run with nothing using them (Findings); each idle PLL probably costs a few mW. If measuring shows a saving, a short list of them is to be switched off through the clock driver, and the hardware video decoder's and resistor-ladder keys' device-tree nodes disabled. Rejected: removing the vendor driver's keep-everything switch (clocks in use with an enable count of 0 would stop and hang the device); register writes from start-up scripts (they bypass the clock driver's lock and leave its view wrong).
- **Deep sleep through TrimUI's firmware, as stock's kernel is configured** (2026-10-11). The kernel suspends through PSCI `SYSTEM_SUSPEND` into TrimUI's TF-A and the "arisc" power-management firmware, without Allwinner's `SUNXI_SUSPEND` path. Rejected: suspend-to-idle (rails and clocks stay up; the only option without the arisc firmware, since crust has no A133 support).
- **Panel 3.3 V switched with the panel; 1.8 V I/O rail always on** (2026-10-13). CLDO4 feeds only the panel, so the panel driver cuts it with the screen and in sleep; CLDO1 also feeds the eMMC's I/O and the codec. Rumble's BLDO3 is powered only while rumbling (2026-10-11).
- **Clock: the kernel's own clock-chip handling plus `ntpd` while there is a network** (2026-10-14). `ntpd` waits for a default route (checking every 30 s) instead of failing and logging every few seconds while WiFi is off.
- **The clocks stay in UTC; the time zone changes only how local time is shown and SD card files are stamped** (2026-10-18). The clock chip, the kernel and `ntpd` all work in UTC, so changing the zone never moves the clock or a sleep alarm. The zone is `/etc/localtime`, which links into the state area, since the root filesystem is read-only. The default is UTC. Rejected: the `TZ` variable (it is set per process, so every program would need restarting).
- **The system only sets the zone it is given; finding it automatically is Specular's** (2026-10-18). `brick-timezone set` is the one way to change it. Rejected: an automatic lookup in the system (a geo-IP request from udhcpc's hook on each new WiFi network): the lookup tells a third party the network's address, so it needs the user's consent, which only Specular can ask for, and Specular then also owns when to look up.
- **File times on the SD card in local time: the kernel's own zone offset follows the zone** (2026-10-18). FAT stores local times without a zone, and PCs read them as their local time. The FAT driver converts with the kernel's zone offset (`sys_tz`) at each conversion, so `brick-timezone kernel` sets it (`hwclock -u --systz`) at start-up before the card is mounted, on `set`, and each minute the device is awake (the `timezone-offset` service), which catches daylight saving time changes and wake-ups within a minute. exFAT stores UTC with its offset, so it is right either way; its `sys_tz` mount option only helps reading entries written without an offset. Caveats: files written in the minute after a change get the old offset; files the kernel read in before a change keep the old conversion while cached, and if written back without new times they move by the change. Rejected: `time_offset=` at mount (fixed, so wrong after a daylight saving time change until remounted); UTC on the card (a PC shows every device-written time shifted by the zone's offset); computing the next change and waking for it (more code for at most a minute's gain).
- **All of tzdata's zones are in the image, without the leap-second variants (`right/`)** (2026-10-18). About 110 KB in the squashfs (200 KB with `right/`). Any zone file's name is accepted (not the `posix/` and `right/` variants); `list` offers those of tzdata's `zone.tab` (one or more per country), since aliases (such as `US/Eastern`) would only duplicate them.
- **The battery driver reports the gauge's own level, without smoothing of its own** (2026-10-18). The gauge already smooths. The BSP driver's own smoothing (after a gauge restart, a level climbing from 1 % at 1 % per 30 s on a charger, kept in register 0x0c across reboots) once lagged the gauge by 40 %. The driver leaves register 0x0c alone: TrimUI's U-Boot writes it for TrimUI's kernel and never acts on it, so a flag left there affects nothing. Rejected: keeping the smoothing; clearing 0x0c at boot (nothing of ours reads it).

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
| BLDO3 | 2.0–3.5 V | rumble motor (voltage = strength) | only while rumbling |
| CLDO1 | 1.8 V | panel I/O, eMMC I/O, codec | always on |
| CLDO3 | 3.3 V | main 3.3 V (SD card, USB, eMMC) | on |
| CLDO4 | 3.3 V | panel | with the panel |
| CPUSLDO | 0.9 V | always-on domain | on |
| Boost | 5.1 V | bottom USB-C port as host | in host role ([usb.md](usb.md)) |
| PL8 switch | 5 V | top USB-C port | off in sleep |
| PD11 switch | 5 V | LEDs (anything else unknown) | LED driver: on only while an LED is lit |
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

**Battery reporting** (`/sys/class/power_supply/axp2202-battery`, `axp2202-usb`; standard properties only). The gauge needs a 128-byte battery model (in TrimUI's device tree); the driver uploads it only when the chip's "model loaded" flag is clear, since both survive reboots while the chip stays powered. The level reported is the gauge's own (its 99 % reads as 100 % once the charger is done). If at boot the gauge claims over 60 % with the battery under 3.5 V while charging, the driver restarts the gauge so that it estimates the level afresh, and logs "resetting gauge".

**Power settings.** `brick-power` (`/usr/sbin`), for Specular, `powertest` and a login. Changes take turns (a lock in `/run/brick-power`) and are logged (tag `brick-power`); exit status 0 done, 1 refused or failed (the reason on stderr and in the log), 2 usage.

```
brick-power                       the settings in effect, read back from the hardware:
    profile   saver                                           the last applied ("none applied since start-up")
    cpu       408-1200 MHz, now 816 MHz, thermal limit step 0/8 (0: not limited)     limits in effect
    governor  ondemand, sampling 50 ms
    gpu       702 MHz
    usb-top   on (5 V enabled, devices attached: 0)
    battery   ok 54 % 3.92 V, charge 0 mA, Discharging       battery-guard state
brick-power profile performance|balanced|saver
brick-power usb-top on|off        off is refused (exit 1) while a USB device is attached to the top port
```

A profile writes the CPU's minimum and maximum speed (the minimum is lowered first, since the kernel refuses a minimum above the maximum) and `ondemand`'s sampling interval, then records its name in `/run/brick-power/profile`. A thermal limit still applies under any profile: the kernel clamps the maximum (and the minimum with it) after the profile's values, so `scaling_max_freq` and the status show the limit in effect. `usb-top` binds or unbinds the top port's host-controller drivers ([usb.md](usb.md)).

**Low battery.** `battery-guard` (`/usr/libexec/brick`), a service that samples the battery every 30 s and logs (tag `battery-guard`) every change of verdict, every sample while the battery is under 10 % or at 3.70 V or less and the first one after, read errors, and the power-off with the last four samples. A replay of the logged samples therefore makes the service's decisions again:

```
sample   <capacity %> <voltage µV> <charge current µA> <status> | absent | error <message>   e.g. "1 3640000 0 Discharging"
verdict  ok | charging | unsure (the gauge says empty, the voltage disagrees) | empty | absent | error
battery-guard state     one fresh sample: "<verdict> 54 % 3.92 V, charge 0 mA, Discharging"
battery-guard replay    the decisions, without powering off, for logged samples on stdin
```

**Sleep.** Specular decides when (after 30 s untouched, never during a running game, or a tap on the power button) and calls `sleepnow`, which (unless it powers off for an empty battery: Decisions) stops WiFi (its driver refuses to suspend while connected), optionally sets the clock chip's alarm, and writes `mem` to `/sys/power/state`. Drivers turn off what they own: panel (display-off, sleep-in, CLDO4), LEDs' 5 V, rumble, speaker amplifier, both USB ports, WiFi chip (power-cycled); Bluetooth is brought down. The arisc firmware then decides the remaining rails from the device tree's `standby_param` (`vdd-cpu` 1, `vdd-sys` 2, `vcc-pll` 0x80, `osc24m-on` 1) and keeps the 24 MHz oscillator running. The power key and the battery's low-level warning (both through the power chip's interrupt; the warning untested: Open questions) and the clock chip's alarm wake it.

**Clock.** The SoC's own real-time clock (`rtc0`, `RTC_DRV_SUNXI`). The kernel sets the system time from it at boot (`CONFIG_RTC_HCTOSYS`) and copies the system time back while it is network-synchronised (`CONFIG_RTC_SYSTOHC`); BusyBox `ntpd -n -p pool.ntp.org` runs as a service whenever a default route exists.

**Time zone.** `brick-timezone` (`/usr/sbin`):

```
/etc/localtime → /var/state/time/localtime → /usr/share/zoneinfo/<zone>   missing or broken: UTC (glibc's fallback too)
/run/brick-timezone.offset                  the offset last given to the kernel (date +%z)
```

What Specular uses (errors on stderr and in the system log, tag `brick-timezone`):

```
brick-timezone get          the zone, e.g. Europe/Paris
brick-timezone set ZONE     sets ZONE (any zone file's name) and prints it; exit 1 if there is no such zone
brick-timezone list         UTC, then zone.tab's zones in order of name, one per line
```

For an automatic zone, Specular asks the user once whether it may tell a lookup service the network's public address, looks the zone up when WiFi joins a network, and calls `set`; a lookup's answer may be an alias that `list` doesn't show. The image has no CA certificates (nothing uses them: Specular's HTTP client has no TLS), so a lookup over HTTPS would need Specular to bring its own (for example rustls with built-in roots); ipinfo.io also answers plain HTTP. A program sees a new zone at its next `localtime()` or `tzset()`; with only `localtime_r()`, glibc keeps the zone a program saw first, so Specular's clock must call `tzset()` before reading the time, and redraw after `set` (neither is done yet).

`brick-timezone kernel` (rcS, `set`, the `timezone-offset` service each minute) gives the kernel the zone's current offset when it differs from the last one given. `-u` matters: the kernel's first zone setting after boot otherwise assumes the clock chip keeps local time, shifts the system clock, and from then on writes local time to the clock chip (`warp_clock`, `persistent_clock_is_local`).

**Measuring.** The gauge reports whole percent only (about 30 mAh) and no discharge current, so drain is measured over long phases. `powertest` runs an unattended sequence (deep sleep, idle screen-on with base and tuned settings, screen off, full load), logging battery, temperatures, CPU speed, interrupts, idle-state residency, per-process wakeups and the power settings in effect to the SD card. Its tuned settings come from the environment (`TUNED_PROFILE`, `TUNED_USB_TOP`, `TUNED_SAMPLING`).

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
- (2026-10-12, device) The battery driver, which then still smoothed, once reported 43 % while the gauge read 86 %; after a reboot it reported 86 %. Smoothing (register 0x0c) was active and lagging, and no log of how it got set survived. Source: linux `axp2202_battery.c`.
- (2026-10-18, stock) TrimUI's U-Boot restarts the gauge at boot when it keeps reading 0 %: with a charger present it then writes 0x81 to register 0x0c (smoothing from 1 %, for the BSP driver); on battery it restarts it only above 3.7 V and leaves 0x0c alone. It reads 0x0c back only to print it. This is the likely source of the lagging level above. Source: disassembly of `u-boot.fex` (the code around the strings "adapt reset gauge" and "AXP2202_CURVE_CHECK"); register 0x0c read 0x00 on our unit.
- (2026-10-13, device) The first read of some SoC temperature sensors after waking (DDR, sometimes GPU) fails with EAGAIN; userspace reading temperatures must tolerate it.
- (2026-10-13, device) Deep sleep with the regulators in automatic mode: 88 → 81 % in 8 h, → 77 % after 4.4 h more: 0.9 %/h ≈ 27 mA, about 4.5 days from full. Barely different from forced PWM: the regulator modes matter awake, not asleep.
- (2026-10-13, device) `regulator-off-in-suspend` has no effect here: in this kernel only Exynos and Rockchip platform code applies it, and the arisc firmware decides rails from `standby_param`. The gauge's coulomb counter isn't usable (only its high word is exposed; gauge memory reads 0). Source: linux `regulator_suspend_prepare()` callers; register reads on our unit.
- (2026-10, upstream) The AXP717 can't measure discharge current. Stock's power-off left the power chip in a state that drained and heated the battery; NextUI/MinUI fixed it with their own power-off sequence (masking the chip's interrupts, registers 0x40–0x4C, 0x22, 0x27). Source: github.com/Helaas/nextui-brick-poweroff-hook.
- (2026-10-10, device) The power chip's charge-LED output is disabled on stock (register 0x70 = 0), and the device tree has `pmu_chgled_func = 0`, so our battery driver leaves it alone too. Yet the power key's charging light works on our system (red while charging, green when charged, 2026-10-18), so something outside our software drives it; see [leds-and-rumble.md](leds-and-rumble.md). Source: linux `axp2202_battery.c`.
- (2026-10-18, device) The clock chip keeps UTC (`rtc0` read the same as `date -u`), with `CONFIG_RTC_HCTOSYS` and `CONFIG_RTC_SYSTOHC` set; nothing on the system reads or writes it as local time.
- (2026-10-18, upstream) glibc's `localtime_r()` loads the zone once per process. `localtime()` and `tzset()` check `/etc/localtime` again and reload it when the file it leads to has changed (device, inode or modification time), which a stat call checks; `set` replaces the link, so the file changes. Source: glibc `time/tzset.c`, `time/tzfile.c`.
- (2026-10-18, upstream) Geo-IP lookup services, for Specular's automatic zone: `ipinfo.io/timezone` answers a bare zone name (`America/Toronto`) over HTTPS and plain HTTP. `https://ipapi.co/timezone` answers the same, but answered 429 (rate-limited) after a few requests from one address, and its plain HTTP redirects to HTTPS. worldtimeapi.org refused connections. ip-api.com (`/line/?fields=timezone`) answers, but its free use is plain HTTP only and non-commercial only.
- (2026-10-18, upstream) Linux's FAT driver converts every file time with the kernel's zone offset (`sys_tz`, set only through `settimeofday`), unless mounted with `tz=UTC` or `time_offset=`; its exFAT driver writes UTC with offset 0 and uses `sys_tz` (mount option `sys_tz`) or `time_offset=` only for entries that carry no offset. BusyBox `hwclock -u --systz` sets `sys_tz` from the current local offset (daylight saving time included); it first calls `settimeofday` with offset 0, then with the real one, which stops the kernel treating the clock chip as local time; it doesn't touch the clock chip. Source: linux `fs/fat/misc.c`, `kernel/time/time.c`, `kernel/time/ntp.c`; exFAT backport `fs/exfat/misc.c`; BusyBox `util-linux/hwclock.c`.
- (2026-10-18, device) `ondemand` re-evaluated the CPU speed only every 2 s: `sampling_rate` 2 000 000 µs, 1000 times the 2 ms speed-change time from the speed table's `clock-latency` (`min_sampling_rate` 40 ms). Its settings are shared by all CPUs, in `/sys/devices/system/cpu/cpufreq/ondemand/`, not per policy. The idle measurements above (0.4–0.8 GHz, 12.1 and 10.0 %/h) were taken with 2 s.
- (2026-10-18, bsp) A user's CPU speed limits are checked against each other, not against a thermal limit, and thermal limits clamp them afterwards (cpufreq's policy notifier), so no profile can override a thermal limit. Source: linux `drivers/cpufreq/cpufreq.c` (`store_one`), `cpu_cooling.c`.
- (2026-10-18, bsp) The vendor clock driver never turns off unused clocks: `drivers/clk/sunxi/clk-sunxi.h` defines `__SUNXI_ALL_CLK_IGNORE_UNUSED__`, which marks every vendor clock to be skipped by the kernel's pass that turns unused clocks off (`clk_ignore_unused` is not needed on the command line). Running with nothing using them (device, register reads against `clk_summary`): PLL_VIDEO1–3, the crypto engine (no driver), GPADC (node disabled), and the video decoder's PLL and gate (`sunxi-cedar`, unused). PLL_CPU, PLL_DDR, MSGBOX and the watchdog run with an enable count of 0, so the switch can't simply go.
- (2026-10-18, device) Low-battery interrupt: TrimUI's device tree sets warning levels 5 % and 0 % (register 0x1b = 0x00) and marks both warnings to stay on in sleep (`wakeup_low_warning1`, `wakeup_low_warning2`); the chip's interrupt-enable register 0x40 = 0xd0 (both warnings and the gauge's new-level interrupt). Our battery driver leaves on in sleep exactly the interrupts with a `wakeup_*` property. Level 1 is 5–20 % and level 2 0–15 %, in 1 % steps. Source: linux `axp2202_battery.c`; X-Powers' interrupt names (the AXP717's "SOC drop to warning level 2", in XPowersLib), which suggest it fires on reaching the level.
- (2026-10-18, device) The battery's `current_now` is the measured charge current only (0 on battery): 201 mA on a charger with the gauge at 100 % and the status already Full. The charger's status follows its charging stage, not the current. Source: linux `axp2202_battery.c`.

## Open questions

- Does the power chip's low-battery interrupt wake the device from sleep, and does it fire on reaching its level or only below it? A device test at a low battery answers it; if it doesn't wake, `sleepnow` would set a wake alarm from the battery level instead, and if it fires only below, the wake level goes to 2 %.
- Does the 50 ms `ondemand` interval raise idle drain or wake-ups? `powertest` with `TUNED_SAMPLING=2000000` compares the two.
- What are the battery's voltages at 1–10 %, under load and just after waking? A discharge logged by the battery guard (dry run) sets its levels.
- Do the unused clocks cost anything measurable? A USB power meter with them switched off by hand answers it.
