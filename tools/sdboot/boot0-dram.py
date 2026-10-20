#!/usr/bin/env python3
"""Reads or changes the DRAM parameters in an Allwinner first-stage loader (boot0, "eGON.BT0").

Usage: boot0-dram.py BOOT0                  prints the DRAM parameters
       boot0-dram.py BOOT0 OUT --clk MHZ    writes OUT: BOOT0 with dram_clk set to MHZ and the
                                            header checksum recomputed (boot0 rejects a bad one)

The header: jump(4) magic(8) check_sum(4) length(4) pub_head_size(4) pub_head_vsn(4)
ret_addr(4) run_addr(4) boot_cpu(4) platform(8), then prvt_head_size(4) prvt_head_vsn(4) and
dram_para[32] (u32 each) at byte 56, in the A133's order: dram_clk (MHz), dram_type
(7 = LPDDR3), DX ODT, DX drive, CA drive, para0-2 (geometry), mode registers 0-6, 11-14, 16, 17
and 22, then tpr0-3, 6, 10-14 (tpr10: which PHY trainings run; tpr13 bit 0 clear: the geometry
is auto-scanned; bit 12: eye training).
The checksum is the 32-bit sum of every word of the file with the checksum field itself
counted as 0x5F0A6C39 (toc1.py uses the same scheme for the boot package). Only the clock is
changed: the loader derives its timings from it and trains the PHY at it, or fails to start.
On the TrimUI Brick (LPDDR3, stock 672) 744 and 756 start and pass memory tests, 768 doesn't
start; the PLL multiplier is clock x 2 / 24, so the clock must be a multiple of 12.
"""
import struct, sys

# The A133's layout (linux-sunxi.org/A133/DRAMC); older chips name the same slots differently.
NAMES = (["dram_clk", "dram_type", "dram_dx_odt", "dram_dx_dri", "dram_ca_dri", "dram_para0",
          "dram_para1", "dram_para2"]
         + [f"dram_mr{i}" for i in (0, 1, 2, 3, 4, 5, 6, 11, 12, 13, 14, 16, 17, 22)]
         + [f"dram_tpr{i}" for i in (0, 1, 2, 3, 6, 10, 11, 12, 13, 14)])
STAMP = 0x5F0A6C39
PARA = 56

def checksum(data):
    words = struct.unpack_from("<%dI" % (len(data) // 4), data, 0)
    return (sum(words) - words[3] + STAMP) & 0xFFFFFFFF

def main():
    args = sys.argv[1:]
    data = bytearray(open(args[0], "rb").read())
    assert data[4:12] == b"eGON.BT0", "not a boot0 (no eGON.BT0 magic)"
    stored, length = struct.unpack_from("<II", data, 12)
    assert length == len(data), f"header length {length} != file size {len(data)}"
    print(f"checksum {'OK' if checksum(data) == stored else 'BAD'}")
    para = list(struct.unpack_from("<32I", data, PARA))
    for name, value in zip(NAMES, para):
        print(f"{name:12} 0x{value:08x} {value}")
    if len(args) >= 4 and args[2] == "--clk":
        out, clk = args[1], int(args[3])
        struct.pack_into("<I", data, PARA, clk)
        struct.pack_into("<I", data, 12, checksum(data))
        open(out, "wb").write(data)
        print(f"wrote {out}: dram_clk {para[0]} -> {clk} MHz, checksum 0x{checksum(data):08x}")

main()
