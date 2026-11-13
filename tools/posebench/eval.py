"""posebench の結果（vision.json）を COCO の正解（selection.json）と比べ、種類ごとに集計する。"""
import json, math, statistics as st
from collections import defaultdict

sel = json.load(open("selection.json"))
res = {r["file"]: r for r in json.load(open("vision.json"))}
CONF = 0.3  # アプリと同じ（PoseDetector の minimumConfidence）
# COCO の関節の順番 → Vision の関節名
COCO = ["nose", "left_eye", "right_eye", "left_ear", "right_ear", "left_shoulder", "right_shoulder",
        "left_elbow", "right_elbow", "left_wrist", "right_wrist", "left_hip", "right_hip",
        "left_knee", "right_knee", "left_ankle", "right_ankle"]
VISION = {"nose": "head_joint", "left_eye": "left_eye_joint", "right_eye": "right_eye_joint",
          "left_ear": "left_ear_joint", "right_ear": "right_ear_joint",
          "left_shoulder": "left_shoulder_1_joint", "right_shoulder": "right_shoulder_1_joint",
          "left_elbow": "left_forearm_joint", "right_elbow": "right_forearm_joint",
          "left_wrist": "left_hand_joint", "right_wrist": "right_hand_joint",
          "left_hip": "left_upLeg_joint", "right_hip": "right_upLeg_joint",
          "left_knee": "left_leg_joint", "right_knee": "right_leg_joint",
          "left_ankle": "left_foot_joint", "right_ankle": "right_foot_joint"}
names = set()
for r in res.values():
    for b in r.get("bodies", []):
        names |= set(b["joints"])
print("Vision の関節名:", sorted(names))
missing = [v for v in VISION.values() if v not in names]
if missing:
    print("!! 対応表にない名前:", missing)

def pick_body(r, s):
    """正解の人物の枠の中に入る関節がいちばん多い検出を選ぶ"""
    x, y, w, h = s["bbox"]
    W, H = s["width"], s["height"]
    best, bestn = None, 0
    for b in r.get("bodies", []):
        n = sum(1 for p in b["joints"].values()
                if p[2] > CONF and x - 0.05 * w <= p[0] * W <= x + 1.05 * w and y - 0.05 * h <= p[1] * H <= y + 1.05 * h)
        if n > bestn:
            best, bestn = b, n
    return best

stats = defaultdict(lambda: defaultdict(list))
for s in sel:
    r = res.get(s["file"])
    if r is None or "error" in r:
        continue
    c = s["category"]
    b = pick_body(r, s)
    stats[c]["person_found"].append(b is not None)
    W, H = s["width"], s["height"]
    ph = s["bbox"][3]
    for i, name in enumerate(COCO):
        gv = s["keypoints"][i * 3 + 2]
        gx, gy = s["keypoints"][i * 3], s["keypoints"][i * 3 + 1]
        p = b["joints"].get(VISION[name]) if b else None
        det = p is not None and p[2] > CONF
        group = name.split("_")[-1]
        if gv == 2:
            stats[c][f"{group}:見えている→検出"].append(det)
            if det:
                stats[c][f"{group}:位置のずれ(人の高さ比)"].append(math.hypot(p[0] * W - gx, p[1] * H - gy) / ph)
        elif gv == 0:
            stats[c][f"{group}:写っていない→誤検出"].append(det)
    # 判定1: 足先が写っているか（両足首とも見える）
    gt_feet = s["keypoints"][15 * 3 + 2] == 2 and s["keypoints"][16 * 3 + 2] == 2
    gt_nofeet = s["keypoints"][15 * 3 + 2] == 0 and s["keypoints"][16 * 3 + 2] == 0
    if b:
        pl, pr = b["joints"].get(VISION["left_ankle"]), b["joints"].get(VISION["right_ankle"])
        pred = bool(pl and pl[2] > CONF and pr and pr[2] > CONF)
    else:
        pred = False
    if gt_feet:
        stats[c]["判定:足先あり→ありと判定"].append(pred)
    if gt_nofeet:
        stats[c]["判定:足先なし→なしと判定"].append(not pred)
    # 判定2: 頭の上の余白（人物の切り抜きの上端と、正解の人物の枠の上端の差。画面の高さ比）
    if "segTop" in r:
        stats[c]["切り抜きの上端のずれ(画面の高さ比)"].append(abs(r["segTop"] - s["bbox"][1] / H))

lines = []
for c in ["stand_full", "sit", "upper", "back"]:
    d = stats[c]
    n = len(d["person_found"])
    lines.append(f"## {c}（{n} 枚）")
    for k in sorted(d):
        vals = d[k]
        if not vals:
            continue
        if isinstance(vals[0], bool):
            lines.append(f"- {k}: {100 * sum(vals) / len(vals):.0f}%（{sum(vals)}/{len(vals)}）")
        else:
            q = sorted(vals)
            lines.append(f"- {k}: 中央値 {100 * st.median(q):.1f}% / 90%点 {100 * q[int(0.9 * (len(q) - 1))]:.1f}%（{len(q)}）")
    lines.append("")
open("report.md", "w").write("\n".join(lines))
print("\n".join(lines))
