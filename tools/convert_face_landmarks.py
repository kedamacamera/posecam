"""MediaPipe の顔のランドマーク（478 点）のモデルを Core ML に変換する。

元のモデル: face_landmarker.task（Google, Apache License 2.0。Face Mesh V2 のモデルカードで確認）
  https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/latest/face_landmarker.task
  中の face_landmarks_detector.tflite（入力 256x256 の顔の切り抜き、出力 478 点 x (x, y, z)）だけを使う。
  顔の位置は iPhone の Vision（顔の枠）で求めるので、顔の検出のモデルは使わない。

変換の流れ: TFLite → ONNX（tf2onnx）→ PyTorch（onnx2torch）→ Core ML（coremltools）
出力: landmarks（1434 = 478 x 3。切り抜きの左上原点のピクセル座標 0〜256）、face（顔らしさ 0〜1）
"""

import json
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

import numpy as np

TASK_URL = ("https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/"
            "float16/latest/face_landmarker.task")
WORK = Path("work")
OUT = Path("out")
SIZE = 256


def download() -> Path:
    WORK.mkdir(exist_ok=True)
    task = WORK / "face_landmarker.task"
    if not task.exists():
        urllib.request.urlretrieve(TASK_URL, task)
    with zipfile.ZipFile(task) as archive:
        print("bundle:", archive.namelist())
        name = next(n for n in archive.namelist() if "landmarks_detector" in n)
        archive.extract(name, WORK)
    path = WORK / name
    print(f"model {path} ({path.stat().st_size:,} bytes)")
    return path


def read_normalization(tflite_path: Path):
    try:
        from tflite_support import metadata
        displayer = metadata.MetadataDisplayer.with_model_file(str(tflite_path))
        meta = json.loads(displayer.get_metadata_json())
        print("metadata:", json.dumps(meta, indent=1)[:3000])
        for tensor in meta["subgraph_metadata"][0]["input_tensor_metadata"]:
            for unit in tensor.get("process_units", []):
                options = unit.get("options", {})
                if "mean" in options:
                    return float(options["mean"][0]), float(options["std"][0])
    except Exception as error:
        print("metadata read failed:", error)
    return None


def run_tflite(tflite_path: Path, nhwc: np.ndarray):
    import tensorflow as tf
    interpreter = tf.lite.Interpreter(model_path=str(tflite_path))
    interpreter.allocate_tensors()
    inp = interpreter.get_input_details()[0]
    outs = interpreter.get_output_details()
    print("tflite input:", inp["shape"], inp["dtype"])
    for o in outs:
        print("tflite output:", o["name"], o["shape"], o["dtype"])
    interpreter.set_tensor(inp["index"], nhwc.astype(np.float32))
    interpreter.invoke()
    return {o["name"]: interpreter.get_tensor(o["index"]) for o in outs}


def load_test_face() -> np.ndarray:
    """見本写真の顔のあたりを 256x256 に切り抜いたもの（0〜255）。"""
    from PIL import Image
    image = Image.open("PoseCam/Resources/Poses/pose_23.jpg").convert("RGB")
    # pose_23 は 768x1152 で、顔はおよそ (300〜480, 150〜360)
    face = image.crop((270, 140, 510, 380)).resize((SIZE, SIZE))
    return np.asarray(face, dtype=np.float32)


def main() -> None:
    import torch
    import coremltools as ct
    from onnx2torch import convert as onnx_to_torch

    tflite_path = download()
    normalization = read_normalization(tflite_path)
    mean, std = normalization if normalization else (0.0, 255.0)
    print(f"normalization: (x - {mean}) / {std}")

    test = load_test_face()
    reference = run_tflite(tflite_path, ((test - mean) / std)[None])
    # 1434 個の値を持つ出力がランドマーク、1 個の出力のうち最初のものが顔らしさ
    names = list(reference.keys())
    landmark_index = next(i for i, n in enumerate(names) if reference[n].size == 478 * 3)
    face_index = next(i for i, n in enumerate(names) if reference[n].size == 1)
    ref_points = reference[names[landmark_index]].reshape(-1)
    ref_face = float(reference[names[face_index]].reshape(-1)[0])
    print("reference face score (raw):", ref_face, "first points:", ref_points[:6])

    onnx_path = WORK / "landmarks.onnx"
    subprocess.run([sys.executable, "-m", "tf2onnx.convert", "--tflite", str(tflite_path),
                    "--output", str(onnx_path), "--opset", "15"], check=True)
    inner = onnx_to_torch(str(onnx_path)).eval()

    class FaceLandmarks(torch.nn.Module):
        """NCHW の 0〜255 の顔の切り抜きを受け取り、(478x3 の座標, 顔らしさ 0〜1) を返す。"""

        def __init__(self, model):
            super().__init__()
            self.model = model

        def forward(self, image):
            x = (image - mean) / std
            x = x.permute(0, 2, 3, 1)
            outputs = self.model(x)
            points = outputs[landmark_index].reshape(1, 478 * 3)
            score = outputs[face_index].reshape(1, 1)
            # 顔らしさが 0〜1 の外なら（ロジットなら）シグモイドで 0〜1 にする
            if not (0.0 <= ref_face <= 1.0):
                score = torch.sigmoid(score)
            return points, score

    wrapper = FaceLandmarks(inner).eval()
    with torch.no_grad():
        points, _ = wrapper(torch.from_numpy(test).permute(2, 0, 1)[None])
    diff = float(np.abs(points.numpy().reshape(-1) - ref_points).max())
    spread = float(ref_points.reshape(-1, 3)[:, 0].std())
    print(f"max abs diff tflite vs torch: {diff:.4f} px, x spread {spread:.1f} px")
    if diff > 0.5:
        sys.exit("converted model does not match the original")
    if spread < 10:
        sys.exit("landmarks look collapsed; the normalization is probably wrong")

    traced = torch.jit.trace(wrapper, torch.rand(1, 3, SIZE, SIZE) * 255)
    mlmodel = ct.convert(
        traced,
        convert_to="neuralnetwork",
        inputs=[ct.ImageType(name="image", shape=(1, 3, SIZE, SIZE), color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="landmarks"), ct.TensorType(name="face")],
        minimum_deployment_target=ct.target.iOS14,
    )
    mlmodel.author = "Google LLC (original MediaPipe Face Mesh V2 model); converted for Hamera"
    mlmodel.license = "Apache License 2.0"
    mlmodel.short_description = "478 face landmarks (x, y, z in 256x256 crop pixels) from MediaPipe face_landmarker"

    OUT.mkdir(exist_ok=True)
    mlmodel.save(str(OUT / "FaceLandmarks.mlmodel"))
    print("saved", OUT / "FaceLandmarks.mlmodel")


if __name__ == "__main__":
    main()
