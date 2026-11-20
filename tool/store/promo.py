"""Landscape promo video (1920x1080) from emulator screen recordings.
   python tool/store/promo.py <video_raw_dir> <out_mp4> <app_icon_png>
Portrait clips sit in a rounded window beside a caption; landscape clips fill the frame with a caption
pill. Needs ffmpeg on PATH. Colours follow the app.
"""
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

W, H, FPS = 1920, 1080, 30
NAVY, NAVY2, MINT, WHITE, SUB = (24, 45, 66), (11, 22, 34), (120, 224, 206), (255, 255, 255), (176, 194, 207)
FONT_BOLD = 'C:/Windows/Fonts/segoeuib.ttf'
FONT = 'C:/Windows/Fonts/segoeui.ttf'
STATUS_BAR, HANDLE = 84, 60

# (clip, start s, duration s, orientation, title, subtitle)
SEGMENTS = [
    ('c1.mp4', 1.5, 9.0, 'portrait', 'Connect in seconds', 'Any rosbridge robot · ROS 1 and ROS 2'),
    ('c2.mp4', 1.2, 11.0, 'landscape', 'A controller for every robot', 'Differential, omni, car-like, arm and drone'),
    ('c3.mp4', 1.0, 15.0, 'portrait', 'Tap the map.\nWatch it drive.', 'Nav2 goals with live progress'),
    ('c4.mp4', 2.5, 6.0, 'portrait', 'Live sensors', 'LiDAR, IMU, odometry, battery, GPS'),
    ('c5.mp4', 1.0, 9.5, 'portrait', 'See inside\nyour robot', 'Topics, nodes and services'),
]


def font(size, bold=True):
    return ImageFont.truetype(FONT_BOLD if bold else FONT, size)


def gradient():
    img = Image.new('RGB', (W, H))
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = y / (H - 1)
        d.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(NAVY, NAVY2)))
    return img


def text_block(d, x, y, title, subtitle, size=92):
    for line in title.split('\n'):
        d.text((x, y), line, font=font(size), fill=WHITE)
        y += round(size * 1.18)
    d.text((x, y + 18), subtitle, font=font(40, bold=False), fill=MINT)


PHONE_H = 960
PHONE_W = round(1080 * PHONE_H / (1920 - STATUS_BAR - HANDLE))
PHONE_X, PHONE_Y = W - PHONE_W - 200, (H - PHONE_H) // 2


def portrait_layers(title, subtitle, tmp, i):
    """Background with caption, and a foreground 'frame' with a rounded window for the clip."""
    bg = gradient()
    text_block(ImageDraw.Draw(bg), 150, 330, title, subtitle)
    bg_path = os.path.join(tmp, f'bg{i}.png')
    bg.save(bg_path)
    frame = bg.convert('RGBA')
    hole = Image.new('L', (W * 4, H * 4), 255)
    ImageDraw.Draw(hole).rounded_rectangle(
        [PHONE_X * 4, PHONE_Y * 4, (PHONE_X + PHONE_W) * 4, (PHONE_Y + PHONE_H) * 4], radius=40 * 4, fill=0)
    frame.putalpha(hole.resize((W, H), Image.LANCZOS))
    frame_path = os.path.join(tmp, f'frame{i}.png')
    frame.save(frame_path)
    return bg_path, frame_path


def caption_pill(title, subtitle, tmp, i):
    img = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    t = title.replace('\n', ' ')
    tw = d.textlength(t, font=font(56))
    sw = d.textlength(subtitle, font=font(32, bold=False))
    w = max(tw, sw) + 100
    x0 = (W - w) / 2
    d.rounded_rectangle([x0, 180, x0 + w, 180 + 170], radius=34, fill=(11, 22, 34, 215))  # below the toolbar
    d.text(((W - tw) / 2, 198), t, font=font(56), fill=WHITE)
    d.text(((W - sw) / 2, 280), subtitle, font=font(32, bold=False), fill=MINT)
    path = os.path.join(tmp, f'pill{i}.png')
    img.save(path)
    return path


