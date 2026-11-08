"""PoseCam のボーン入れツール（Windows 用・開発者向け）。

組み込みポーズの見本写真に、関節・顔・枠（撮影画面に重なる範囲）を手で入れ直し、
アプリに同梱する PoseCam/Resources/Poses/builtin_shapes.json を作り直す。

使い方: pose-editor.bat をダブルクリック（または python server.py）。ブラウザで編集画面が開く。
Python 3.8 以上の標準ライブラリだけで動く（追加のインストールは不要）。

ファイル:
  builtin_analysis.json … Mac で自動解析した結果（写真の上の座標）。tools/shapes が書き出す。
  pose_edits.json       … このツールで手直しした内容（写真の上の座標）。これが手直しの元データ。
  pose_checked.json     … 見て「手直し不要（OK）」にした写真の名前の一覧。アプリの型には影響しない。
  pose_problems.json    … 写真そのものに問題がある（描き直しが要る）と印を付けた写真の一覧。アプリの型には影響しない。
  保存すると、上の 2 つから builtin_shapes.json（アプリが読む、枠の中の座標）を作り直す。
"""

import json
import os
import re
import sys
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
POSES = os.path.join(REPO, "PoseCam", "Resources", "Poses")
ANALYSIS = os.path.join(HERE, "builtin_analysis.json")
EDITS = os.path.join(HERE, "pose_edits.json")
CHECKED = os.path.join(HERE, "pose_checked.json")
PROBLEMS = os.path.join(HERE, "pose_problems.json")
SHAPES = os.path.join(POSES, "builtin_shapes.json")
BUILTIN_SWIFT = os.path.join(REPO, "PoseCam", "Pose", "BuiltInPoses.swift")


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def write_json(path, value, indent=None):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(value, f, ensure_ascii=False, sort_keys=True, indent=indent,
                  separators=(",", ":") if indent is None else (",", ": "))
        f.write("\n" if indent is not None else "")
    os.replace(tmp, path)


def pose_labels():
    """画像名 → (表示名, カテゴリ)。アプリの BuiltInPoses と同じ名前の付け方"""
    labels = {}
    counts = {}
    for entry in load_json(os.path.join(POSES, "sample_poses.json"), []):
        category = entry["category"]
        counts[category] = counts.get(category, 0) + 1
        labels[entry["image"]] = ("%s %d" % (category, counts[category]), category)
    try:
        with open(BUILTIN_SWIFT, encoding="utf-8") as f:
            source = f.read()
        specs = re.findall(r'PoseSpec\(name: "([^"]+)", category: "([^"]+)"', source)
        for i, (name, category) in enumerate(specs):
            labels["pose_%02d" % i] = (name, category)
    except FileNotFoundError:
        pass
    return labels


# MARK: - 型の形への変換（アプリの PoseImporter.shape と同じ計算）

def convert_shape(record, edit):
    width, height = record["size"]
    crop = edit.get("crop") or record["crop"]
    cx, cy, cw, ch = crop
    aspect = cw / ch

    def iso(p):
        x = (p[0] * width - cx) / cw
        y = (p[1] * height - cy) / ch
        return [(x - 0.5) * aspect, y]

    joints = edit["joints"] if "joints" in edit else record["joints"]
    face = edit["face"] if "face" in edit else record.get("face")
    outlines = record.get("outlines") or []
    lines = record.get("lines") or []

    def convert_face(face):
        f = dict(face)
        f["center"] = iso(face["center"])
        # 顔の高さは枠の高さに対する割合
        f["height"] = face["height"] * height / ch
        for key in ("contour", "mouth"):
            f[key] = [iso(p) for p in face.get(key) or []]
        # ペンで描いた鼻・口の線（あるときだけ。アプリは表示にだけ使う）
        for key in ("noseLines", "mouthLines"):
            lines_ = [[iso(p) for p in line] for line in face.get(key) or [] if len(line) > 1]
            if lines_:
                f[key] = lines_
            else:
                f.pop(key, None)
        for key in ("leftEye", "rightEye", "nose"):
            if face.get(key) is not None:
                f[key] = iso(face[key])
            else:
                f.pop(key, None)
        return f

    # 2 人以上の写真の、2 人目以降の骨格と顔（[{points, face}]）
    others = edit["others"] if "others" in edit else (record.get("others") or [])

    shape = {"points": {k: iso(v) for k, v in joints.items()}}
    if outlines:
        shape["outline"] = [iso(p) for p in outlines[0]]
    if len(outlines) > 1:
        shape["extraOutlines"] = [[iso(p) for p in o] for o in outlines[1:]]
    if face:
        shape["face"] = convert_face(face)
    if lines:
        shape["lines"] = [[iso(p) for p in line] for line in lines]
    if others:
        people = []
        for other in others:
            person = {"points": {k: iso(v) for k, v in (other.get("points") or {}).items()}}
            if other.get("face"):
                person["face"] = convert_face(other["face"])
            people.append(person)
        shape["extraPeople"] = people
    return shape


