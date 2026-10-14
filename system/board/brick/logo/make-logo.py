"""Draws our boot logo: TrimUI's (three hexagons and the name) redrawn in Specular's look, so
our system's start is easy to tell from TrimUI's. Hexagons in flat colours, Specular's default accents
(teal, coral), the name in Geist; on black, like the screen around it. The size must stay 396x66
(the size of TrimUI's bootlogo.bmp, which it replaces in place: see replace-bootlogo.py).

Usage: make-logo.py GEIST_TTF OUT.bmp [OUT.png]   (the PNG is a preview)
"""
import math, sys
from PIL import Image, ImageDraw, ImageFont

W, H, S = 396, 66, 4                 # S: drawn at 4x, then scaled down for smooth edges
TEAL, CORAL, FG = (0x2e, 0xc4, 0xb6), (0xf2, 0x66, 0x5e), (0xf2, 0xf2, 0xf2)
img = Image.new('RGB', (W * S, H * S), (0, 0, 0))
d = ImageDraw.Draw(img)

def hexagon(cx, cy, r, fill):
    """A hexagon with a point at the top and bottom, of circumradius r."""
    pts = [(cx + r * math.cos(math.radians(90 + 60 * i)), cy + r * math.sin(math.radians(90 + 60 * i))) for i in range(6)]
    d.polygon([(x * S, y * S) for x, y in pts], fill=fill)

font = ImageFont.truetype(sys.argv[1], 50 * S)
try:
    font.set_variation_by_name('SemiBold')
except (OSError, ValueError):
    pass                             # not a variable font: its one weight
NAME, TRACK = 'TRIMUI', 8            # letter-spaced, as Specular's captions
text_w = sum(font.getlength(c) for c in NAME) / S + TRACK * (len(NAME) - 1)

# The mark: one hexagon on top of two, as TrimUI's, with gaps between them. U-Boot centres the
# picture on the screen, so mark and name are centred within it. (The mark sits 2 px above
# centre: it looks centred against the capitals' height that way.)
r, gap, space = 13.5, 2.5, 18        # hexagon radius, gap between hexagons, mark to name
w = math.sqrt(3) * r                 # a hexagon's width across its flat sides
left = (W - (2 * w + gap + space + text_w)) / 2
cx, cy = left + w + gap / 2, H / 2
hexagon(cx, cy - 0.75 * r - gap / 2 - 2, r, CORAL)
hexagon(cx - (w + gap) / 2, cy + 0.75 * r - 2, r, TEAL)
hexagon(cx + (w + gap) / 2, cy + 0.75 * r - 2, r, TEAL)

x = left + 2 * w + gap + space
for ch in NAME:
    d.text((x * S, H * S / 2), ch, font=font, fill=FG, anchor='lm')
    x += font.getlength(ch) / S + TRACK
img = img.resize((W, H), Image.LANCZOS)
img.save(sys.argv[2], format='BMP')
if len(sys.argv) > 3:
    img.save(sys.argv[3])
