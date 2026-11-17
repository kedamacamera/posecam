"""改善前（old）と改善後（new）の結果を 1 枚の比較画像にまとめる。
使い方: python3 sheet.py <old フォルダ> <new フォルダ> <出力フォルダ>
顔の周り: 加工前 / 改善前 / 改善後（標準・強め）と、美肌をかける範囲（改善前 / 改善後）。"""
import glob
import os
import sys

from PIL import Image, ImageDraw

OLD, NEW, OUT = sys.argv[1:4]
os.makedirs(OUT, exist_ok=True)
HEIGHT = 700


def load(path):
    image = Image.open(path).convert("RGB")
    scale = HEIGHT / image.height
    return image.resize((max(1, round(image.width * scale)), HEIGHT), Image.LANCZOS)


def row(images, labels):
    width = sum(i.width for i in images) + 10 * (len(images) - 1)
    canvas = Image.new("RGB", (width, HEIGHT + 40), "white")
    draw = ImageDraw.Draw(canvas)
    x = 0
    for image, label in zip(images, labels):
        canvas.paste(image, (x, 40))
        draw.text((x + 8, 10), label, fill="black")
        x += image.width + 10
    return canvas


names = sorted({os.path.basename(p).rsplit("_original_face", 1)[0]
                for p in glob.glob(os.path.join(NEW, "*_original_face.png"))})
for name in names:
    rows = []
    for preset in ("standard", "strong"):
        paths = [os.path.join(NEW, f"{name}_original_face.png"), os.path.join(OLD, f"{name}_{preset}_face.png"),
                 os.path.join(NEW, f"{name}_{preset}_face.png")]
        if all(os.path.exists(p) for p in paths):
            rows.append(row([load(p) for p in paths], ["original", f"before fix ({preset})", f"after fix ({preset})"]))
    # 頬のあたりを等倍で（縮めると毛穴・きめの違いが見えないため）
    for preset in ("standard", "strong"):
        paths = [os.path.join(NEW, f"{name}_original_face.png"), os.path.join(OLD, f"{name}_{preset}_face.png"),
                 os.path.join(NEW, f"{name}_{preset}_face.png")]
        if all(os.path.exists(p) for p in paths):
            crops = []
            for p in paths:
                image = Image.open(p).convert("RGB")
                w, h = image.size
                side = min(HEIGHT, w // 2, h // 2)
                left, top = int(w * 0.3), int(h * 0.45)
                crops.append(image.crop((left, top, left + side, top + side)).resize((HEIGHT, HEIGHT), Image.NEAREST))
            rows.append(row(crops, ["original 1:1", f"before fix ({preset}) 1:1", f"after fix ({preset}) 1:1"]))
    masks = [os.path.join(OLD, f"{name}_mask_face.png"), os.path.join(NEW, f"{name}_mask_face.png")]
    if all(os.path.exists(p) for p in masks):
        rows.append(row([load(p) for p in masks], ["skin area: before fix", "skin area: after fix"]))
    if not rows:
        continue
    sheet = Image.new("RGB", (max(r.width for r in rows), sum(r.height for r in rows) + 20 * len(rows)), "white")
    y = 0
    for r in rows:
        sheet.paste(r, (0, y))
        y += r.height + 20
    sheet.save(os.path.join(OUT, f"compare_{name}.jpg"), quality=90)
    print("saved", name)
