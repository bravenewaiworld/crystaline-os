"""Inspect, validate and repack an Allwinner TOC1 "sunxi-package": the container boot0 loads
from sector 32800 holding U-Boot, the ARM trusted firmware ("monitor"), the power-management
co-processor firmware ("scp") and the device tree ("dtb") the kernel will receive.

CLI: toc1.py FILE [BYTE_OFFSET [EXTRACT_DIR]]
       Prints the items; exits 1 unless the checksum is valid and U-Boot's work_mode is 0 (normal
       boot).
     toc1.py repack FILE OUT NAME=PATH...
       Writes a copy of the package with the named items (e.g. dtb=my.dtb) replaced.
 Any other work_mode makes U-Boot run the vendor flasher, e.g. 0x11 = PhoenixCard
"card product", which rewrites the internal eMMC from the card.
"""
import os, struct, sys

# Allwinner checksums are a 32-bit sum of all words, computed with the checksum field itself
# preset to this placeholder.
STAMP = 0x5F0A6C39
MAGIC = 0x89119800
HEADER_SIZE = 64       # TOC1 main header
ITEM_SIZE = 368        # one item-table entry
WORK_MODE_OFF = 0xE0   # work_mode, then storage_type (0 = boot media), in U-Boot's own header


def checksum(buf, csum_off):
    """Allwinner additive checksum of buf, with the checksum field at csum_off."""
    b = bytearray(buf); b[csum_off:csum_off + 4] = struct.pack('<I', STAMP)
    b += b'\0' * (-len(b) % 4)
    return sum(struct.unpack('<%dI' % (len(b) // 4), b)) & 0xffffffff


def parse(data):
    """Print the package's items and return ({name: payload}, problems list)."""
    name, magic, add_sum, _, _, nr, vlen = struct.unpack_from('<16s6I', data, 0)
    if magic != MAGIC:
        return {}, ['bad magic %#x' % magic]
    problems = []
    computed = checksum(data[:vlen], 20)
    print('toc1 name=%r items=%d valid_len=%d add_sum=%08x computed=%08x'
          % (name.rstrip(b'\0'), nr, vlen, add_sum, computed))
    if computed != add_sum:
        problems.append('checksum mismatch')
    items = {}
    for i in range(nr):
        io = HEADER_SIZE + i * ITEM_SIZE
        iname, doff, dlen, _, _, run = struct.unpack_from('<64s5I', data, io)
        iname = iname.rstrip(b'\0').decode()
        print('  %-10s off=0x%06x len=%7d run=0x%x' % (iname, doff, dlen, run))
        items[iname] = data[doff:doff + dlen]
    if 'u-boot' not in items:
        return items, problems + ['no u-boot item']
    work_mode, storage = struct.unpack_from('<2I', items['u-boot'], WORK_MODE_OFF)
    print('  u-boot work_mode=0x%x storage_type=%d' % (work_mode, storage))
    if work_mode != 0:
        problems.append('work_mode 0x%x would run the vendor flasher' % work_mode)
    return items, problems


def repack(data, replacements):
    """Return a new package with item payloads replaced ({name: bytes}), laid out like the
    stock one (payloads 1 KiB aligned, total 16 KiB aligned) with the checksum recomputed;
    boot0 rejects a package whose checksum doesn't match. Used to swap in our own DTB."""
    nr, = struct.unpack_from('<I', data, 32)
    out = bytearray(data[:HEADER_SIZE + nr * ITEM_SIZE])
    pos = struct.unpack_from('<I', data, HEADER_SIZE + 64)[0]   # first payload offset
    for i in range(nr):
        io = HEADER_SIZE + i * ITEM_SIZE
        name = data[io:io + 64].rstrip(b'\0').decode()
        doff, dlen = struct.unpack_from('<2I', data, io + 64)
        payload = replacements.get(name, data[doff:doff + dlen])
        pos = (pos + 0x3ff) & ~0x3ff
        out += b'\0' * (pos - len(out)); out += payload
        struct.pack_into('<2I', out, io + 64, pos, len(payload))
        pos += len(payload)
    out += b'\0' * (-len(out) % 0x4000)
    struct.pack_into('<I', out, 36, len(out))                   # valid_len
    struct.pack_into('<I', out, 20, checksum(out, 20))          # add_sum
    return bytes(out)


if __name__ == '__main__' and sys.argv[1] == 'repack':
    src, out = sys.argv[2:4]
    repl = {k: open(v, 'rb').read() for k, v in (a.split('=', 1) for a in sys.argv[4:])}
    open(out, 'wb').write(repack(open(src, 'rb').read(), repl))
elif __name__ == '__main__':
    path = sys.argv[1]
    off = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0
    with open(path, 'rb') as f:
        f.seek(off); data = f.read(4 << 20)   # packages are ~1 MiB; boot0 caps them well below 4
    items, problems = parse(data)
    if len(sys.argv) > 3:
        os.makedirs(sys.argv[3], exist_ok=True)
        for k, v in items.items():
            open(os.path.join(sys.argv[3], k + '.bin'), 'wb').write(v)
    for p in problems:
        print('PROBLEM:', p, file=sys.stderr)
    sys.exit(1 if problems else 0)
