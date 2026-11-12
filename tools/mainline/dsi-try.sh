#!/bin/sh
# dsi-try MODE [bsp=0|1] [timing=MBPS] [cont=0|1] [patch=HEX,...]: shows modetest's pattern in panel
# mode MODE (modetest's index: 0 = 60 Hz, 1 = 120, 2 = 90, 3 = 75.47) with the DSI test switches set
# as given (each one not given goes back to its default), then prints the lane rate and timing row
# the kernel chose. The frontend must be stopped (sv stop frontend).
mode=$1; shift
bsp=0 timing=0 cont=0 patch=
for a; do case $a in bsp=*) bsp=${a#*=} ;; timing=*) timing=${a#*=} ;; cont=*) cont=${a#*=} ;; patch=*) patch=${a#*=} ;; esac; done
echo $bsp >/sys/module/rockchipdrm/parameters/bsp_lane_rate
echo $timing >/sys/module/phy_rockchip_inno_dsidphy/parameters/timing_mbps
echo $cont >/sys/module/dw_mipi_dsi/parameters/continuous_clock
printf %s "$patch" >/sys/module/panel_generic_dsi/parameters/init_patch
kill $(pidof modetest) 2>/dev/null; sleep 1
dmesg -c >/dev/null
setsid sh -c "sleep 3600 | modetest -M rockchip -s 59@54:#$mode >/tmp/mt.log 2>&1" </dev/null >/dev/null 2>&1 &
sleep 2
dmesg | grep -E "lane rate|timing row|replaced"
