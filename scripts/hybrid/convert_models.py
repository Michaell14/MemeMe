"""Builds the hybrid matcher's on-device models from the pinned weights.

    python convert_models.py --weights WEIGHTS_DIR --out OUT_DIR [--prompts-only] [--check-prompts FILE]

Writes to OUT_DIR:
  CLIPImage.mlpackage   OpenCLIP ViT-B-32-quickgelu (LAION-400M e32) image tower, fp16, input "image"
                        [1, 3, 224, 224] (CLIP-normalized RGB), output "embedding" [1, 512] (not normalized)
  HSEmotion.mlpackage   HSEmotion enet_b0_8_best_vgaf (ONNX → PyTorch with onnx2torch → Core ML), fp32, input
                        "image" [1, 3, 224, 224] (ImageNet-normalized RGB), output "logits" [1, 8]
  emotion_prompts.json  the 7 zero-shot prompts' text embeddings, L2-normalized (the app never runs the text tower)
  manifest.json         weight hashes and versions

The weights are downloaded once into WEIGHTS_DIR and checked against the hashes in hybrid_common.py.
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hybrid_common as hc  # noqa: E402


def clip_model(weights_dir):
    import open_clip
    path = hc.fetch("clip", weights_dir)
    model, _, preprocess = open_clip.create_model_and_transforms(hc.CLIP_ARCH, pretrained=path)
    return model.eval(), preprocess, open_clip.get_tokenizer(hc.CLIP_ARCH)


def prompt_embeddings(model, tokenizer):
    import torch
    with torch.inference_mode():
        t = model.encode_text(tokenizer(hc.PROMPTS))
        t = torch.nn.functional.normalize(t, dim=-1).numpy().astype(np.float32)
    return t


def write_prompts(path, t):
    hc.write_json(path, {
        "model": f"{hc.CLIP_ARCH} laion400m_e32",
        "classes": hc.EMOS,
        "prompts": hc.PROMPTS,
        "scale": hc.ZERO_SHOT_SCALE,
        "embeddings": [[float(v) for v in row] for row in t],
    })


def clip_precision(name):
    import coremltools as ct
    if name == "fp32":
        return ct.precision.FLOAT32
    return ct.precision.FLOAT16


def convert_clip(model, out_dir, precision="fp16"):
    import coremltools as ct
    import torch

    class Visual(torch.nn.Module):
        def __init__(self, visual):
            super().__init__()
            self.visual = visual

        def forward(self, image):
            return self.visual(image)

    # PyTorch's fused attention kernel doesn't convert; the plain one computes the same thing.
    if hasattr(torch.backends, "mha"):
        torch.backends.mha.set_fastpath_enabled(False)
    wrapped = Visual(model.visual).eval()
    example = torch.randn(1, 3, 224, 224)
    with torch.inference_mode():
        traced = torch.jit.trace(wrapped, example)
        reference = wrapped(example).numpy()
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=(1, 3, 224, 224), dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=clip_precision(precision),
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = f"OpenCLIP ViT-B-32-quickgelu (LAION-400M e32) image encoder ({precision})"
    path = os.path.join(out_dir, "CLIPImage.mlpackage")
    mlmodel.save(path)
    return path, example.numpy(), reference


def convert_hsemotion(weights_dir, out_dir):
    import coremltools as ct
    import onnx
    import onnxruntime as ort
    import torch
    from onnx2torch import convert

    onnx_path = hc.fetch("hsemotion", weights_dir)
    torch_model = convert(onnx.load(onnx_path)).eval()
    sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    rng = np.random.RandomState(0)
    worst = 0.0
    for _ in range(4):
        x = rng.randn(1, 3, 224, 224).astype(np.float32)
        want = sess.run(None, {sess.get_inputs()[0].name: x})[0]
        with torch.inference_mode():
            got = torch_model(torch.from_numpy(x)).numpy()
        worst = max(worst, float(np.abs(want - got).max()))
    if worst > 1e-3:
        raise SystemExit(f"onnx2torch changed HSEmotion's logits by {worst}")
    print(f"HSEmotion ONNX → PyTorch: max logit difference {worst:.2e}")

    example = torch.randn(1, 3, 224, 224)
    with torch.inference_mode():
        traced = torch.jit.trace(torch_model, example)
        reference = torch_model(example).numpy()
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=(1, 3, 224, 224), dtype=np.float32)],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        convert_to="mlprogram",
        # A small model: full precision costs ~16 MB and keeps the 8 probabilities within the parity bound easily.
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = "HSEmotion EfficientNet-B0 enet_b0_8_best_vgaf (8 AffectNet emotions)"
    path = os.path.join(out_dir, "HSEmotion.mlpackage")
    mlmodel.save(path)
    return path, example.numpy(), reference


def check_on_device(path, name, x, reference):
    """On macOS, runs the converted model once against the PyTorch output."""
    if sys.platform != "darwin":
        print(f"{name}: not checked (Core ML predictions need macOS)")
        return
    import coremltools as ct
    out_name = "embedding" if name == "CLIPImage" else "logits"
    got = ct.models.MLModel(path).predict({"image": x})[out_name]
    a, b = got.reshape(-1).astype(np.float64), reference.reshape(-1).astype(np.float64)
    cos = float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))
    print(f"{name}: Core ML vs PyTorch cosine {cos:.5f}, max abs {float(np.abs(a - b).max()):.4f}")
    if cos < 0.99:
        raise SystemExit(f"{name}: converted model disagrees with PyTorch (cosine {cos})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--prompts-only", action="store_true")
    ap.add_argument("--check-prompts", help="a committed emotion_prompts.json the new one must match")
    ap.add_argument("--clip-precision", choices=["fp16", "fp32"], default="fp16",
                    help="fp16 ships; fp32 (twice the size) only for the benchmark's comparison")
    ap.add_argument("--clip-only", action="store_true", help="convert the CLIP image encoder only")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    model, _, tokenizer = clip_model(args.weights)
    t = prompt_embeddings(model, tokenizer)
    write_prompts(os.path.join(args.out, "emotion_prompts.json"), t)
    if args.check_prompts:
        committed = np.array(json.load(open(args.check_prompts))["embeddings"], dtype=np.float32)
        diff = float(np.abs(committed - t).max())
        print(f"emotion prompts vs {args.check_prompts}: max abs difference {diff:.2e}")
        if diff > 1e-4:
            raise SystemExit("the committed emotion_prompts.json no longer matches the weights")
    if args.prompts_only:
        return

    import coremltools
    import torch
    clip_path, cx, cref = convert_clip(model, args.out, args.clip_precision)
    check_on_device(clip_path, "CLIPImage", cx, cref)
    if args.clip_only:
        return
    hse_path, hx, href = convert_hsemotion(args.weights, args.out)
    check_on_device(hse_path, "HSEmotion", hx, href)
    hc.write_json(os.path.join(args.out, "manifest.json"), {
        "clip": {"arch": hc.CLIP_ARCH, **hc.WEIGHTS["clip"]},
        "hsemotion": hc.WEIGHTS["hsemotion"],
        "coremltools": coremltools.__version__,
        "torch": torch.__version__,
    })
    print("wrote", args.out)


if __name__ == "__main__":
    main()
