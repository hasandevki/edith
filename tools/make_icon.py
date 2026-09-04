"""Uygulama simgesi üretir: icon-source.(png|jpg) varsa onu 1024x1024 siyah zemine oturtur,
yoksa J.A.R.V.I.S tarzı bir halka çizer. Çıktı: Edith/Assets.xcassets/AppIcon.appiconset/AppIcon.png"""
import math, os, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Edith/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
SIZE = 1024

def from_source(path):
    img = Image.open(path).convert("RGBA")
    w, h = img.size
    side = min(w, h)
    img = img.crop(((w - side) // 2, (h - side) // 2, (w + side) // 2, (h + side) // 2))
    img = img.resize((int(SIZE * 0.92), int(SIZE * 0.92)), Image.LANCZOS)
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 255))
    off = (SIZE - img.size[0]) // 2
    canvas.alpha_composite(img, (off, off))
    return canvas.convert("RGB")

def procedural():
    img = Image.new("RGBA", (SIZE, SIZE), (2, 6, 12, 255))
    glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    c = SIZE / 2
    cyan = (64, 200, 255)
    for r, wd in [(430, 22), (372, 8), (300, 40)]:
        g.ellipse([c - r, c - r, c + r, c + r], outline=cyan + (255,), width=wd)
    glow = glow.filter(ImageFilter.GaussianBlur(18))
    img.alpha_composite(glow)
    d = ImageDraw.Draw(img)
    for r, wd, col in [(430, 10, cyan), (372, 4, (120, 220, 255)), (300, 26, (40, 170, 230))]:
        d.ellipse([c - r, c - r, c + r, c + r], outline=col + (255,), width=wd)
    # tik işaretleri
    for i in range(72):
        a = math.radians(i * 5)
        long = i % 6 == 0
        r1, r2 = (395, 352) if long else (395, 372)
        d.line([(c + r1 * math.cos(a), c + r1 * math.sin(a)), (c + r2 * math.cos(a), c + r2 * math.sin(a))],
               fill=(140, 225, 255, 255), width=5 if long else 3)
    # turuncu yay
    d.arc([c - 340, c - 340, c + 340, c + 340], start=150, end=250, fill=(255, 170, 40, 255), width=14)
    # iç disk
    d.ellipse([c - 250, c - 250, c + 250, c + 250], fill=(4, 10, 20, 255))
    # yazı
    font = None
    for path in [r"C:\Windows\Fonts\arialbd.ttf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf"]:
        if os.path.exists(path):
            font = ImageFont.truetype(path, 120)
            break
    font = font or ImageFont.load_default()
    text = "J.A.R.V.I.S."
    bbox = d.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    d.text((c - tw / 2 - bbox[0], c - th / 2 - bbox[1]), text, font=font, fill=(235, 250, 255, 255))
    return img.convert("RGB")

src = next((os.path.join(ROOT, n) for n in ["icon-source.png", "icon-source.jpg", "icon-source.jpeg"] if os.path.exists(os.path.join(ROOT, n))), None)
icon = from_source(src) if src else procedural()
os.makedirs(os.path.dirname(OUT), exist_ok=True)
icon.save(OUT, "PNG", optimize=True)
print("kaynak:", os.path.basename(src) if src else "prosedürel", "->", OUT, icon.size)
