#!/bin/sh
# Device-tree changes for our kernel, applied by tools/sdboot/patch-boot-package.sh to the DTB
# (compiled device tree: the hardware description the kernel reads) inside the boot package, which
# is the one vendor U-Boot hands the kernel.
# Usage: dt-tweaks.sh <dtb>
set -eu
DTB=$1
REGS=/soc@03000000/s_twi@0x07081400/pmu@34/regulators@0   # power-management chip's rails

# Keep CLDO1 (1.8 V) on: besides the panel's I/O it feeds the codec's headphone charge pump and
# other I/O. CLDO4 (3.3 V) feeds only the panel, so the panel driver (trimui_brick.c) switches it
# off with the screen and in sleep.
fdtput "$DTB" $REGS/cldo1 regulator-always-on

# Power chip DC-DC converters 1 and 2 in automatic mode (0) rather than forced PWM (1: always
# switching at full rate, the steadiest voltage but wasteful at light load), which the bootloader
# leaves set. Our axp2101-regulator driver supports this setting for the AXP2202.
fdtput -t u "$DTB" $REGS/dcdc1 x-powers,dcdc-workmode 0
fdtput -t u "$DTB" $REGS/dcdc2 x-powers,dcdc-workmode 0

# CPU voltage regulator (TCS4838 at I2C 0x41): register-compatible with the Silergy SYR827, so
# use the standard fan53555 driver. TrimUI's node describes the chip as two child regulators
# for its own driver; fan53555 instead reads the regulator settings from the chip node itself.
# Keep "ti,tcs4838" first: vendor U-Boot also reads this node and looks for that name.
# The chip has two voltage registers; on this board VSEL0 is the one in effect. fan53555 writes
# the register not named as the suspend one, so suspend-voltage-selector = 1 makes it write
# VSEL0. Getting this wrong would let the CPU speed up without its voltage rising.
TCS=/soc@03000000/s_twi@0x07081400/tcs@41
fdtput -t s "$DTB" $TCS compatible ti,tcs4838 silergy,syr827
fdtput -t s "$DTB" $TCS regulator-name vdd-cpu
fdtput -t i "$DTB" $TCS regulator-min-microvolt 712500
fdtput -t i "$DTB" $TCS regulator-max-microvolt 1500000
fdtput "$DTB" $TCS regulator-always-on
fdtput "$DTB" $TCS regulator-boot-on
fdtput -t i "$DTB" $TCS fcs,suspend-voltage-selector 1
# Automatic mode (REGULATOR_MODE_NORMAL = 2) instead of the bootloader's forced PWM (see DC-DC 1/2
# above): 17 % less drain at idle, and stable under full load (tools/device/powertest).
fdtput -t u "$DTB" $TCS regulator-initial-mode 2
fdtput -t i "$DTB" /cpus/cpu@0 cpu-supply "$(fdtget "$DTB" $TCS phandle)"

# Buttons as a standard gpio-keys input device (the gamepad bridge turns it into a gamepad).
# All are active-low GPIOs with external pull-ups. This vendor kernel's GPIO specifier has six
# cells: port (A=0 ... H=7), pin, mux (0 = input), pull (0 = none), drive (0xffffffff = leave
# as is), data (1 = active low). Face buttons use positional codes (BTN_SOUTH = bottom), so on
# the Brick's Nintendo layout B is SOUTH and A is EAST.
PIO=$(fdtget "$DTB" /soc@03000000/pinctrl@0300b000 phandle)
KEYS=/brick-keys
fdtput -c "$DTB" $KEYS
fdtput -t s "$DTB" $KEYS compatible gpio-keys
fdtput -t s "$DTB" $KEYS label brick-keys
# key NAME PORT PIN CODE [INPUT_TYPE]
key() {
	fdtput -c "$DTB" $KEYS/$1
	fdtput -t s "$DTB" $KEYS/$1 label "$1"
	fdtput -t u "$DTB" $KEYS/$1 gpios "$PIO" "$2" "$3" 0 0 0xffffffff 1
	fdtput -t u "$DTB" $KEYS/$1 linux,code "$4"
	[ -z "${5:-}" ] || fdtput -t u "$DTB" $KEYS/$1 linux,input-type "$5"
}
key a      3 12 0x131	# BTN_EAST
key b      3 13 0x130	# BTN_SOUTH
key x      3 18 0x133	# BTN_NORTH
key y      3 19 0x134	# BTN_WEST
key up     3 17 0x220	# BTN_DPAD_UP
key down   3 14 0x221	# BTN_DPAD_DOWN
key left   3 15 0x222	# BTN_DPAD_LEFT
key right  3 16 0x223	# BTN_DPAD_RIGHT
key l1     1  4 0x136	# BTN_TL
key r1     7 17 0x137	# BTN_TR
key l2     1  2 0x138	# BTN_TL2
key r2     1  5 0x139	# BTN_TR2
key select 7 15 0x13a	# BTN_SELECT
key start  7 16 0x13b	# BTN_START
key menu   7 14 0x13c	# BTN_MODE
key f1     7 12 0x2c0	# BTN_TRIGGER_HAPPY1
key f2     7 13 0x2c1	# BTN_TRIGGER_HAPPY2
key volup  3 21 115	# KEY_VOLUMEUP
key voldn  3 20 114	# KEY_VOLUMEDOWN
key fn     7 19 1 5	# SW_TABLET_MODE (EV_SW): the FN slider, as TrimUI's pad reports it

