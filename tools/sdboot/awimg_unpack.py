# Unpack Allwinner IMAGEWTY (v3 header, unencrypted) firmware images.
import struct, sys, os
src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
with open(src, 'rb') as f:
    hdr = f.read(0x60)
    assert hdr[:8] == b'IMAGEWTY'
    nfiles = struct.unpack_from('<I', hdr, 0x3c)[0]
    for i in range(nfiles):
        f.seek(0x400 + i * 0x400)
        fh = f.read(0x400)
        main = fh[8:16].decode().strip(); sub = fh[16:32].decode(errors='replace')
        name = fh[0x24:0x124].split(b'\0')[0].decode()
        stored, orig, off = struct.unpack_from('<I', fh, 0x124)[0], struct.unpack_from('<I', fh, 0x12c)[0], struct.unpack_from('<I', fh, 0x134)[0]
        print(f'{i:2} {main:8} {sub:16} {name:40} orig={orig:>11} off={off:#x}')
        f.seek(off)
        dst = os.path.join(out, os.path.basename(name.replace('\\', '/')))
        with open(dst, 'wb') as o:
            remaining = orig
            while remaining:
                chunk = f.read(min(remaining, 1 << 24)); o.write(chunk); remaining -= len(chunk)
