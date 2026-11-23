#!/usr/bin/env python3
"""Generates FAbrowser app icons (default + alternates) and color sets into Assets.xcassets."""
import json, os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.join(os.path.dirname(__file__), "..", "FAbrowser", "Assets.xcassets")
S = 1024
VARIANTS = {
    "AppIcon": ((46, 124, 246), (20, 88, 214)),
    "AppIcon-Black": ((44, 44, 48), (8, 8, 10)),
    "AppIcon-Green": ((52, 199, 89), (22, 150, 70)),
    "AppIcon-Red": ((255, 82, 82), (210, 30, 50)),
    "AppIcon-Orange": ((255, 159, 10), (240, 110, 0)),
    "AppIcon-Purple": ((175, 82, 222), (110, 50, 190)),
}

def font(size):
    for path, idx in [("/System/Library/Fonts/Avenir Next.ttc", 2), ("/System/Library/Fonts/HelveticaNeue.ttc", 1)]:
        try:
            return ImageFont.truetype(path, size, index=idx)
        except Exception:
            pass
    return ImageFont.load_default()

def icon(top, bottom):
    img = Image.new("RGB", (S, S))
    px = img.load()
    for y in range(S):
        t = y / (S - 1)
        c = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
        for x in range(S):
            px[x, y] = c
    d = ImageDraw.Draw(img, "RGBA")
    # globe ring
    cx, cy, r = S // 2, S // 2, 330
    d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=(255, 255, 255, 235), width=44)
    d.ellipse((cx - r * 0.42, cy - r, cx + r * 0.42, cy + r), outline=(255, 255, 255, 90), width=20)
    d.line((cx - r, cy, cx + r, cy), fill=(255, 255, 255, 90), width=20)
    # compass needle
    d.polygon([(cx + 200, cy - 200), (cx + 40, cy - 40), (cx - 40, cy + 40)], fill=(255, 255, 255, 255))
    d.polygon([(cx - 200, cy + 200), (cx - 40, cy + 40), (cx + 40, cy - 40)], fill=(255, 255, 255, 150))
    d.ellipse((cx - 34, cy - 34, cx + 34, cy + 34), fill=top + (255,))
    f = font(150)
    text = "FA"
    w = d.textlength(text, font=f)
    d.text(((S - w) / 2, S - 215), text, font=f, fill=(255, 255, 255, 255))
    return img

def write_iconset(name, colors):
    folder = os.path.join(ROOT, f"{name}.appiconset")
    os.makedirs(folder, exist_ok=True)
    icon(*colors).save(os.path.join(folder, "icon-1024.png"))
    json.dump({"images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
               "info": {"author": "xcode", "version": 1}}, open(os.path.join(folder, "Contents.json"), "w"), indent=2)

def write_color(name, light, dark):
    folder = os.path.join(ROOT, f"{name}.colorset")
    os.makedirs(folder, exist_ok=True)
    def comp(c):
        return {"color-space": "srgb", "components": {"red": f"{c[0]/255:.3f}", "green": f"{c[1]/255:.3f}", "blue": f"{c[2]/255:.3f}", "alpha": "1.000"}}
    json.dump({"colors": [
        {"idiom": "universal", "color": comp(light)},
        {"idiom": "universal", "appearances": [{"appearance": "luminosity", "value": "dark"}], "color": comp(dark)},
    ], "info": {"author": "xcode", "version": 1}}, open(os.path.join(folder, "Contents.json"), "w"), indent=2)

os.makedirs(ROOT, exist_ok=True)
json.dump({"info": {"author": "xcode", "version": 1}}, open(os.path.join(ROOT, "Contents.json"), "w"), indent=2)
for n, c in VARIANTS.items():
    write_iconset(n, c)
write_color("LaunchBackground", (255, 255, 255), (0, 0, 0))
write_color("AccentColor", (46, 124, 246), (64, 140, 255))
# small preview images of the alternate icons for the in-app picker
for n, c in VARIANTS.items():
    folder = os.path.join(ROOT, f"{n}-Preview.imageset")
    os.makedirs(folder, exist_ok=True)
    icon(*c).resize((180, 180), Image.LANCZOS).save(os.path.join(folder, "preview.png"))
    json.dump({"images": [{"filename": "preview.png", "idiom": "universal", "scale": "3x"}], "info": {"author": "xcode", "version": 1}},
              open(os.path.join(folder, "Contents.json"), "w"), indent=2)
print("ok")
