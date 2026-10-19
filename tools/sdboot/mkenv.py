"""Build a vendor U-Boot env image from a base env image plus overrides, printing the result.

Usage: mkenv.py BASE_ENV OUT SIZE [key=value | key+=text | -key]...
Applied in order: set key, append text to key's value, remove key.
SIZE must equal U-Boot's env size (0x20000 for the Brick); the base image's CRC is checked
against it. Format is U-Boot's "redundant" env (used when two env copies exist): crc32 of
bytes 5..SIZE at 0, a flags byte at 4 (a save counter; written as 1, as in TrimUI's image), then
NUL-separated "key=value" strings ending with an empty one.
"""
import struct, sys, zlib
base, out, size = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)
d = open(base, 'rb').read()
assert struct.unpack_from('<I', d)[0] == zlib.crc32(d[5:size]), 'base env CRC mismatch'
env = {}
for kv in d[5:size].split(b'\0\0')[0].split(b'\0'):
    k, _, v = kv.decode().partition('='); env[k] = v
for arg in sys.argv[4:]:
    k, _, v = arg.partition('=')
    if arg.startswith('-'): env.pop(arg[1:], None)
    elif k.endswith('+'): env[k[:-1]] = env.get(k[:-1], '') + v
    else: env[k] = v
data = b''.join(f'{k}={v}'.encode() + b'\0' for k, v in env.items()) + b'\0'
data = data.ljust(size - 5, b'\0')
open(out, 'wb').write(struct.pack('<I', zlib.crc32(data)) + b'\x01' + data)
for k, v in env.items(): print(f'{k}={v}')
