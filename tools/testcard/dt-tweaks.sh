#!/bin/sh
# Device-tree changes for test cards running our kernel, applied by build-test-card.sh to the DTB
# (compiled device tree: the hardware description the kernel reads) inside the card's boot
# package, which is the one vendor U-Boot hands the kernel.
# Usage: dt-tweaks.sh <dtb>
set -eu
DTB=$1
REGS=/soc@03000000/s_twi@0x07081400/pmu@34/regulators@0   # power-management chip's rails
SD=/soc@03000000/sdmmc@04020000                           # SD card controller

# Keep the panel powered. Its rails (CLDO1, CLDO4) are switched by TrimUI's panel driver, which
# our kernel lacks, so Linux would cut them as unused and the screen would go blank.
fdtput "$DTB" $REGS/cldo1 regulator-always-on
fdtput "$DTB" $REGS/cldo4 regulator-always-on

# SD card: no UHS modes (1.8 V signalling). Our SD driver can't switch the card's signalling
# rails correctly, and with UHS enabled it never finishes initialising the card.
fdtput -d "$DTB" $SD sd-uhs-sdr50
fdtput -d "$DTB" $SD sd-uhs-ddr50
fdtput -d "$DTB" $SD sd-uhs-sdr104

# CPU voltage regulator (TCS4838 at I2C 0x41): register-compatible with the Silergy SYR827, so
# use the standard fan53555 driver. TrimUI's node describes the chip as two child regulators
# for its own driver; fan53555 instead reads the regulator settings from the chip node itself.
# Keep "ti,tcs4838" first: vendor U-Boot reads this node too. The suspend-voltage-selector of
# 1 makes the driver set VSEL0, the voltage slot the chip actually uses (VSEL1 is the off
# suspend slot); setting the other slot would raise CPU speed without raising its voltage.
TCS=/soc@03000000/s_twi@0x07081400/tcs@41
fdtput -t s "$DTB" $TCS compatible ti,tcs4838 silergy,syr827
fdtput -t s "$DTB" $TCS regulator-name vdd-cpu
fdtput -t i "$DTB" $TCS regulator-min-microvolt 712500
fdtput -t i "$DTB" $TCS regulator-max-microvolt 1500000
fdtput "$DTB" $TCS regulator-always-on
fdtput "$DTB" $TCS regulator-boot-on
fdtput -t i "$DTB" $TCS fcs,suspend-voltage-selector 1
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
# Their 5 V supply, switched on by PD11, as a fixed regulator that the LED driver enables and
# switches off during sleep. GPIO cells as for the buttons: mux 1 = output, data 0 = active high.
fdtput -c "$DTB" /led-5v
fdtput -t s "$DTB" /led-5v compatible regulator-fixed
fdtput -t s "$DTB" /led-5v regulator-name led-5v
fdtput -t u "$DTB" /led-5v regulator-min-microvolt 5000000
fdtput -t u "$DTB" /led-5v regulator-max-microvolt 5000000
fdtput -t u "$DTB" /led-5v gpio "$PIO" 3 11 1 0 0xffffffff 0
fdtput "$DTB" /led-5v enable-active-high
fdtput -t s "$DTB" $LEDC led_regulator led-5v