def export_shapes(analysis, edits):
    shapes = {name: convert_shape(record, edits.get(name, {})) for name, record in analysis.items()}
    write_json(SHAPES, shapes)
    return len(shapes)


# MARK: - サーバー

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, value, status=200):
        self.send(status, json.dumps(value, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

    def do_GET(self):
        path = unquote(self.path.split("?")[0])
        if path in ("/", "/index.html"):
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                self.send(200, f.read(), "text/html; charset=utf-8")
        elif path == "/api/data":
            analysis = load_json(ANALYSIS, None)
            if analysis is None:
                self.send_json({"error": "builtin_analysis.json がありません。README の手順で Mac の解析結果を入れてください。"}, 500)
                return
            labels = pose_labels()
            items = []
            for name in sorted(analysis):
                label, category = labels.get(name, (name, analysis[name].get("category") or ""))
                items.append({"name": name, "label": label, "category": category,
                              "isObject": analysis[name].get("isObject", False)})
            self.send_json({"items": items, "analysis": analysis, "edits": load_json(EDITS, {}),
                            "checked": load_json(CHECKED, []), "problems": load_json(PROBLEMS, [])})
        elif path.startswith("/photo/"):
            name = os.path.basename(path[len("/photo/"):])
            file = os.path.join(POSES, name + ".jpg")
            if not re.fullmatch(r"[A-Za-z0-9_\-]+", name) or not os.path.exists(file):
                self.send(404, b"not found", "text/plain")
                return
            with open(file, "rb") as f:
                self.send(200, f.read(), "image/jpeg")
        else:
            self.send(404, b"not found", "text/plain")

    def do_POST(self):
        if self.path != "/api/save":
            self.send(404, b"not found", "text/plain")
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            body = json.loads(self.rfile.read(length).decode("utf-8"))
            edits = body["edits"]
            checked = sorted(set(body.get("checked", [])))
            problems = sorted(set(body.get("problems", [])))
            analysis = load_json(ANALYSIS, {})
            unknown = [name for name in list(edits) + checked + problems if name not in analysis]
            if unknown:
                raise ValueError("解析結果にない写真: " + ", ".join(unknown))
            write_json(EDITS, edits, indent=1)
            write_json(CHECKED, checked, indent=1)
            write_json(PROBLEMS, problems, indent=1)
            count = export_shapes(analysis, edits)
            self.send_json({"ok": True, "shapes": count, "edited": len(edits), "checked": len(checked),
                            "problems": len(problems)})
        except Exception as error:  # 保存できなかった理由を画面に出す
            self.send_json({"ok": False, "error": str(error)}, 500)


def main():
    if "--export" in sys.argv:
        # 画面を開かずに builtin_shapes.json だけ作り直す（確認用）
        count = export_shapes(load_json(ANALYSIS, {}), load_json(EDITS, {}))
        print("builtin_shapes.json: %d poses" % count)
        return
    port = 8765
    # Windows では SO_REUSEADDR を付けると、ほかのツールが使っているポートにも重ねて入れてしまい、
    # 2 つのツールが同じアドレスで動いて保存先がばらばらになる。使用中なら次のポートへ進むように切る
    ThreadingHTTPServer.allow_reuse_address = False
    while True:
        try:
            server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
            break
        except OSError:
            port += 1
    url = "http://127.0.0.1:%d/" % port
    print("ボーン入れツール: %s （閉じるときはこの画面で Ctrl+C）" % url)
    if "--no-browser" not in sys.argv:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
