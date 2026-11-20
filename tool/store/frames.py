"""Play Store graphics from raw emulator captures.
   python tool/store/frames.py <raw_dir> <out_dir> <app_icon_png>
Writes 8 phone screenshots (1080x1920, headline + framed capture) and the 1024x500 feature graphic.
Colours follow the app: navy #182D42, teal #087F8C, mint #78E0CE.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

NAVY, NAVY2, MINT, WHITE = (24, 45, 66), (11, 22, 34), (120, 224, 206), (255, 255, 255)
SUB = (176, 194, 207)
FONT_BOLD = 'C:/Windows/Fonts/segoeuib.ttf'
FONT = 'C:/Windows/Fonts/segoeui.ttf'
W, H = 1080, 1920
STATUS_BAR = 84  # px of Android status bar cropped off portrait captures


def font(size, bold=True):
    return ImageFont.truetype(FONT_BOLD if bold else FONT, size)


def gradient(w, h, top=NAVY, bottom=NAVY2):
    img = Image.new('RGB', (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / (h - 1)
        d.line([(0, y), (w, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img


def rounded(img, radius):
    mask = Image.new('L', img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1], radius=radius, fill=255)
    out = Image.new('RGBA', img.size, (0, 0, 0, 0))
    out.paste(img.convert('RGBA'), (0, 0), mask)
    return out


def shadowed(canvas, card, xy, radius=36):
    """Pastes [card] with rounded corners and a soft shadow."""
    card = rounded(card, radius)
    shadow = Image.new('RGBA', (card.size[0] + 80, card.size[1] + 80), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([40, 50, card.size[0] + 40, card.size[1] + 40], radius=radius,
                                             fill=(0, 0, 0, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(22))
    canvas.alpha_composite(shadow, (xy[0] - 40, xy[1] - 40))
    canvas.alpha_composite(card, xy)


def headline(canvas, title, subtitle):
    d = ImageDraw.Draw(canvas)
    y = 96
    for line in title.split('\n'):
        f = font(78)
        w = d.textlength(line, font=f)
        d.text(((W - w) / 2, y), line, font=f, fill=WHITE)
        y += 96
    f = font(38, bold=False)
    w = d.textlength(subtitle, font=f)
    d.text(((W - w) / 2, y + 14), subtitle, font=f, fill=MINT)
    return y + 90


def portrait_shot(raw, name, title, subtitle):
    canvas = gradient(W, H).convert('RGBA')
    top = headline(canvas, title, subtitle)
    shot = Image.open(os.path.join(raw, name)).convert('RGB')
    shot = shot.crop((0, STATUS_BAR, shot.width, shot.height - 60))  # status bar, gesture handle
    avail_h = H - top - 40
    scale = min(900 / shot.width, avail_h / shot.height)
    shot = shot.resize((round(shot.width * scale), round(shot.height * scale)), Image.LANCZOS)
    shadowed(canvas, shot, ((W - shot.width) // 2, top + 20))
    return canvas


def stacked_shot(raw, names, title, subtitle):
    """Two landscape captures, one above the other."""
    canvas = gradient(W, H).convert('RGBA')
    top = headline(canvas, title, subtitle)
    gap = 56
    shots = [Image.open(os.path.join(raw, n)).convert('RGB') for n in names]
    width = 980
    y = top + 40
    for s in shots:
        s = s.resize((width, round(s.height * width / s.width)), Image.LANCZOS)
        shadowed(canvas, s, ((W - width) // 2, y), radius=28)
        y += s.height + gap
    return canvas


def feature_graphic(raw, icon_path):
    fw, fh = 1024, 500
    canvas = gradient(fw, fh).convert('RGBA')
    d = ImageDraw.Draw(canvas)
    icon = rounded(Image.open(icon_path).convert('RGB').resize((112, 112), Image.LANCZOS), 26)
    canvas.alpha_composite(icon, (60, 104))
    # A thin mint outline so the navy icon stands out from the navy background.
    ring = Image.new('RGBA', (120 * 4, 120 * 4), (0, 0, 0, 0))  # drawn at 4x for smooth corners
    ImageDraw.Draw(ring).rounded_rectangle([2, 2, 120 * 4 - 3, 120 * 4 - 3], radius=29 * 4,
                                           outline=(120, 224, 206, 170), width=8)
    canvas.alpha_composite(ring.resize((120, 120), Image.LANCZOS), (56, 100))
    d.text((60, 236), 'Mobile ROS', font=font(64), fill=WHITE)
    d.text((62, 322), 'Drive, map and inspect', font=font(30, bold=False), fill=SUB)
    d.text((62, 362), 'ROS robots from your phone', font=font(30, bold=False), fill=SUB)
    # Right side: a landscape control capture with a portrait map capture overlapping it.
    ctrl = Image.open(os.path.join(raw, 'control_drive.png')).convert('RGB')
    ctrl = ctrl.resize((520, round(ctrl.height * 520 / ctrl.width)), Image.LANCZOS)
    shadowed(canvas, ctrl, (470, 70), radius=20)
    mp = Image.open(os.path.join(raw, 'map_driving.png')).convert('RGB')
    mp = mp.crop((0, STATUS_BAR, mp.width, mp.height - 60))
    mh = 380
    mp = mp.resize((round(mp.width * mh / mp.height), mh), Image.LANCZOS)
    shadowed(canvas, mp, (fw - mp.width - 30, fh - mh - 20), radius=20)
    return canvas.convert('RGB')


SHOTS = [
    ('portrait', 'map_driving.png', 'Tap the map.\nWatch it drive.', 'Nav2 goals with live progress, path and LiDAR'),
    ('stacked', ('control_type.png', 'control_drive.png'), 'A controller\nfor every robot', 'Differential, omni, car-like, arm and drone'),
    ('stacked', ('arm.png', 'drone.png'), 'Arms and drones too', 'Joint jog, gripper, take-off, hover and land'),
    ('portrait', 'sensors.png', 'Live sensors,\nzero setup', 'LiDAR, IMU, odometry, battery, GPS and more'),
    ('portrait', 'explorer_topic.png', 'See inside\nyour robot', 'Topics, nodes and services with live rates'),
    ('portrait', 'publish.png', 'Publish\nany message', 'Forms built from the robot\'s own message types'),
    ('portrait', 'map_topics.png', 'Works with\nyour topic names', 'Namespaces, custom topics and sensors'),
    ('portrait', 'connect.png', 'Connect in\nseconds', 'rosbridge over ws:// or wss://, ROS 1 and ROS 2'),
]


def main():
    raw, out, icon = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(out, exist_ok=True)
    for i, (kind, src, title, subtitle) in enumerate(SHOTS, 1):
        img = portrait_shot(raw, src, title, subtitle) if kind == 'portrait' else stacked_shot(raw, src, title, subtitle)
        name = f'{i:02d}_{(src if isinstance(src, str) else src[0]).split(".")[0]}.png'
        img.convert('RGB').save(os.path.join(out, name))
        print('wrote', name)
    feature_graphic(raw, icon).save(os.path.join(out, 'feature_graphic_1024x500.png'))
    print('wrote feature_graphic_1024x500.png')


if __name__ == '__main__':
    main()
