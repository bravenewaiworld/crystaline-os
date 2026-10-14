"""Copy TrimUI's boot-resource FAT image (the "bootloader" partition: pictures U-Boot reads by
name) with bootlogo.bmp replaced. Overwrites the stock logo's bytes in place, so it needs neither
root rights (no loop mount) nor mtools; the new logo must therefore be the same size as the stock
one (a 396x66 24-bit BMP), and the stock one must be stored contiguously in the image (it is).

Usage: replace-bootlogo.py BOOT_RESOURCE_FEX NEW_LOGO_BMP OUT
"""
import subprocess, sys

fat = bytearray(open(sys.argv[1], 'rb').read())
new = open(sys.argv[2], 'rb').read()
old = subprocess.run(['7z', 'e', '-so', sys.argv[1], 'bootlogo.bmp'], capture_output=True).stdout
# 7z exits non-zero on this image (it is shorter than the FAT claims) but still extracts.
assert old, '7z could not extract bootlogo.bmp'
assert len(old) == len(new), 'logo size differs from stock bootlogo.bmp'
at = fat.find(old)
assert at > 0, 'stock bootlogo.bmp not stored contiguously'
fat[at:at + len(new)] = new
open(sys.argv[3], 'wb').write(fat)
