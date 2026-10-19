# Wireless

Status: In progress · Updated: 2026-10-18

WiFi and Bluetooth on the TrimUI Brick's XR829 chip, and Bluetooth audio. WiFi carries file transfer, network time and SSH, and Bluetooth carries wireless headphones. This is also the hardware with the weakest driver support: only Allwinner's vendor driver exists. When connected, WiFi is the biggest power cost on an idle device, so the system keeps it off unless something needs it.

## Decisions

- **We use Allwinner's vendor XR829 WiFi driver as a module, loaded only while WiFi is on** (2026-10-14). Loading the module powers up the chip's WiFi side, and unloading it powers it down. Bluetooth, on the same chip, is not affected. Rejected: the open `xradio` driver (it supports only the XR819).
- **WiFi starts off, and Specular switches it on and off** (2026-10-14). WiFi has three settings: On, Off and Auto. Auto, the default, keeps WiFi on only while Specular needs it, for example for file transfer, time sync or a download. A connected XR829 wakes the CPU about 30 times a second and blocks deep sleep.
- **The WiFi MAC address is derived from the SoC's unique chip ID** (2026-10-10; this is PocketForge's kernel change, which we took). The chip has no MAC address of its own. Without this, the driver makes up a new random address at every boot, which breaks DHCP reservations.
- **WiFi is stopped before sleep and restarted after** (2026-10-11). The driver refuses to suspend while connected. `sleepnow` stops `wpa_supplicant` and DHCP, takes `wlan0` down, sleeps, and restarts WiFi only if it was running.
- **The vendor driver's power saving stays on** (2026-10-10). Rejected: PocketForge's fix for its disconnects and stuck scans, which turns power saving off entirely (too costly for the battery).
- **Our own program, `xr829-attach`, starts Bluetooth** (2026-10-18). It powers up the chip's Bluetooth side, uploads its firmware, sets its address and hands it to the kernel as `hci0`. It is a rewrite of Xradio's `hciattach_xradio.c` (GPL-2.0-or-later, from Allwinner's BlueZ), with a time limit on every step, one log line per step, and an exit on failure so runit starts it again. It leaves the serial port at 1.5 Mbaud with flow control on. Rejected: TrimUI's closed `hciattach` (chosen 2026-10-11; no source, it retries a silent chip without end, and its log lines only reach the log when it exits); BlueZ's own `hciattach` (no XR829 support); the Sakura and PocketForge builds of the Xradio source (after attaching, their `hciattach` wrappers set the port again from settings saved before, which turns flow control off).
- **The Bluetooth address is derived from the chip's ID, like the WiFi MAC address, and written into `xr_bt.conf` when that file is missing** (2026-10-18). The XR829 has no Bluetooth address of its own. `xr829-attach` reads it from that file, the same file and format TrimUI's `hciattach` used (it made up a random address and saved it there). A derived address stays the same across state wipes and reinstalls, so headphones never need pairing again. A unit that already has a valid saved address keeps it, so its pairings stay. A file that holds no valid address (wrong format, all zero, or a reserved address) is replaced by the derived address, with a warning in the log. Rejected: keeping the saved random address (2026-10-11, commit 425274e; a state wipe means re-pairing everything); deriving it as commit ed92b5d did (2026-10-11), which relied on NextUI's replacement `hciattach`, not TrimUI's; setting it through BlueZ (`btmgmt public-addr` can't work over this serial link).
- **Pairings, the Bluetooth address and saved WiFi networks are kept in the state area on the system partition** (2026-10-14). They survive reboots and system updates.
- **Bluetooth audio goes through bluez-alsa, playback only (A2DP source), with the SBC codec** (2026-10-11). Each paired device becomes an ALSA output. Other codecs are on the roadmap. Each needs a licence check first (fdk-aac's licence, for AAC, is not GPL-compatible) and a check of how much CPU it costs to encode on this chip.

## Design

Hardware:

```
XR829 ─ SDIO, controller sdc1 (Linux mmc2), PG0–PG5, 4-bit, 50 MHz, 3.3 V  ── WiFi; its interrupt is a GPIO edge on PL6
      ─ UART1 = ttyS1, PG6–PG9 (with RTS/CTS)                               ── Bluetooth (H4)
power: BLDO1 3.3 V (main), ALDO3 3.3 V (I/O); WiFi enable PL5; Bluetooth reset PL2, wake PL4, host wake PL3; 32 kHz clock
```

Services (runit, `/etc/sv`):

```
wpa_supplicant  modprobe xr829_wlan; wpa_supplicant -i wlan0 -D nl80211 -c /var/state/wifi/wpa_supplicant.conf   down at start-up
wifi-dhcp       udhcpc -f -i wlan0, once wpa_supplicant runs                                                     down at start-up
xr829-attach    xr829-attach                   Bluetooth: power, firmware upload, address, attach as hci0
bluetoothd      BlueZ, once D-Bus runs
bluealsa        bluealsa -p a2dp-source, once D-Bus runs
```

The state area. `/var/state` links to `/system/state`. The start-up script `/usr/libexec/brick/state` creates it:

```
/var/state/bluetooth/xr_bt.conf        the Bluetooth address: "%02x " per byte, most significant first, trailing space
/var/state/bluetooth/<adapter>/…       BlueZ's pairings (/var/lib/bluetooth links here)
/var/state/wifi/wpa_supplicant.conf    saved networks; ctrl_interface=/run/wpa_supplicant, update_config=1
                                         (wpa_supplicant saves the networks joined in Specular)
```

The first time, the state script copies over the networks in a `wpa_supplicant.conf` at the SD card's root.

What Specular uses:

```
WiFi on        modprobe xr829_wlan; sv up wpa_supplicant wifi-dhcp
WiFi off       sv -v down wifi-dhcp wpa_supplicant; rmmod xr829_wlan
network joined ip -4 addr flush dev wlan0; sv restart wifi-dhcp      (an address at once; none left from the last network)
WiFi control   wpa_supplicant's control socket /run/wpa_supplicant/wlan0
Bluetooth      BlueZ over D-Bus (adapter power, search, pair, connect)
Bluetooth out  ALSA "bluealsa:DEV=<address>,PROFILE=a2dp", with its own volume through bluez-alsa
sleep          sleepnow (see Decisions)
```

The firmware files come from TrimUI's stock system, copied in by `tools/system/build-system.sh`: `boot_xr829.bin`, `fw_xr829.bin`, `sdd_xr829.bin` (radio calibration), `etf_xr829.bin` (test mode) and `fw_xr829_bt.bin`.

Bluetooth start-up (`userspace/xr829-attach`). Most of the time goes to the firmware upload: 320 KB at 1.5 Mbaud take at least 2.1 s.

```
1. power      rfkill switch "sunxi-bt": off 20 ms, on, 20 ms; /proc/bluetooth/sleep/btwake 1, lpm 0
2. boot ROM   ttyS1 at 115200, no flow control
              sync: send 0x55, answer "OK" (or "KO") within 20 ms; up to 16 tries
              SETUART 0x10 (1500000 | 3 << 24), host to 1.5 Mbaud, sync again
              SEQWR 0x09 per 1 KiB of fw_xr829_bt.bin (address, length, data checksum), then the data
              SETPC 0x13 (0): run the firmware
              a failure: power off 500 ms and start again, 3 tries in all
3. firmware   115200 with RTS/CTS: HCI Reset; vendor 0xFC18 60 e3 16 00 (1.5 Mbaud), host to 1.5 Mbaud
              vendor 0xFC0A 02 00 06 + address, least significant byte first; HCI Reset
              HCI Read Local Version Information, logged
4. attach     line discipline N_HCI, protocol H4; wait for SIGTERM/SIGINT/SIGHUP, then back to N_TTY
whole start-up: at most 20 s; any failure: one log line naming the step, exit 1
```

Boot ROM commands, all numbers big-endian on the wire:

```
"BROM"  flags (0x04: checked)  version 0  checksum (2)  payload length (4)  |  command (1)  fields
checksum = ~(sum of 16-bit little-endian words of header + payload), computed with the numbers in
           little-endian order and the checksum field 0; a reply's header sums to 0xffff the same way
reply    = header with flag 0x02 (ack) and length 0, or flag 0x01 (error) and a 1-byte error code
```

The address, when `xr_bt.conf` is missing or holds no valid one: the WiFi driver's chip-ID method with a different salt. FNV-1a (64-bit) over the 16-byte chip ID (the first 16 bytes of `/sys/bus/nvmem/devices/sunxi-sid0/nvmem`, which the kernel's `sunxi_get_soc_chipid()` also returns) and then the byte `'B'` (WiFi: `'W'`). The address is the hash's low 48 bits, most significant first, with bit 1 of the first byte set (locally administered) and bit 0 cleared (unicast). The WiFi and Bluetooth addresses always differ, but share most of their bytes.

## Findings

- (2026-10-10, stock) Stock uses driver version XR_V02.16.93, built as three modules. It carries its own copy of Linux's WiFi stack (mac80211). The board has no MAC address storage: stock expects one from a sunxi address driver that isn't there.
- (2026-10-10, device) The SDIO link runs 4-bit, 50 MHz, 3.3 V (not UHS). WiFi firmware is XR_C09.08.52.73, 2.4 GHz only. The driver also creates a spare `wlan1` for access-point mode.
- (2026-06-23, upstream) PocketForge's chip-ID MAC address stayed the same across 250 reboots and a full reflash, and a second unit got a different one. Source: kernel commit 1c92aa495.
- (2026-10-10, bsp) PocketForge found that the vendor driver's power saving causes deauthentications (LOW_ACK) and stuck scans. They also found that the firmware's key slots get swapped when roaming (their commit bb609ab).
- (2026-10-11, device) The WiFi driver refuses to suspend while connected. Source: `tools/device/sleepnow`.
- (2026-10-10, upstream) On stock, NextUI's suspend script also stops `wpa_supplicant` and `bluetoothd` first, and retries the suspend up to 5 times.
- (2026-10-12, device) Idle with WiFi connected and the screen on: about 20 SDIO interrupts a second and about 33 wakeups a second from the driver's worker thread.
- (2026-10-12, device) For about 5 s after waking, frame rate drops to 20–25 fps while the WiFi firmware reloads and floods the SDIO bus. Once, frames then kept waiting two vsyncs until WiFi was restarted again. That did not happen again in about 48 further sleeps. Source: Brick ROADMAP.md, WiFi row.
- (2026-10-13, device) In deep sleep, the WiFi chip is power-cycled and the Bluetooth adapter is down. The XR829's supply stays on, because Bluetooth stays attached.
- (2026-10-18, device) The controller reports HCI version 7 (Bluetooth 4.1), revision 0x0e19, manufacturer 0x063d (Xradio Technology). Its LE feature mask is `01 00 00 00 00 00 00 00`: only LE encryption, so no LE Data Length Extension, 2M PHY or isochronous channels. LE Audio needs Bluetooth 5.2 with isochronous channels, so this chip can't do it. Source: `/sys/kernel/debug/bluetooth/hci0/{hci_version,hci_revision,manufacturer,features}`, `bluetoothctl show`; company ID from the Bluetooth SIG's assigned numbers.
- (2026-10-18, device) The chip ID is readable by anyone at `/sys/bus/nvmem/devices/sunxi-sid0/nvmem` (the efuse from 0x03006200, the chip-ID block in the device tree). Its first 16 bytes match `sunxi_serial` in `/sys/class/sunxi_info/sys_info`, which is built from the same words. Source: `linux/drivers/nvmem/sun50i_sid.c`, `linux/drivers/soc/sunxi/sunxi-sid.c`.
- (2026-10-18, stock) TrimUI's `hciattach` runs: rfkill off, 20 ms, on, 20 ms, wake pin, LPM off, 5 ms; after 16 unanswered sync bytes, rfkill off 500 ms and on, retrying without end; 1 KiB firmware chunks; then the HCI steps above. BlueZ's `hciattach` gives up after 10 s. Its `printf` log lines are buffered and only reach the log when it exits. Source: disassembly of the stock `/usr/bin/hciattach`, Allwinner's `hciattach_xradio.c` (BlueZ 5.54 patches).
- (2026-10-11, stock) TrimUI's `hciattach` (`hciattach_xradio.c`) takes the address from `/sys/class/addr_mgt/addr_bt` (no such driver here). Failing that, it uses `/etc/bluetooth/xr_bt.conf`. Failing that, it makes up `22:22:xx:xx:xx:xx` and writes it to that file. It sends the address as vendor command 0xFC0A, which survives an HCI reset. On a read-only root filesystem without the link into the state area, it would make up a new address at every boot.
- (2026-10-11, stock) Stock runs BlueZ 5.54, which stores pairings in `/etc/lib/bluetooth`, and bluealsa 3.1.0 (A2DP source). TrimUI's `trimui_btmanager` drives `bluetoothctl`.
- (2026-10-14, device) Stock keeps its WiFi networks and Bluetooth address in its settings area (`rootfs_data`) on the internal storage.
- (2026-10-10, upstream) linux-sunxi describes the XR829 as an XR819 with HT40 plus Bluetooth 2.1+EDR and 4.1 LE, pin-compatible with the XR819. TrimUI's spec sheet says "BT2.1 + EDR/4.2". Source: https://linux-sunxi.org/Wifi.
- (2026-10-10, upstream) Mainline has no XR829 driver. `fifteenhex/xradio` and `dbeinder/xradio` support only the XR819. `dilyn-corner/xr829-struggle` reports WiFi working on 5.15, with Bluetooth not working, and an unfinished 6.7 attempt. `Sakura-Pi/Xradio-XR829-Bluetooth` is BlueZ 5.54 with the xradio `hciattach` patch, which PocketForge uses as a standalone tool. Allwinner's 5.15 BSP tree has the vendor driver. This is the riskiest hardware for a move to a newer kernel.
- (2026-10-14, inferred) With SBC, headsets add about 150–250 ms of delay, most of it the headset's own buffer. aptX Low Latency and aptX Adaptive are closed (libopenaptx has neither). bluez-alsa supports FastStream, but almost no headphones do. LE Audio (LC3) needs a newer Bluetooth controller (see the XR829's version above). Source: Brick ROADMAP.md item 16.
