import os
from PIL import Image, ImageDraw, ImageFilter

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# 背景圆角渐变
bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
bd = ImageDraw.Draw(bg)
for y in range(S):
    t = y / S
    bd.line([(0, y), (S, y)], fill=(int(20 - 10 * t), int(32 - 16 * t), int(54 - 22 * t), 255))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([36, 36, S - 36, S - 36], radius=212, fill=255)
img.paste(bg, (0, 0), mask)

d = ImageDraw.Draw(img)

# 卡片
card = [190, 250, 834, 774]
d.rounded_rectangle(card, radius=54, fill=(24, 37, 60, 255), outline=(56, 88, 132, 255), width=3)

# 卡片内文字条
for i, (x0, x1) in enumerate([(250, 706), (250, 774), (250, 596)]):
    y = 336 + i * 92
    d.rounded_rectangle([x0, y, x1, y + 28], radius=14, fill=(120, 146, 180, 235))

# 扫描光束（裁进卡片内）
beam = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(beam).rectangle([190, 452, 834, 566], fill=(70, 150, 255, 210))
beam = beam.filter(ImageFilter.GaussianBlur(30))
clip = Image.new("L", (S, S), 0)
ImageDraw.Draw(clip).rounded_rectangle(card, radius=54, fill=255)
img.paste(Image.alpha_composite(img.crop((0, 0, S, S)), beam), (0, 0), clip)

d = ImageDraw.Draw(img)
d.rounded_rectangle([206, 508, 818, 520], radius=6, fill=(178, 222, 255, 235))

# 取景器四角
acc = (92, 168, 255, 255)
L, th, m = 104, 15, 108
for cx, cy, dx, dy in [(m, m, 1, 1), (S - m, m, -1, 1), (m, S - m, 1, -1), (S - m, S - m, -1, -1)]:
    d.line([(cx, cy), (cx + dx * L, cy)], fill=acc, width=th, joint="curve")
    d.line([(cx, cy), (cx, cy + dy * L)], fill=acc, width=th, joint="curve")
    r = th // 2
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=acc)

img.save("AppIcon-1024.png")

os.makedirs("AppIcon.iconset", exist_ok=True)
for base in (16, 32, 128, 256, 512):
    for scale, suffix in ((1, ""), (2, "@2x")):
        px = base * scale
        img.resize((px, px), Image.LANCZOS).save(f"AppIcon.iconset/icon_{base}x{base}{suffix}.png")
print("ok")
