"""Generates BOT's app icon: a friendly robot head, blue and white.

Run: python scripts/gen_icon.py
Writes Resources/AppIcons/*.png (legacy sizes embedded by the CI workflow) and
Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png, plus Preview/icon-preview.png.
Everything is drawn at 2x and downsampled for smooth edges. No alpha channel (iOS requires it).
"""
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 2048          # supersampled canvas
OUT = 1024

SIZES = {
    "AppIcon20x20@2x": 40, "AppIcon20x20@3x": 60,
    "AppIcon29x29@2x": 58, "AppIcon29x29@3x": 87,
    "AppIcon40x40@2x": 80, "AppIcon40x40@3x": 120,
    "AppIcon60x60@2x": 120, "AppIcon60x60@3x": 180,
}


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient_bg(top, bottom):
    img = Image.new("RGB", (S, S))
    px = img.load()
    for y in range(S):
        c = lerp(top, bottom, y / (S - 1))
        for x in range(S):
            px[x, y] = c
    return img


def rr(d, box, r, **kw):
    d.rounded_rectangle([int(v) for v in box], radius=int(r), **kw)


def draw():
    img = gradient_bg((70, 168, 255), (18, 70, 190)).convert("RGBA")

    # soft radial glow behind the head
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([S * 0.12, S * 0.14, S * 0.88, S * 0.90], fill=(255, 255, 255, 70))
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.07))
    img = Image.alpha_composite(img, glow)

    d = ImageDraw.Draw(img)
    cx = S / 2

    # antenna
    d.rectangle([cx - S * 0.012, S * 0.17, cx + S * 0.012, S * 0.30], fill=(255, 255, 255, 255))
    d.ellipse([cx - S * 0.045, S * 0.115, cx + S * 0.045, S * 0.205], fill=(255, 255, 255, 255))
    d.ellipse([cx - S * 0.022, S * 0.138, cx + S * 0.022, S * 0.182], fill=(70, 168, 255, 255))

    # ears
    for sign in (-1, 1):
        x0 = cx + sign * S * 0.335
        rr(d, [x0 - S * 0.04 if sign > 0 else x0 - S * 0.06,
               S * 0.50, x0 + S * 0.06 if sign > 0 else x0 + S * 0.04, S * 0.66],
           S * 0.035, fill=(214, 235, 255, 255))

    # soft drop shadow under head
    sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sh)
    rr(sd, [S * 0.19, S * 0.33, S * 0.81, S * 0.83], S * 0.17, fill=(6, 30, 100, 110))
    sh = sh.filter(ImageFilter.GaussianBlur(S * 0.025))
    img = Image.alpha_composite(img, sh)
    d = ImageDraw.Draw(img)

    # head
    rr(d, [S * 0.19, S * 0.30, S * 0.81, S * 0.80], S * 0.17, fill=(255, 255, 255, 255))

    # visor
    rr(d, [S * 0.255, S * 0.375, S * 0.745, S * 0.665], S * 0.115, fill=(14, 52, 150, 255))
    rr(d, [S * 0.265, S * 0.385, S * 0.735, S * 0.54], S * 0.10, fill=(24, 74, 185, 255))

    # eyes (glowing)
    eye = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ed = ImageDraw.Draw(eye)
    for sign in (-1, 1):
        ex = cx + sign * S * 0.115
        ed.ellipse([ex - S * 0.062, S * 0.438 - S * 0.0, ex + S * 0.062, S * 0.438 + S * 0.124],
                   fill=(120, 215, 255, 255))
    blur = eye.filter(ImageFilter.GaussianBlur(S * 0.02))
    img = Image.alpha_composite(img, blur)
    d = ImageDraw.Draw(img)
    for sign in (-1, 1):
        ex = cx + sign * S * 0.115
        d.ellipse([ex - S * 0.052, S * 0.446, ex + S * 0.052, S * 0.446 + S * 0.108],
                  fill=(205, 242, 255, 255))

    # smile
    d.arc([cx - S * 0.10, S * 0.555, cx + S * 0.10, S * 0.64], 20, 160,
          fill=(120, 215, 255, 255), width=int(S * 0.016))

    # chin vents
    for i in (-1, 0, 1):
        rr(d, [cx + i * S * 0.07 - S * 0.022, S * 0.715, cx + i * S * 0.07 + S * 0.022, S * 0.76],
           S * 0.012, fill=(150, 200, 255, 255))

    return img.convert("RGB").resize((OUT, OUT), Image.LANCZOS)


def main():
    master = draw()
    icons = os.path.join(ROOT, "Resources", "AppIcons")
    os.makedirs(icons, exist_ok=True)
    for name, px in SIZES.items():
        master.resize((px, px), Image.LANCZOS).save(os.path.join(icons, name + ".png"))
    cat = os.path.join(ROOT, "Resources", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(cat, exist_ok=True)
    master.save(os.path.join(cat, "AppIcon-1024.png"))
    prev = os.path.join(ROOT, "Preview")
    os.makedirs(prev, exist_ok=True)
    master.resize((512, 512), Image.LANCZOS).save(os.path.join(prev, "icon-preview.png"))
    print("icons written")


if __name__ == "__main__":
    main()
