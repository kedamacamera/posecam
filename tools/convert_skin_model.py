"""MediaPipe の人物マルチクラス分割モデルを、肌のマスクを出す Core ML モデルに変換する。

元のモデル: selfie_multiclass_256x256（Google, Apache License 2.0）
  https://storage.googleapis.com/mediapipe-models/image_segmenter/selfie_multiclass_256x256/float32/latest/selfie_multiclass_256x256.tflite
  クラス: 0 背景 / 1 髪 / 2 体の肌 / 3 顔の肌 / 4 服 / 5 その他（モデルカードより）

変換の流れ: TFLite → ONNX（tf2onnx）→ PyTorch（onnx2torch）→ Core ML（coremltools）
出力は「体の肌 + 顔の肌」の確率を 0〜255 の白黒画像にしたもの（256x256）。
Linux で実行する（GitHub Actions の convert-model ワークフロー）。
"""

import json
import subprocess
import sys
import urllib.request
from pathlib import Path

import numpy as np

MODEL_URL = ("https://storage.googleapis.com/mediapipe-models/image_segmenter/"
             "selfie_multiclass_256x256/float32/latest/selfie_multiclass_256x256.tflite")
WORK = Path("work")
OUT = Path("out")
SIZE = 256
SKIN_CLASSES = (2, 3)


def download() -> Path:
    WORK.mkdir(exist_ok=True)
    path = WORK / "selfie_multiclass_256x256.tflite"
    if not path.exists():
        urllib.request.urlretrieve(MODEL_URL, path)
    print(f"downloaded {path} ({path.stat().st_size:,} bytes)")
    return path


def read_normalization(tflite_path: Path):
    """モデルに埋め込まれたメタデータから、入力の正規化（mean / std）を読む。"""
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
    except Exception as error:  # メタデータが読めなくても、後の比較で正しさは確かめる
        print("metadata read failed:", error)
    return None


def run_tflite(tflite_path: Path, nhwc: np.ndarray) -> np.ndarray:
    import tensorflow as tf
    interpreter = tf.lite.Interpreter(model_path=str(tflite_path))
    interpreter.allocate_tensors()
    inp = interpreter.get_input_details()[0]
    out = interpreter.get_output_details()[0]
    print("tflite input:", inp["shape"], inp["dtype"], "output:", out["shape"], out["dtype"])
    interpreter.set_tensor(inp["index"], nhwc.astype(np.float32))
    interpreter.invoke()
    return interpreter.get_tensor(out["index"])


def load_test_image() -> np.ndarray:
    """リポジトリの見本写真（人物）を 256x256 にしたもの。値は 0〜255。"""
    from PIL import Image
    image = Image.open("PoseCam/Resources/Poses/pose_30.jpg").convert("RGB").resize((SIZE, SIZE))
    return np.asarray(image, dtype=np.float32)


def main() -> None:
    import torch
    import coremltools as ct
    from onnx2torch import convert as onnx_to_torch

    tflite_path = download()
    normalization = read_normalization(tflite_path)
    mean, std = normalization if normalization else (0.0, 255.0)
    print(f"normalization: (x - {mean}) / {std}")

    onnx_path = WORK / "model.onnx"
    subprocess.run([sys.executable, "-m", "tf2onnx.convert", "--tflite", str(tflite_path),
                    "--output", str(onnx_path), "--opset", "15"], check=True)

    inner = onnx_to_torch(str(onnx_path)).eval()

    class SkinMask(torch.nn.Module):
        """NCHW の 0〜255 の画像を受け取り、肌の確率を 0〜255 の 1 チャンネル画像で返す。"""

        def __init__(self, model):
            super().__init__()
            self.model = model

        def forward(self, image):
            x = (image - mean) / std
            x = x.permute(0, 2, 3, 1)          # NCHW → NHWC（元のモデルの入力の形）
            probs = self.model(x)              # NHWC, 6 クラス
            skin = probs[..., SKIN_CLASSES[0]] + probs[..., SKIN_CLASSES[1]]
            return torch.clamp(skin, 0, 1).unsqueeze(1) * 255.0   # N,1,H,W

    wrapper = SkinMask(inner).eval()

    # 元のモデルと変換後のモデルに同じ写真を入れて、肌の確率が一致するか確かめる
    test = load_test_image()
    reference = run_tflite(tflite_path, ((test - mean) / std)[None])
    reference_skin = reference[0, ..., SKIN_CLASSES[0]] + reference[0, ..., SKIN_CLASSES[1]]
    with torch.no_grad():
        converted = wrapper(torch.from_numpy(test).permute(2, 0, 1)[None]).numpy()[0, 0] / 255.0
    diff = float(np.abs(converted - np.clip(reference_skin, 0, 1)).max())
    skin_ratio = float((reference_skin > 0.5).mean())
    print(f"max abs diff tflite vs torch: {diff:.5f}, skin pixels in test image: {skin_ratio:.3f}")
    if diff > 0.02:
        sys.exit("converted model does not match the original")
    if skin_ratio < 0.02:
        sys.exit("skin mask looks empty; the normalization is probably wrong")

    traced = torch.jit.trace(wrapper, torch.rand(1, 3, SIZE, SIZE) * 255)
    mlmodel = ct.convert(
        traced,
        convert_to="neuralnetwork",
        inputs=[ct.ImageType(name="image", shape=(1, 3, SIZE, SIZE), color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="skin", color_layout=ct.colorlayout.GRAYSCALE)],
        minimum_deployment_target=ct.target.iOS15,
    )
    mlmodel.author = "Google LLC (original MediaPipe model); converted for PoseCam"
    mlmodel.license = "Apache License 2.0"
    mlmodel.short_description = "Skin probability mask (face + body skin) from MediaPipe selfie_multiclass_256x256"

    OUT.mkdir(exist_ok=True)
    mlmodel.save(str(OUT / "SkinSegmenter.mlmodel"))
    print("saved", OUT / "SkinSegmenter.mlmodel")


if __name__ == "__main__":
    main()
