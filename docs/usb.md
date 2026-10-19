# USB

Status: In progress · Updated: 2026-10-18

The Brick's two USB-C ports: how the bottom port decides between charging from a PC, powering a USB device and doing nothing, the network link to a PC that development and file transfer use, and what is planned for USB mass storage, USB drives and USB audio. The bottom port is also the charging port, so its cable detection sets the charging current ([power.md](power.md)).

## Decisions

- **The bottom port's role follows the power chip's USB-C cable detection** (2026-10-11). The AXP2202 runs the standard USB-C attach state machine; our driver reports it as extcon cables and the vendor port manager switches role from them: device mode when powered by a computer or charger, host with 5 V when a device needs power, off when unplugged. Rejected: the port manager's ID-pin polling (the ID pin, PH8, never changes on this board), and TrimUI's role fixed by a setting and scripts.
- **The power chip's charger detection (BC1.2) is on and sets the input current limit itself** (2026-10-11). Its result can't be re-run from software, so when booted already plugged in the driver applies the stored result at probe.
- **5 V for a device on the bottom port comes from the AXP2202's boost plus its VBUS switch** (register 0x19 bit 4 and 0x13 bit 0), as TrimUI's kernel does it (2026-10-11). Mainline's AXP717 boost regulator sets only the first, which gives 0 V here.
- **Device mode is a USB network link (NCM)** (2026-10-10). Linux PCs support NCM without drivers. Rejected: adb (TrimUI's; our system has no `adbd`, and TrimUI's kills a session's processes when it ends); RNDIS (never weighed: NCM was picked to get SSH from a Linux development PC); MTP and USB mass storage for now (they race with the system's own writes and corrupt the card; [system-image.md](system-image.md)).
- **The link uses fixed addresses: the Brick is 192.168.7.2 and hands the PC one of 192.168.7.10–20 by DHCP, with no gateway or DNS** (2026-10-11), so the PC's internet routing is untouched and scripts can reach the device without discovery.
- **The top port is host only, with its 5 V on while awake and off in sleep** (2026-10-12). It has no ID or CC detection, so there is nothing to switch on, and a user plugging in a pad or a drive expects it to work.
- **Specular may switch the top port off while awake: `brick-power usb-top off`, refused while a USB device is attached** (2026-10-18). It unbinds the port's two host-controller drivers (`sunxi-ohci`, `sunxi-ehci` for `5200000.*1-controller`), the only users of its 5 V regulator (`usb1-vbus`, PL8), which also stops their clocks and the port's PHY clock; `on` binds them again. Refused with a device attached, since a drive in use would be cut off; Specular asks the user. Nothing persists: each start-up begins with the port on ([power.md](power.md)). Rejected: a regulator "userspace consumer" (not built, and the host drivers hold the regulator, so it would stay on); the vendor drivers' `ehci_enable`/`ohci_enable` files (not symmetric: writing 1 switches the 5 V back on only for port 0).
- **Nothing on a USB drive is mounted automatically** (2026-10-11). Stock's automounting mounted drives over the data card's mount point, hiding it. When to mount a drive on either port, where (not over the data card) and how to remove it safely is decided once there is a use for drives, e.g. games on a drive (2026-10-18).
- **Sharing the card with a PC (planned for V1): Specular hands it over on request** (2026-10-18). It saves and quits any game, stops everything that writes the data partition (WebDAV, logs), unmounts it and exposes it as USB mass storage. When the PC ejects it or the cable is pulled, the device runs a FAT check and mounts it again; that check also repairs a cable pulled mid-write.

## Design

### Ports

| | Bottom USB-C (USB0) | Top USB-C (USB1) |
|---|---|---|
| Roles | device (MUSB `udc`) or host (`ehci0`/`ohci0`) | host only (`ehci1`/`ohci1`) |
| Role chosen by | AXP2202 USB-C state, through extcon | – |
| 5 V out | AXP2202 `drivevbus` regulator, in host role | PL8, a fixed regulator, on while awake unless switched off (`brick-power usb-top`) |
| Charging | yes; limit from BC1.2 | no |

### Role from cable state