def card(icon_path, lines, tmp, name):
    img = gradient()
    d = ImageDraw.Draw(img)
    icon = Image.open(icon_path).convert('RGB').resize((200, 200), Image.LANCZOS)
    mask = Image.new('L', (800, 800), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, 799, 799], radius=180, fill=255)
    img.paste(icon, ((W - 200) // 2, 250), mask.resize((200, 200), Image.LANCZOS))
    ring = Image.new('RGBA', (212 * 4, 212 * 4), (0, 0, 0, 0))  # mint outline so the icon stands out
    ImageDraw.Draw(ring).rounded_rectangle([4, 4, 212 * 4 - 5, 212 * 4 - 5], radius=50 * 4,
                                           outline=(120, 224, 206, 170), width=10)
    img = img.convert('RGBA')
    img.alpha_composite(ring.resize((212, 212), Image.LANCZOS), ((W - 212) // 2, 244))
    img = img.convert('RGB')
    d = ImageDraw.Draw(img)
    y = 500
    for text, size, colour, bold in lines:
        f = font(size, bold)
        d.text(((W - d.textlength(text, font=f)) / 2, y), text, font=f, fill=colour)
        y += round(size * 1.35)
    path = os.path.join(tmp, name)
    img.save(path)
    return path


def run(args):
    subprocess.run(['ffmpeg', '-v', 'error', '-y', *args], check=True)


ENC = ['-r', str(FPS), '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', '-pix_fmt', 'yuv420p', '-an']


def main():
    raw, out, icon = sys.argv[1], sys.argv[2], sys.argv[3]
    tmp = tempfile.mkdtemp()
    parts = []
    intro = card(icon, [('Mobile ROS', 110, WHITE, True), ('Drive, map and inspect ROS robots from your phone', 44, SUB, False)],
                 tmp, 'intro.png')
    parts.append(os.path.join(tmp, 'p0.mp4'))
    run(['-loop', '1', '-t', '3', '-i', intro, '-vf', 'fade=in:0:15,fade=out:75:15', *ENC, parts[-1]])
    for i, (clip, start, dur, kind, title, subtitle) in enumerate(SEGMENTS, 1):
        src = os.path.join(raw, clip)
        part = os.path.join(tmp, f'p{i}.mp4')
        fade = f'fade=in:0:10,fade=out:{round(dur * FPS) - 10}:10'
        if kind == 'portrait':
            bg, frame = portrait_layers(title, subtitle, tmp, i)
            crop = f'crop=1080:{1920 - STATUS_BAR - HANDLE}:0:{STATUS_BAR},scale={PHONE_W}:{PHONE_H}'
            graph = (f'[1:v]{crop},fps={FPS}[v];[0:v][v]overlay={PHONE_X}:{PHONE_Y}[b];[b][2:v]overlay=0:0,'
                     f'{fade}[out]')
            run(['-loop', '1', '-t', str(dur), '-i', bg, '-ss', str(start), '-t', str(dur), '-i', src,
                 '-loop', '1', '-t', str(dur), '-i', frame, '-filter_complex', graph, '-map', '[out]',
                 '-t', str(dur), *ENC, part])
        else:
            pill = caption_pill(title, subtitle, tmp, i)
            # Caption for the first 3.5 s, then the clip alone.
            graph = (f'[0:v]scale={W}:{H},fps={FPS}[v];[1:v]format=rgba,fade=out:st=3:d=0.5:alpha=1[p];'
                     f'[v][p]overlay=0:0,{fade}[out]')
            run(['-ss', str(start), '-t', str(dur), '-i', src, '-loop', '1', '-t', str(dur), '-i', pill,
                 '-filter_complex', graph, '-map', '[out]', '-t', str(dur), *ENC, part])
        parts.append(part)
        print('segment', i, 'done', flush=True)
    outro = card(icon, [('Mobile ROS', 110, WHITE, True), ('Free on Google Play', 44, MINT, False)], tmp, 'outro.png')
    parts.append(os.path.join(tmp, 'p9.mp4'))
    run(['-loop', '1', '-t', '3', '-i', outro, '-vf', 'fade=in:0:15', *ENC, parts[-1]])
    listing = os.path.join(tmp, 'list.txt')
    with open(listing, 'w') as f:
        for p in parts:
            f.write(f"file '{p}'\n")
    run(['-f', 'concat', '-safe', '0', '-i', listing, '-c', 'copy', '-movflags', '+faststart', out])
    print('wrote', out)


if __name__ == '__main__':
    main()
