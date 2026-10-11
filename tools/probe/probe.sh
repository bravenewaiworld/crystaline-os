#!/bin/sh
# Read-only hardware/software snapshot of a TrimUI Brick (Allwinner A133P) running
# its stock firmware, for porting our own kernel. Run as root on the device
# (BusyBox ash) with the memdump helper next to this script; normally started by
# collect.sh. Progress goes to stderr; a .tar.gz of the results goes to stdout.
#
# The only change made to the device: debugfs is mounted if it isn't already
# (and unmounted afterwards).
#
# Keep the screen on while it runs: display registers are only read when their
# clocks are on, but the screen blanking mid-run could still race that check.

OUT=/tmp/brick-probe
HERE=$(cd "$(dirname "$0")" && pwd)
MEMDUMP=$HERE/memdump
DBG=/sys/kernel/debug

log() { echo "[probe] $*"; }

# limit SECONDS CMD... : run CMD, killing it after SECONDS (BusyBox here has no
# `timeout`, and some vendor sysfs/debugfs reads may block). A kill is noted in
# the output so a cut-off capture doesn't look complete.
limit() {
	t=$1; shift
	"$@" & p=$!
	# Detached from our stdout, or a pipeline like "limit cat | head" would stay
	# open until the sleep ends.
	( sleep "$t"; kill -9 $p ) >/dev/null 2>&1 & w=$!
	wait $p; r=$?
	kill $w 2>/dev/null
	[ $r -eq 137 ] && echo "[probe: killed after ${t}s]"
	return $r
}

# cap FILE CMD... : save CMD's output and errors to FILE (10 s limit).
cap() { f=$1; shift; mkdir -p "$(dirname "$f")"; limit 10 "$@" >"$f" 2>&1; }

# catall FILE... : print each existing FILE under a "== name" header.
catall() { for f; do [ -f "$f" ] && { echo "== $f"; cat "$f"; }; done; }

# dumpdir FILE DIR [DEPTH] : append "path: contents" (one line per file, newlines
# turned into tabs, 4 KiB max) for every file under DIR, descending DEPTH levels.
# Uses globs rather than find so that sysfs symlinks (every /sys/class entry is
# one) are followed.
dumpdir() {
	mkdir -p "$(dirname "$1")"
	if [ -d "$2" ]; then walk "$2" "${3:-1}" >>"$1"; else echo "missing: $2" >>"$1"; fi
}
walk() {
	local x
	for x in "$1"/*; do
		# Skip links that lead back up or sideways in the sysfs tree (they'd
		# recurse or duplicate), binary files, and per-device noise.
		case ${x##*/} in
		subsystem|device|driver|of_node|firmware_node|consumer:*|supplier:*) continue ;;
		descriptors|rom|uevent|power) continue ;;
		esac
		if [ -f "$x" ]; then
			printf '%s: ' "$x"
			limit 3 cat "$x" 2>&1 | head -c 4096 | tr '\n' '\t'
			echo
		elif [ -d "$x" ] && [ "$2" -gt 1 ]; then
			walk "$x" $(($2 - 1))
		fi
	done
}

# Small listings that would otherwise need nested `sh -c` quoting.
list_drivers() {
	for d in "$1"/*; do
		echo "${d##*/} name=$(cat "$d/name" 2>/dev/null) driver=$(basename "$(readlink "$d/driver")" 2>/dev/null)"
	done
}
list_exported_gpios() {
	for g in /sys/class/gpio/gpio*; do
		[ -d "$g" ] && echo "${g##*/} dir=$(cat "$g/direction") value=$(cat "$g/value")"
	done
}
list_wakeup_enabled() {
	find /sys/devices -path '*/power/wakeup' 2>/dev/null | while read -r f; do echo "$f: $(cat "$f")"; done
}

