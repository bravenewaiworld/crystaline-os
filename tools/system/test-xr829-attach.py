#!/usr/bin/env python3
"""A fake XR829 Bluetooth chip for test-xr829-attach.sh.

Runs a PC build of xr829-attach with its serial port (ROOT/dev/ttyS1) on a pty and answers as
the chip does: first its boot ROM, then its firmware, as Xradio's hciattach_xradio.c talks to
them. It checks what the program sends: the boot ROM commands' checksums, the port's speed and
flow control at each stage, and the uploaded firmware (against ROOT/lib/firmware). It prints the
program's log, then its own lines: "fake: HCI <opcode> <parameters>" per HCI command,
"fake: exit <status>", "fake: firmware matches" and "fake: FAIL: <why>" for each problem.

Usage: test-xr829-attach.py BINARY ROOT MODE, where MODE is
  ok      everything answers
  late    the boot ROM answers only from the 20th sync byte (after a power-cycle retry)
  mute    the boot ROM never answers
  romerr  the boot ROM reports error 3 (bad checksum) for the chunk at byte 2048
  event   an unrelated HCI event comes before each HCI Reset's reply
  refuse  the set-address command is refused (Command Status, status 0x0c)
  flood   after the first HCI Reset, only unrelated events come, every 0.2 s
"""
import os
import select
import struct
import subprocess
import sys
import termios
import time

binary, root, mode = sys.argv[1:4]
master, slave = os.openpty()
os.symlink(os.ttyname(slave), root + "/dev/ttyS1")
log = subprocess.Popen([binary], stderr=subprocess.PIPE, text=True)
buf = bytearray()
problems = []
deadline = time.time() + 40


class Exited(Exception):
    pass


def need(n):
    """The next n bytes from the program; Exited once it has exited with nothing more sent."""
    while len(buf) < n:
        if select.select([master], [], [], 0.1)[0]:
            buf.extend(os.read(master, 4096))
        elif log.poll() is not None:
            raise Exited
        elif time.time() > deadline:
            problems.append("the program is stuck")
            raise Exited
    out = bytes(buf[:n])
    del buf[:n]
    return out


def sum16(b):
    s = sum(b[i] | b[i + 1] << 8 for i in range(0, len(b) - 1, 2))
    return (s + (b[-1] if len(b) & 1 else 0)) & 0xFFFF


def check_port(stage, speed, flow):
    t = termios.tcgetattr(slave)
    got = (t[4], bool(t[2] & termios.CRTSCTS))
    if got != (speed, flow):
        problems.append("port at %s: speed %s, flow control %s; expected %s, %s"
                        % (stage, got[0], got[1], speed, flow))


def ack():
    h = bytearray(b"BROM\x06\0\0\0\0\0\0\0")       # ack, checked; payload length 0
    h[6:8] = struct.pack(">H", ~sum16(h) & 0xFFFF)   # summed little-endian, sent big-endian
    os.write(master, bytes(h))


def boot_rom_command():
    """Read a command after its "B"; check its checksum; return (command, numbers)."""
    h = b"B" + need(11)
    payload = need(struct.unpack(">I", h[8:12])[0])
    if h[:4] != b"BROM" or h[4] != 0x04 or h[5] != 0:
        problems.append("bad header " + h.hex())
    sizes = {0x09: (4, 4, 2), 0x10: (4,), 0x13: (4,)}.get(payload[0])
    if sizes is None:
        problems.append("unknown boot ROM command %#x" % payload[0])
        raise Exited
    numbers, little, at = [], bytearray(payload[:1]), 1
    for size in sizes:
        v = int.from_bytes(payload[at:at + size], "big")
        numbers.append(v)
        little += v.to_bytes(size, "little")
        at += size
    header = h[:6] + struct.unpack(">H", h[6:8])[0].to_bytes(2, "little") + \
        len(payload).to_bytes(4, "little")
    if sum16(header + little) != 0xFFFF:
        problems.append("bad checksum: " + (h + payload).hex())
    return payload[0], numbers


def hci_reply(opcode, ret=b""):
    os.write(master, bytes([4, 0x0E, 4 + len(ret), 5]) + struct.pack("<HB", opcode, 0) + ret)


memory = bytearray()
syncs = 0
fast = False      # boot ROM at 1.5 Mbaud, after SETUART
try:
    while True:   # boot ROM
        b = need(1)
        if b == b"\x55":
            check_port("boot ROM sync", termios.B1500000 if fast else termios.B115200, False)
            syncs += 1
            if mode != "mute" and (mode != "late" or syncs >= 20):
                os.write(master, b"OK")
            continue
        if b != b"B":
            problems.append("unexpected byte %s for the boot ROM" % b.hex())
            raise Exited
        command, numbers = boot_rom_command()
        if command == 0x10:
            if numbers != [1500000 | 3 << 24]:
                problems.append("SETUART %#x" % numbers[0])
            ack()
            fast = True
        elif command == 0x09:
            addr, n, dcs = numbers
            if mode == "romerr" and addr == 2048:
                os.write(master, b"BROM\x01\0\0\0\0\0\0\0\x03")
                fast = False    # the program power-cycles the chip and starts again
                continue
            ack()
            data = need(n)
            if ~sum16(data) & 0xFFFF != dcs:
                problems.append("bad data checksum at byte %d" % addr)
            memory[addr:addr + n] = data
            ack()
        elif command == 0x13:
            if numbers != [0]:
                problems.append("SETPC %#x" % numbers[0])
            ack()
            break

    baud = termios.B115200
    while True:   # firmware: HCI over H4
        h = need(4)
        if h[0] != 1:
            problems.append("not an HCI command: " + h.hex())
            raise Exited
        opcode = h[1] | h[2] << 8
        param = need(h[3])
        print("fake: HCI %#06x %s" % (opcode, param.hex()))
        check_port("HCI command %#06x" % opcode, baud, True)
        if opcode == 0x0C03 and mode == "event":
            os.write(master, bytes([4, 0x13, 1, 0]))
        if opcode == 0x0C03 and mode == "flood":
            while log.poll() is None and time.time() < deadline:
                os.write(master, bytes([4, 0x13, 1, 0]))
                time.sleep(0.2)
            raise Exited
        if opcode == 0xFC0A and mode == "refuse":
            os.write(master, bytes([4, 0x0F, 4, 0x0C, 5]) + struct.pack("<H", opcode))
            continue
        # Read Local Version: HCI 7, revision 0x0e19, LMP 7, Xradio (0x063d), subversion 0x1234
        hci_reply(opcode, bytes([7, 0x19, 0x0E, 7, 0x3D, 0x06, 0x34, 0x12])
                  if opcode == 0x1001 else b"")
        if opcode == 0xFC18:
            baud = termios.B1500000
except Exited:
    pass
finally:
    if log.poll() is None:
        log.kill()
    sys.stdout.write(log.stderr.read())
print("fake: exit %d" % log.wait())
with open(root + "/lib/firmware/fw_xr829_bt.bin", "rb") as f:
    if bytes(memory) == f.read():
        print("fake: firmware matches")
for p in problems:
    print("fake: FAIL: " + p)