```
AXP2202 register 0xE7, low nibble     extcon cable                  role
1, 4  unattached (toggling)           none                          off ("null")
3     attached as sink (we're powered) EXTCON_USB + EXTCON_CHG_USB_*  device: network link
6     attached as source (we power)    EXTCON_USB_HOST                host, 5 V on
```

Cables and the charger type are readable under `/sys/class/extcon`. `usb_otg_id_status()` answers from the host cable, because the vendor host code refuses to switch 5 V on while the ID pin reads high.

### Network link

The `usb` service builds the gadget through configfs, once per boot:

```
/sys/kernel/config/usb_gadget/brick
  idVendor 0x1d6b, idProduct 0x0104   Linux Foundation "multifunction composite gadget"
  strings: manufacturer/product "Brick", serialnumber = androidboot.serialno from U-Boot
  configs/c.1: self-powered (0xc0), MaxPower 500 mA, function ncm.usb0
  UDC = the only controller in /sys/class/udc
usb0 192.168.7.2/24;  udhcpd: 192.168.7.10-20, leases in /run, no router or DNS options
```

SSH and the WebDAV server listen on it as on WiFi ([system-image.md](system-image.md)).

### Kernel support present

NCM, mass storage, FunctionFS and MTP/PTP gadget functions; USB storage (host); USB audio (`snd-usb-audio`, built in).

## Findings

- (2026-10-11, device) The AXP2202's USB-C state is the low nibble of register 0xE7: 1/4 unattached (toggling between sink and source), 2 attach-wait as sink, 3 attached as sink (dock or charger: 0xE7 = 0xB3), 6 attached as source (a USB drive: 0xE7 = 0x46). Register 0xE9 differs per source (dock 0x47, MacBook charger 0x74), possibly the current the source advertises. Source: cable test with a Thunderbolt dock, a MacBook USB-C charger and a USB drive.
- (2026-10-11, device) The ID pin (PH8) never changes, whatever is plugged in. Source: same cable test.
- (2026-10-11, device) With BC1.2 detection on (0x0B bit 4), the dock and the MacBook charger both report 0x05 = 0x70 (bits 7:5 = 3, "DCP" in mainline's mapping) and the chip sets a 3000 mA input limit itself (0x17 = 0x3A); with nothing connected it reads 2000 mA. Gadget enumeration over the dock still works. No plain PC port was tested. Source: same cable test.
- (2026-10-11, device) The BC1.2 result can't be cleared or re-run from software (0x05 is read-only; toggling 0x0B bit 4 or 0x17 bit 7 does nothing), and the chip applies it to the input limit only on plug-in. Source: device test.
- (2026-10-11, stock) TrimUI's OTG 5 V needs 0x13 bit 0 and 0x19 bit 4 both set; then VBUS measures 5.11 V and a drive on the bottom port enumerates. Source: TrimUI's `drivevbus` regulator, disassembled.
- (2026-10-11, device) The top port enumerates a USB drive with no action; its 5 V (PL8) and host controller are always on in stock. Source: device test.
- (2026-10-11, device) The power chip's VBUS voltage reads 0 until its ADC channel (0xC0 bit 2) is switched on, which our driver now does. Source: device test.
- (2026-10-10, bsp) In the vendor port manager, merely *reading* `/sys/devices/platform/soc/usbc0/usb_device`, `usb_host` or `usb_null` switches the bottom port to that role; TrimUI's `usb_device.sh` relies on this. `otg_role` is the plain state. Source: Sonic Pad kernel source.
- (2026-10-10, bsp) Device mode needs VBUS detection from an AXP2202 USB power-supply driver, which the Sonic Pad source lacks, so its gadget never starts. Our AXP2202 drivers (2026-10-11) provide it. Source: Sonic Pad kernel source.
- (2026-10-10, stock) Stock's gadget: `adbd` at start-up (Google's ID 18d1:D002, product "SmartPro") and `MtpDaemon`; `setusbconfig` switches between adb, MTP, mass storage, RNDIS, UAC1, HID. Its USB storage app unmounts the card, exports the whole `/dev/mmcblk1` as mass storage, and runs `fsck` afterwards. Source: stock rootfs.