collect() {
	rm -rf "$OUT"; mkdir -p "$OUT"
	cd "$OUT" || exit 1

	# ------------------------------------------------------------ system
	log system
	for f in cmdline cpuinfo meminfo interrupts iomem partitions mounts modules; do
		cap "sys/$f.txt" cat "/proc/$f"
	done
	cap sys/uname.txt uname -a
	cap sys/by-name.txt ls -l /dev/block/by-name
	cap sys/df.txt df -h
	cap sys/ps.txt ps w
	cap sys/dmesg.txt dmesg
	cap sys/logread.txt logread
	cap sys/uboot-env.txt fw_printenv
	cap sys/etc-versions.txt catall /etc/version /etc/openwrt_release /etc/openwrt_version /usr/trimui/version*
	cap sys/sdcard-top.txt ls -la /mnt/SDCARD
	cp /sys/firmware/fdt dt-live.dtb 2>/dev/null

	# ------------------------------------------------------------ power
	log power
	dumpdir power/regulators.txt /sys/class/regulator 2
	dumpdir power/supply.txt /sys/class/power_supply 2
	# wakeup_count is left out: reading it can block.
	cap power/sleep.txt catall /sys/power/state /sys/power/mem_sleep /sys/power/pm_*
	cap power/wakeup-enabled.txt list_wakeup_enabled
	dumpdir power/cpufreq.txt /sys/devices/system/cpu/cpufreq 3
	dumpdir power/cpuidle.txt /sys/devices/system/cpu/cpu0/cpuidle 2
	dumpdir power/thermal.txt /sys/class/thermal 2
	dumpdir power/devfreq.txt /sys/class/devfreq 2

	# ------------------------------------------------------------ debugfs
	log debugfs
	mounted_dbg=
	# Any well-known debugfs entry tells us it's already mounted.
	[ -d "$DBG/clk" ] || { mount -t debugfs none "$DBG" && mounted_dbg=1; }
	cap debugfs/ls.txt find "$DBG" -maxdepth 2
	for f in clk/clk_summary gpio regulator/regulator_summary regulator/supply_map \
		wakeup_sources suspend_stats usb/devices; do
		cap "debugfs/${f##*/}.txt" cat "$DBG/$f"
	done
	for p in "$DBG"/pinctrl/*/; do
		n=$(basename "$p")
		for f in pinmux-pins pinconf-pins pins gpio-ranges; do cap "debugfs/pinctrl/$n-$f.txt" cat "$p$f"; done
	done
	for m in "$DBG"/mmc*; do
		[ -d "$m" ] || continue
		cap "debugfs/${m##*/}-ios.txt" cat "$m/ios"
		for c in "$m"/mmc*:*; do
			[ -f "$c/ext_csd" ] && cap "debugfs/${c##*/}-ext_csd.txt" cat "$c/ext_csd"
		done
	done
	# Only I2C regmaps, named <bus>-<4-digit address> (e.g. 0-0034, the PMIC).
	# A memory-mapped block's regmap could be read while its clock is off.
	for r in "$DBG"/regmap/*-00??; do
		[ -f "$r/registers" ] && cap "debugfs/regmap-${r##*/}.txt" cat "$r/registers"
	done
	dumpdir debugfs/pvr.txt "$DBG/pvr" 1   # PowerVR GPU driver
	[ -n "$mounted_dbg" ] && umount "$DBG"

	# ------------------------------------------------------------ devices
	log devices
	cap dev/platform-drivers.txt list_drivers /sys/bus/platform/devices
	cap dev/i2c.txt list_drivers /sys/bus/i2c/devices
	cap dev/classes.txt ls /sys/class
	cap dev/input-devices.txt cat /proc/bus/input/devices
	cap dev/input-nodes.txt ls -lR /dev/input
	cap dev/gpio-exported.txt list_exported_gpios
	dumpdir dev/backlight.txt /sys/class/backlight 2
	dumpdir dev/leds.txt /sys/class/leds 2
	dumpdir dev/fb.txt /sys/class/graphics 2
	dumpdir dev/disp.txt /sys/class/disp 3
	dumpdir dev/mmc.txt /sys/class/mmc_host 3
	dumpdir dev/usb.txt /sys/bus/usb/devices 2
	dumpdir dev/udc.txt /sys/class/udc 2
	# Non-standard sysfs classes from TrimUI and the Allwinner SDK: LED effects,
	# rumble, speaker mute, WiFi/BT MAC addresses (addr_mgt), PMIC (axp*),
	# lid/hall sensor and switches, plus rfkill for the radios.
	for c in /sys/class/*; do
		case ${c##*/} in
		led_anim|led|motor|speaker|addr_mgt|rfkill|axp*|trimui*|gpio_power|hall*|switch*)
			dumpdir "dev/vendor-${c##*/}.txt" "$c" 3 ;;
		esac
	done
	# USB-C port controller. Only plain values are read: reading its usb_host, usb_device and
	# usb_null files *switches* the port's role.
	cap dev/usbc0.txt catall /sys/devices/platform/soc/usbc0/otg_role /sys/devices/platform/soc/usbc0/axp_5v
	cap dev/gpu-sysfs.txt find /sys/devices/platform -maxdepth 2 -iname '*gpu*'
	cap dev/proc-pvr.txt catall /proc/pvr/*

	# ------------------------------------------------------------ audio
	log audio
	cap audio/proc-asound.txt catall /proc/asound/cards /proc/asound/devices /proc/asound/pcm /proc/asound/version
	for c in /proc/asound/card[0-9]*; do
		n=${c##*card}
		cap "audio/amixer-card$n.txt" amixer -c "$n" contents
		cap "audio/tinymix-card$n.txt" tinymix -D "$n"
	done

	# ------------------------------------------------------------ network
	# Contains this unit's MAC addresses and the connected network's name.
	log network
	cap net/ip-addr.txt ip addr
	cap net/ip-route.txt ip route
	cap net/iw-dev.txt iw dev
	cap net/iw-link.txt iw dev wlan0 link
	cap net/iw-power-save.txt iw dev wlan0 get power_save
	cap net/iw-phy.txt iw phy
	cap net/wifi-driver.txt readlink /sys/class/net/wlan0/device/driver
	cap net/bt.txt hciconfig -a

	# ------------------------------------------------------------ registers
	# Raw register snapshots. Addresses are from the A133 user manual / the stock
	# device tree. Always-powered blocks are read unconditionally; the others only
	# when the clock controller (CCU) shows them clocked and out of reset, since
	# reading a gated block can hang the bus.
	log registers
	mkdir -p regs
	CCU=0x03001000
	reg() { "$MEMDUMP" "$2" "$3" >"regs/$1.txt" 2>&1; }
	# word ADDR : print one 32-bit register value (empty if memdump fails).
	word() { "$MEMDUMP" "$1" 4 | awk '{print $2}'; }
	# bits_set ADDR MASK : true if all MASK bits are set in the register at ADDR.
	bits_set() { v=$(word "$1"); [ -n "$v" ] && [ $((v & $2)) -eq $(($2)) ]; }
	# ccu_on BGR_OFFSET : a CCU "bus gating reset" register has the bus clock gate
	# in bit 0 and the reset release in bit 16.
	ccu_on() { bits_set $((CCU + $1)) 0x10001; }

	reg ccu       $CCU       0x1000
	reg r_ccu     0x07010000 0x400    # always-on domain clocks ("PRCM")
	reg pio       0x0300b000 0x400    # pin mux/pull/drive, ports B-H
	reg r_pio     0x07022000 0x400    # pin mux/pull/drive, port L
	reg gpu_power 0x07001000 0x100    # power switch for the GPU domain (lives in the always-on domain)
	reg sys_cfg   0x03000000 0x100    # system control; 0x24 holds the chip revision
	reg rtc       0x07000000 0x200    # real-time clock; 0x100-0x11c are 8 registers that survive resets
	ccu_on 0x07ac && reg pwm       0x0300a000 0x400    # backlight PWM
	ccu_on 0x0abc && reg disp_top  0x06510000 0x100    # display-interface top: mixer-to-TCON routing, DSI gate
	ccu_on 0x0b7c && reg tcon_lcd0 0x06511000 0x400    # display timing controller
	ccu_on 0x0b4c && reg dsi_dphy  0x06504000 0x2000   # DSI controller (+0x0) and its D-PHY (+0x1000), one gate
	ccu_on 0x0a5c && reg codec     0x05096000 0x400
	ccu_on 0x0bfc && reg ledc      0x05018000 0x40     # RGB LED controller
	if ccu_on 0x060c; then
		reg de_top 0x06000000 0x100
		# The display engine gates each mixer internally: bit 0 of its module
		# clock (+0x00), bus clock (+0x04) and reset (+0x08) registers is mixer 0.
		bits_set 0x06000000 1 && bits_set 0x06000004 1 && bits_set 0x06000008 1 &&
			reg de_mixer0 0x06100000 0x8000
	fi
	log done
}

# Only the final tarball goes to the real stdout; nothing else (including
# children that outlive their time limit) holds it open.
collect >&2
tar czf - -C /tmp brick-probe
rm -rf "$OUT"
