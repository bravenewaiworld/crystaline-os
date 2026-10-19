"""Show which U-Boot settings TrimUI's U-Boot will use on a disk (an image file or a device such
as /dev/mmcblk0), read independently of brick-install: for tests, and to look at a card or a dump.

Usage: uboot-env.py DISK [KEY]
Finds the env and env-redund partitions by GPT name and prints each copy's state ("env: crc ok
flags 3", "env-redund: crc bad"), the copy U-Boot picks ("picked: env"), then the picked copy's
key=value lines; with KEY, only that key's value (exit status 1 if it isn't set). Exit status 2 if
neither copy is good (U-Boot would then fall back to its built-in settings).

U-Boot's rule (env_import_redund): a copy with a bad CRC loses; of two good ones the higher flags
byte wins, except that 0 beats 255 (the counter wraps); equal flags: env. The format is described in mkenv.py.
"""
import struct, sys, zlib

SIZE = 0x20000
disk, key = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None
f = open(disk, 'rb')

def read(at, n):
    f.seek(at)
    return f.read(n)

# The GPT: header in sector 1, then its entries (start sector at 32, name as UTF-16 at 56).
h = read(512, 92)
assert h[:8] == b'EFI PART', f'{disk}: no GPT'
entries_at, count, esize = struct.unpack_from('<QII', h, 72)
parts = {}
for i in range(count):
    e = read(entries_at * 512 + i * esize, esize)
    name = e[56:128].decode('utf-16-le').split('\0')[0]
    if name: parts[name] = struct.unpack_from('<Q', e, 32)[0] * 512

copies = {}
for name in ('env', 'env-redund'):
    d = read(parts[name], SIZE)
    ok = struct.unpack_from('<I', d)[0] == zlib.crc32(d[5:])
    copies[name] = (ok, d[4], d)
    if key is None: print(f'{name}: crc ok flags {d[4]}' if ok else f'{name}: crc bad')

(ok1, f1, _), (ok2, f2, _) = copies['env'], copies['env-redund']
if not ok1 and not ok2:
    print('picked: none', file=sys.stderr); sys.exit(2)
redund = not ok1 or (ok2 and (f1, f2) != (0, 255) and ((f1, f2) == (255, 0) or f2 > f1))
picked = 'env-redund' if redund else 'env'
if key is None: print(f'picked: {picked}')

pairs = [kv.decode().partition('=') for kv in copies[picked][2][5:].split(b'\0\0')[0].split(b'\0') if kv]
if key is None:
    for k, _, v in pairs: print(f'{k}={v}')
else:
    values = [v for k, _, v in pairs if k == key]
    if not values: sys.exit(1)
    print(values[0])
