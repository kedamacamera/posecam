"""顔の形の補正の確認画像をまとめる。使い方: python3 sheet.py <フォルダ> <出力フォルダ>"""
import glob
import os
import sys

from PIL import Image, ImageDraw

SRC, OUT = sys.argv[1:3]
os.makedirs(OUT, exist_ok=True)
HEIGHT = 600
for original in sorted(glob.glob(os.path.join(SRC, "*_original.png"))):
    name = os.path.basename(original)[: -len("_original.png")]
    parts = [("original", original), ("points", os.path.join(SRC, f"{name}_points.png"))]
    parts += [(p, os.path.join(SRC, f"{name}_reshape_{p}.png")) for p in ("slim", "eyes", "nose", "all")]
    images = []
    for label, path in parts:
        if not os.path.exists(path):
            continue
        image = Image.open(path).convert("RGB")
        image = image.resize((max(1, round(image.width * HEIGHT / image.height)), HEIGHT), Image.LANCZOS)
        images.append((label, image))
    sheet = Image.new("RGB", (sum(i.width + 10 for _, i in images), HEIGHT + 40), "white")
    draw = ImageDraw.Draw(sheet)
    x = 0
    for label, image in images:
        sheet.paste(image, (x, 40))
        draw.text((x + 8, 10), label, fill="black")
        x += image.width + 10
    sheet.save(os.path.join(OUT, f"reshape_{name}.jpg"), quality=90)
