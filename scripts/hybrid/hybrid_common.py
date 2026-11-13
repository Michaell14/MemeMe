"""Shared pieces of the hybrid matcher's Python side: the pinned weights, the prompts and the reference math.

The preprocessing and scoring below are copied from the team's benchmark script (bench.py in
MemeMe_Iteration1_Benchmark.zip, the "Hybrid: CLIP B/32 + expression" rows) so the reference stays the benchmark.
"""
import hashlib
import json
import os
import urllib.request

import numpy as np
from PIL import Image, ImageOps

# ---------- pinned weights (downloaded, never committed) ----------
WEIGHTS = {
    "clip": {
        "file": "vit_b_32-quickgelu-laion400m_e32-46683a32.pt",
        "url": "https://github.com/mlfoundations/open_clip/releases/download/v0.2-weights/"
               "vit_b_32-quickgelu-laion400m_e32-46683a32.pt",
        "sha256": "46683a32721d5c68911153698992361285d20ca690bb4f317c11e45c03d798fa",
    },
    "hsemotion": {
        "file": "enet_b0_8_best_vgaf.onnx",
        "url": "https://raw.githubusercontent.com/av-savchenko/face-emotion-recognition/main/models/"
               "affectnet_emotions/onnx/enet_b0_8_best_vgaf.onnx",
        "sha256": "fa07e841fd06c7a67ee651ea4e6e4a3a2bb5695f47b37a7da50492526f59c898",
    },
    # The benchmark's face detector (OpenCV res10 SSD); only the Python reference uses it, the app uses Vision.
    "res10_prototxt": {
        "file": "deploy.prototxt",
        "url": "https://raw.githubusercontent.com/opencv/opencv/4.10.0/samples/dnn/face_detector/deploy.prototxt",
        "sha256": "dcd661dc48fc9de0a341db1f666a2164ea63a67265c7f779bc12d6b3f2fa67e9",
    },
    "res10_caffemodel": {
        "file": "res10_300x300_ssd_iter_140000.caffemodel",
        "url": "https://raw.githubusercontent.com/opencv/opencv_3rdparty/"
               "dnn_samples_face_detector_20170830/res10_300x300_ssd_iter_140000.caffemodel",
        "sha256": "2a56a11a57a4a295956b0660b4a3d76bbdca2206c4961cea8efe7d95c7cb2f2d",
    },
}

CLIP_ARCH = "ViT-B-32-quickgelu"
CLIP_MEAN = (0.48145466, 0.4578275, 0.40821073)
CLIP_STD = (0.26862954, 0.26130258, 0.27577711)
IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)

# bench.py: EMOS / ADJ / HSE_CLASSES
EMOS = ["anger", "disgust", "fear", "happiness", "neutral", "sadness", "surprise"]
ADJ = {"anger": "angry", "disgust": "disgusted", "fear": "scared", "happiness": "happy",
       "neutral": "neutral, expressionless", "sadness": "sad", "surprise": "surprised, shocked"}
PROMPTS = [f"a photo of a {ADJ[e]} face" for e in EMOS]
HSE_CLASSES = ["anger", "contempt", "disgust", "fear", "happiness", "neutral", "sadness", "surprise"]

EXPRESSION_WEIGHT = 0.2   # w, tuned on the benchmark's dev set
ZERO_SHOT_SCALE = 100.0


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def fetch(name, directory):
    """Downloads a pinned file into `directory` (kept between runs) and checks its hash."""
    spec = WEIGHTS[name]
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, spec["file"])
    if not os.path.exists(path) or (spec["sha256"] and sha256(path) != spec["sha256"]):
        tmp = path + ".part"
        urllib.request.urlretrieve(spec["url"], tmp)
        os.replace(tmp, path)
    if spec["sha256"]:
        got = sha256(path)
        if got != spec["sha256"]:
            raise SystemExit(f"{spec['file']}: sha256 {got} != pinned {spec['sha256']}")
    return path


# ---------- bench.py, verbatim where it matters ----------
def load(path):
    with Image.open(path) as im:
        if getattr(im, "is_animated", False):
            im.seek(0)
        return ImageOps.exif_transpose(im).convert("RGB")


class FaceDetector:
    """bench.py's largest_face, also returning the box it cropped (pixel coordinates before rounding)."""

    def __init__(self, weights_dir):
        import cv2
        self.cv2 = cv2
        self.net = cv2.dnn.readNetFromCaffe(fetch("res10_prototxt", weights_dir), fetch("res10_caffemodel", weights_dir))

    def largest_face_box(self, img, conf=0.5):
        cv2 = self.cv2
        a = np.asarray(img)[:, :, ::-1]
        h, w = a.shape[:2]
        self.net.setInput(cv2.dnn.blobFromImage(cv2.resize(a, (300, 300)), 1.0, (300, 300), (104, 177, 123)))
        det = self.net.forward()[0, 0]
        best = None
        for d in det:
            if d[2] < conf:
                continue
            x1, y1, x2, y2 = (d[3:7] * [w, h, w, h]).astype(int)
            x1, y1, x2, y2 = max(0, x1), max(0, y1), min(w, x2), min(h, y2)
            if x2 - x1 < 12 or y2 - y1 < 12:
                continue
            area = (x2 - x1) * (y2 - y1)
            if best is None or area > best[0]:
                best = (area, (x1, y1, x2, y2))
        if best is None:
            return None
        x1, y1, x2, y2 = best[1]
        m = 0.15 * max(x2 - x1, y2 - y1)
        return (max(0, x1 - m), max(0, y1 - m), min(w, x2 + m), min(h, y2 + m))

    def largest_face(self, img):
        box = self.largest_face_box(img)
        return None if box is None else img.crop(box)


def hse_input(im):
    """bench.py's hse(): resize straight to 224×224 (PIL's default, bicubic), ImageNet-normalize, CHW."""
    x = np.asarray(im.resize((224, 224)), dtype="float32") / 255.0
    x = (x - [0.485, 0.456, 0.406]) / [0.229, 0.224, 0.225]
    return x.transpose(2, 0, 1)[None].astype("float32")


def softmax(z):
    z = np.asarray(z, dtype=np.float64)
    z = z - z.max(-1, keepdims=True)
    p = np.exp(z)
    return p / p.sum(-1, keepdims=True)


def zs_probs(img_emb, text, temp=ZERO_SHOT_SCALE):
    z = temp * img_emb @ text.T
    z -= z.max(1, keepdims=True)
    p = np.exp(z)
    return p / p.sum(1, keepdims=True)


def prob_sim(a, b):  # 1 - total variation distance, in [0,1]
    return 1 - 0.5 * np.abs(a[:, None, :] - b[None, :, :]).sum(-1)


def hybrid_scores(q_full, q_emo, q_zs, g_full, g_emo, g_zs, g_has, w=EXPRESSION_WEIGHT):
    """Queries × gallery scores: (1 - w)·visual + w·expression, as bench.py's B/32 hybrid."""
    visual = (q_full @ g_full.T + 1) / 2
    expr = np.where(g_has[None, :], prob_sim(q_emo, g_emo), prob_sim(q_zs, g_zs))
    return (1 - w) * visual + w * expr


def write_json(path, obj):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f)