# LEDs: a chain of 14 on the LED controller (the vendor tree claims 23). Chain order: top bar left
# to right (0-7), F2 (8), F1 (9), then the shoulders: under L1 (10), L2 (11), R2 (12), R1 (13).
# LEDs 0-9 take red and green in the opposite order from 10-13 (found in TrimUI's led_anim driver
# and confirmed on the device).
LEDC=/soc@03000000/ledc@0x05018000
fdtput -t u "$DTB" $LEDC led_count 14
fdtput -t u "$DTB" $LEDC swap-rg-leds 0 1 2 3 4 5 6 7 8 9
# Reset time: the idle gap after each data frame that tells the LEDs to apply what they received
# (the driver accepts up to 327000 ns). The vendor tree's 84 ns is far too short for these LEDs
# (~300 µs). The driver sends a frame on every brightness write, so back-to-back writes merged
# into one long frame and colours shifted onto later LEDs (random colours, LEDs stuck on).
fdtput -t u "$DTB" $LEDC reset_ns 300000
# Their 5 V supply, switched on by PD11, as a fixed regulator that the LED driver enables and
# switches off during sleep. GPIO cells as for the buttons: mux 1 = output, data 0 = active high.
LED5V=/led-5v
fdtput -c "$DTB" $LED5V
fdtput -t s "$DTB" $LED5V compatible regulator-fixed
fdtput -t s "$DTB" $LED5V regulator-name led-5v
fdtput -t u "$DTB" $LED5V regulator-min-microvolt 5000000
fdtput -t u "$DTB" $LED5V regulator-max-microvolt 5000000
fdtput -t u "$DTB" $LED5V gpio "$PIO" 3 11 1 0 0xffffffff 0
fdtput "$DTB" $LED5V enable-active-high
fdtput -t s "$DTB" $LEDC led_regulator led-5v

# Headphone jack: its detect signal is the opposite polarity from the vendor tree's setting
# (0 reported headphones with the jack empty).
fdtput -t u "$DTB" /soc@03000000/sound@0 hp_detect_case 1
# Start-up headphone amplifier setting (a register value: 0 = loudest, each step 6 dB quieter;
# it also drives the speaker). 3 = -18 dB, what TrimUI's start-up script set; 0 is very loud.
fdtput -t u "$DTB" /soc@03000000/codec@0x05096000 headphonegain 3

# Rumble: a standard force-feedback input device (regulator-haptic). The motor's supply is BLDO3,
# whose voltage sets the strength (min-microvolt for the weakest effect, max for the strongest),
# and PH3 switches it on. BLDO3's always-on flags are removed: the driver powers it only while rumbling.
BLDO3=$REGS/bldo3
fdtput -d "$DTB" $BLDO3 regulator-always-on regulator-boot-on
RUMBLE=/brick-rumble
fdtput -c "$DTB" $RUMBLE
fdtput -t s "$DTB" $RUMBLE compatible regulator-haptic
fdtput -t u "$DTB" $RUMBLE haptic-supply "$(fdtget "$DTB" $BLDO3 phandle)"
fdtput -t u "$DTB" $RUMBLE min-microvolt 2000000
fdtput -t u "$DTB" $RUMBLE max-microvolt 3300000
# PH3: port 7 pin 3, output, active high (cells as for the buttons).
fdtput -t u "$DTB" $RUMBLE enable-gpios "$PIO" 7 3 1 0 0xffffffff 0

# Bottom USB-C port role from the power chip's cable detection (see axp2202_usb_power.c): the
# port manager (usbc0) switches roles from what the chip reports is plugged in, instead of
# polling an ID pin, which never changes on this board. The chip's own charger detection (BC1.2) is turned on and sets the input current
# limit itself.
USB_PSY=/soc@03000000/s_twi@0x07081400/pmu@34/usb_power_supply
fdtput -t u "$DTB" $USB_PSY pmu_bc12_en 1
fdtput -t u "$DTB" /soc@03000000/usbc0@0 extcon "$(fdtget "$DTB" $USB_PSY phandle)"

# Internal storage (eMMC, controller sdc2), which U-Boot leaves disabled when booting from the card.
# Enabled with the limits U-Boot itself sets when it boots TrimUI's system from the eMMC, the
# settings stock has always used: 50 MHz and no HS200/HS400, so the eMMC runs in DDR52 mode.
# The installer (userspace/brick-install) needs it; nothing mounts it by itself. For an eMMC boot
# U-Boot also fills in sample delays tuned for each unit (sdc_tm4_sm<speed mode>_freq<frequency
# band>, one byte per band); 0xff bytes mean "not set", so the driver uses its defaults, which read
# the eMMC without errors (two full reads gave the same checksum, 2026-10-14; see docs/storage.md).
SDC2=/soc@03000000/sdmmc@04022000
fdtput -t s "$DTB" $SDC2 status okay
fdtput -t u "$DTB" $SDC2 max-frequency 50000000
fdtput -d "$DTB" $SDC2 mmc-hs200-1_8v mmc-hs400-1_8v
for sm in 0 1 2 3 4; do for f in 0 1; do fdtput -t x "$DTB" $SDC2 sdc_tm4_sm${sm}_freq$f ffffffff; done; done
