# Draws the hex-ios-keyboard app icon. Usage: python3 tools/make_icon.py VoiceKeyboard/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import math, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 4096            # draw at 4x, downsample to 1024
C = S / 2
k = S / 1024

def hexagon(r, cx=C, cy=C):
    # pointy-top hexagon
    return [(cx + r * math.cos(math.radians(-90 + 60 * i)), cy + r * math.sin(math.radians(-90 + 60 * i))) for i in range(6)]

def vgrad(top, bottom, size=S):
    g = Image.new("RGB", (1, 256))
    for y in range(256):
        t = y / 255
        g.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return g.resize((size, size), Image.BICUBIC)

def outline_mask(r, width):
    m = Image.new("L", (S, S), 0)
    pts = hexagon(r)
    ImageDraw.Draw(m).line(pts + pts[:2], fill=255, width=round(width), joint="curve")
    return m

def filled_mask(r, corner):
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    pts = hexagon(r - corner)
    d.polygon(pts, fill=255)
    d.line(pts + pts[:2], fill=255, width=round(corner * 2), joint="curve")
    return m

# Background: dark graphite, lighter at the top.
img = vgrad((52, 52, 52), (14, 14, 14))

outer = outline_mask(398 * k, 50 * k)
middle = outline_mask(262 * k, 46 * k)
core = filled_mask(138 * k, 16 * k)
shapes = ImageChops.lighter(ImageChops.lighter(outer, middle), core)

# Soft drop shadow under the metal.
shadow = shapes.transform((S, S), Image.AFFINE, (1, 0, 0, 0, 1, -10 * k)).filter(ImageFilter.GaussianBlur(14 * k))
img = Image.composite(Image.new("RGB", (S, S), (0, 0, 0)), img, shadow.point(lambda v: v * 0.7))

# Brushed-silver body.
img = Image.composite(vgrad((226, 226, 226), (168, 168, 168)), img, shapes)

# Bevel: a brighter ridge running along the top of each stroke.
ridge = ImageChops.lighter(outline_mask(398 * k, 22 * k), outline_mask(262 * k, 20 * k))
ridge = ridge.transform((S, S), Image.AFFINE, (1, 0, 0, 0, 1, 5 * k)).filter(ImageFilter.GaussianBlur(5 * k))
ridge = ImageChops.multiply(ridge, shapes)
img = Image.composite(vgrad((255, 255, 255), (214, 214, 214)), img, ridge.point(lambda v: v * 0.85))

# Core: lighter face with a gentle top highlight.
core_face = filled_mask(124 * k, 14 * k).filter(ImageFilter.GaussianBlur(4 * k))
img = Image.composite(vgrad((246, 246, 246), (200, 200, 200)), img, core_face.point(lambda v: v * 0.8))

out = img.resize((1024, 1024), Image.LANCZOS)
out.save(sys.argv[1])
