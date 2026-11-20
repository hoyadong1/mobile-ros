"""Mobile ROS icon artwork (three concepts), drawn at 4x and downsampled for smooth edges.
   python tool/store/icon_art.py <out_dir>
Writes concept_<a|b|c>.png (512, store icon), foreground/background layers for the Android adaptive icon,
and a side-by-side sheet. Colours follow the app: navy #182D42, teal #087F8C, mint #78E0CE.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

NAVY, NAVY2 = (24, 45, 66), (13, 27, 42)
TEAL, MINT, WHITE = (8, 127, 140), (120, 224, 206), (255, 255, 255)
SS = 4  # supersampling


def gradient(size, top, bottom):
    img = Image.new('RGB', (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        d.line([(0, y), (size, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img


def background(size, concept):
    if concept == 'b':
        return gradient(size, (12, 145, 158), (6, 96, 108)).convert('RGBA')
    return gradient(size, NAVY, NAVY2).convert('RGBA')


def robot_head(d, cx, cy, w, h, plate, eye, s):
    """Rounded robot face with an antenna; (cx, cy) is the face centre."""
    r = h * 0.32
    d.rounded_rectangle([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2], radius=r, fill=plate)
    ey = cy - h * 0.02
    er = h * 0.11
    for ex in (cx - w * 0.2, cx + w * 0.2):
        d.ellipse([ex - er, ey - er, ex + er, ey + er], fill=eye)
    # smile
    d.arc([cx - w * 0.16, cy + h * 0.02, cx + w * 0.16, cy + h * 0.3], 20, 160, fill=eye, width=round(9 * s))
    # ears
    for side in (-1, 1):
        x = cx + side * (w / 2 + w * 0.04)
        d.rounded_rectangle([x - w * 0.05, cy - h * 0.16, x + w * 0.05, cy + h * 0.16], radius=w * 0.04, fill=plate)
    # antenna
    top = cy - h / 2
    d.line([(cx, top), (cx, top - h * 0.2)], fill=plate, width=round(14 * s))
    d.ellipse([cx - h * 0.075, top - h * 0.3, cx + h * 0.075, top - h * 0.15], fill=plate)
    return top - h * 0.225  # antenna tip y


def foreground(size, concept, scale=1.0, mono=False):
    """Artwork on a transparent canvas. [scale] enlarges it (1.0 stays well inside the adaptive-icon safe
    zone); [mono] draws a single-colour silhouette with the face details cut out (themed icons)."""
    big = size * SS
    img = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = big / 1024 * scale
    c = big / 2
    if concept == 'a':  # robot face sending a signal
        plate, eye, wave = (WHITE, (0, 0, 0, 0), WHITE) if mono else (WHITE, NAVY, MINT)
        tip = robot_head(d, c, c + 70 * s, 330 * s, 250 * s, plate, eye, s)
        for i, rad in enumerate((70, 120)):
            box = [c - rad * s, tip - rad * s, c + rad * s, tip + rad * s]
            d.arc(box, 220, 320, fill=wave, width=round(20 * s))
    elif concept == 'b':  # joystick + ROS-graph nodes
        nodes = [(c - 200 * s, c - 150 * s), (c + 205 * s, c - 120 * s), (c + 150 * s, c + 205 * s)]
        for n in nodes:
            d.line([(c, c), n], fill=(255, 255, 255, 170), width=round(16 * s))
        for n in nodes:
            rr = 42 * s
            d.ellipse([n[0] - rr, n[1] - rr, n[0] + rr, n[1] + rr], fill=MINT)
        R = 175 * s
        d.ellipse([c - R, c - R, c + R, c + R], fill=WHITE)
        d.ellipse([c - R * 0.62, c - R * 0.62, c + R * 0.62, c + R * 0.62], fill=TEAL)
        k = R * 0.34
        d.ellipse([c - k, c - k, c + k, c + k], fill=WHITE)
    else:  # map pin with a robot face
        pin_r = 190 * s
        py = c - 40 * s
        d.ellipse([c - pin_r, py - pin_r, c + pin_r, py + pin_r], fill=MINT)
        d.polygon([(c - pin_r * 0.62, py + pin_r * 0.78), (c + pin_r * 0.62, py + pin_r * 0.78), (c, py + pin_r * 1.85)],
                  fill=MINT)
        robot_head(d, c, py + 18 * s, 220 * s, 160 * s, NAVY, MINT, s * 0.75)
    return img.resize((size, size), Image.LANCZOS)


def store_icon(concept, size=512, scale=1.0):
    """Full-bleed square for the Play Store (Google applies the rounded mask itself)."""
    bg = background(size, concept)
    fg = foreground(size, concept, scale)
    bg.alpha_composite(fg)
    return bg


def mask_preview(img):
    """How it looks on a launcher (squircle mask), for the comparison sheet only."""
    size = img.size[0]
    m = Image.new('L', (size * SS, size * SS), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size * SS, size * SS], radius=size * SS * 0.24, fill=255)
    m = m.resize((size, size), Image.LANCZOS)
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    out.paste(img, (0, 0), m)
    return out


DENSITIES = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}


def android_icons(res_dir, concept, store_scale=1.25, adaptive_scale=1.2):
    """Launcher icons: adaptive layers (108 dp) per density plus the legacy 48 dp icon."""
    for name, k in DENSITIES.items():
        d = os.path.join(res_dir, f'mipmap-{name}')
        layer = round(108 * k)
        background(layer, concept).save(os.path.join(d, 'ic_launcher_background.png'))
        foreground(layer, concept, adaptive_scale).save(os.path.join(d, 'ic_launcher_foreground.png'))
        foreground(layer, concept, adaptive_scale, mono=True).save(os.path.join(d, 'ic_launcher_monochrome.png'))
        legacy = round(48 * k)
        mask_preview(store_icon(concept, legacy * 4, store_scale).resize((legacy, legacy), Image.LANCZOS))             .save(os.path.join(d, 'ic_launcher.png'))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'android':
        res, concept = sys.argv[2], sys.argv[3]
        android_icons(res, concept)
        out = sys.argv[4]
        os.makedirs(out, exist_ok=True)
        store_icon(concept, 512, 1.25).convert('RGB').save(os.path.join(out, 'app_icon_512.png'))
        print('android icons and store icon written')
        return
    out = sys.argv[1] if len(sys.argv) > 1 else 'store_icons'
    os.makedirs(out, exist_ok=True)
    sheet = Image.new('RGBA', (3 * 300 + 4 * 40, 300 + 2 * 40 + 50), (244, 247, 250, 255))
    d = ImageDraw.Draw(sheet)
    for i, concept in enumerate('abc'):
        icon = store_icon(concept)
        icon.convert('RGB').save(os.path.join(out, f'concept_{concept}_512.png'))
        x = 40 + i * 340
        sheet.alpha_composite(mask_preview(icon.resize((300, 300), Image.LANCZOS)), (x, 40))
        d.text((x + 140, 360), concept.upper(), fill=(24, 45, 66))
    sheet.convert('RGB').save(os.path.join(out, 'concepts.png'))
    print('wrote', out)


if __name__ == '__main__':
    main()
