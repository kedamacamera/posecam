"""COCO val2017 の人物の正解（関節の位置と、見えているか）から、種類ごとに写真を選ぶ。
1 枚に人物が 1 人だけ・画面の 8% 以上の大きさの写真に限る（誰を測っているかを取り違えないため）。
種類:
  stand_full  立っていて全身（両足首が見えている。説明文に standing / stands）
  sit         座っている（説明文に sitting / sits / seated）
  upper       上半身（両肩は見えていて、両膝・両足首は写っていない）
  back        後ろ向き（両肩は見えていて、鼻・両目が見えていない）
出力: selection.json（file, category, width, height, bbox, keypoints）
"""
import json, random, re, sys

N = int(sys.argv[1]) if len(sys.argv) > 1 else 60
kp = json.load(open("annotations/person_keypoints_val2017.json"))
caps = json.load(open("annotations/captions_val2017.json"))
images = {im["id"]: im for im in kp["images"]}
captions = {}
for c in caps["annotations"]:
    captions.setdefault(c["image_id"], []).append(c["caption"].lower())
persons = {}
for a in kp["annotations"]:
    persons.setdefault(a["image_id"], []).append(a)

def v(a, i):  # 0 = 写っていない/付いていない, 1 = 隠れている, 2 = 見えている
    return a["keypoints"][i * 3 + 2]

NOSE, LEYE, REYE, LSH, RSH, LKN, RKN, LAN, RAN = 0, 1, 2, 5, 6, 13, 14, 15, 16
cats = {"stand_full": [], "sit": [], "upper": [], "back": []}
for iid, anns in persons.items():
    if len(anns) != 1 or anns[0]["iscrowd"]:
        continue
    a = anns[0]
    im = images[iid]
    if a["area"] < 0.08 * im["width"] * im["height"]:
        continue
    text = " ".join(captions.get(iid, []))
    shoulders = v(a, LSH) == 2 and v(a, RSH) == 2
    if re.search(r"\b(sitting|sits|seated)\b", text):
        cats["sit"].append(a)
    elif re.search(r"\b(standing|stands)\b", text) and v(a, LAN) == 2 and v(a, RAN) == 2 and v(a, NOSE) == 2:
        cats["stand_full"].append(a)
    if shoulders and v(a, LKN) == 0 and v(a, RKN) == 0 and v(a, LAN) == 0 and v(a, RAN) == 0 and v(a, NOSE) == 2:
        cats["upper"].append(a)
    if shoulders and v(a, NOSE) == 0 and v(a, LEYE) == 0 and v(a, REYE) == 0:
        cats["back"].append(a)

random.seed(1)
out = []
for name, anns in cats.items():
    print(name, "候補", len(anns))
    for a in random.sample(anns, min(N, len(anns))):
        im = images[a["image_id"]]
        out.append({"file": im["file_name"], "url": im["coco_url"], "category": name,
                    "width": im["width"], "height": im["height"], "bbox": a["bbox"], "keypoints": a["keypoints"]})
json.dump(out, open("selection.json", "w"))
print("selected", len(out))
