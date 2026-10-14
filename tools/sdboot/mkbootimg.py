"""Build an Android v0 boot image (what vendor U-Boot's `bootm` loads from the "boot"
partition) by taking a stock image as the template and swapping in a new kernel.

Usage: mkbootimg.py [--ramdisk FILE] TEMPLATE_BOOT_IMG KERNEL OUT [EXTRA_CMDLINE]
Keeps the template's load addresses and page size, and its ramdisk unless --ramdisk gives one
(the stock ramdisk is a 12-byte placeholder, so reusing it is harmless). EXTRA_CMDLINE is
appended to the header's command line, which U-Boot adds after its own boot arguments.

v0 header: magic[8], then u32 kernel size/addr, ramdisk size/addr, second size/addr, tags
addr, page size; name[16] at 48; cmdline[512] at 64; id[32] at 576. Payloads follow, each
padded to the page size.
"""
import hashlib, struct, sys

args = sys.argv[1:]
ramdisk_path = None
if args[:1] == ['--ramdisk']:
    ramdisk_path, args = args[1], args[2:]
template, kernel_path, out = args[:3]
extra = args[3] if len(args) > 3 else ''
t = open(template, 'rb').read()
assert t[:8] == b'ANDROID!', 'template is not an Android boot image'
ksz, kaddr, rsz, raddr, ssz, _, _, page = struct.unpack_from('<8I', t, 8)
assert ssz == 0, 'template has a second-stage image; not supported'
align = lambda n: -(-n // page) * page
ramdisk = t[page + align(ksz):page + align(ksz) + rsz]
if ramdisk_path:
    ramdisk = open(ramdisk_path, 'rb').read()
kernel = open(kernel_path, 'rb').read()

# An arm64 Image header records the kernel's full in-memory size (including zeroed data) at
# byte 16; it must not run into the ramdisk's load address.
mem_size = struct.unpack_from('<Q', kernel, 16)[0] or len(kernel)
assert kaddr + mem_size <= raddr, 'kernel would overlap the ramdisk load address'

cmdline = t[64:64 + 512].split(b'\0')[0].decode()
cmdline = (cmdline + ' ' + extra).strip().encode()
assert len(cmdline) < 512, 'command line too long for the v0 header'

# The id field is SHA-1 over each payload followed by its size: kernel, ramdisk, then the
# (empty) second-stage image, as AOSP mkbootimg does.
sha = hashlib.sha1()
for blob in (kernel, ramdisk, b''):
    sha.update(blob); sha.update(struct.pack('<I', len(blob)))

hdr = bytearray(t[:page])
struct.pack_into('<I', hdr, 8, len(kernel))
struct.pack_into('<I', hdr, 16, len(ramdisk))
hdr[64:64 + 512] = cmdline.ljust(512, b'\0')
hdr[576:576 + 32] = sha.digest().ljust(32, b'\0')
with open(out, 'wb') as f:
    f.write(hdr)
    f.write(kernel.ljust(align(len(kernel)), b'\0'))
    f.write(ramdisk.ljust(align(len(ramdisk)), b'\0'))
print('kernel %d bytes at %#x, cmdline: %s' % (len(kernel), kaddr, cmdline.decode()))
