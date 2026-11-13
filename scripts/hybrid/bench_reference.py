"""The benchmark's B/32 hybrid, as bench.py runs it, on the downloaded benchmark data; the parity reference.

    python bench_reference.py --data DATA_DIR --weights WEIGHTS_DIR --out reference.json [--prompts emotion_prompts.json]

DATA_DIR comes from fetch_benchmark_data.py. The JSON holds, per gallery and query image: the face box the res10
detector found (before the crop's rounding), the CLIP embeddings of the whole image and of the crop (or the whole
image without a face), the HSEmotion probabilities of the crop (or the whole image), and the zero-shot
probabilities; and per test query: the hybrid's top 5 and whether each matches the label (expression match@5).
"""
import argparse
import os
import sys
import time

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hybrid_common as hc  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--weights", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    import onnxruntime as ort
    import open_clip
    import torch
    torch.set_num_threads(2)
    D = lambda *p: os.path.join(args.data, *p)  # noqa: E731

    # ---------- data (bench.py) ----------
    g = pd.read_csv(D("gallery.csv"))
    g["file"] = g["file"].map(lambda f: D("gallery", os.path.basename(f)))
    labels = dict(l.split() for l in open(D("gallery_labels.txt")).read().split("\n") if l.strip())
    g["labels"] = g["id"].map(lambda k: set(labels[k].split(";")))
    g = g[g["file"].map(os.path.exists)].reset_index(drop=True)
    q = pd.read_csv(D("queries_sample.csv"))
    q["file"] = q["image"].map(lambda f: D("queries", f))
    q = q[q["file"].map(os.path.exists)].reset_index(drop=True)
    rng = np.random.RandomState(5210)
    q["split"] = "test"
    for e, idx in q.groupby("emotion").groups.items():
        idx = list(idx)
        rng.shuffle(idx)
        q.loc[idx[: len(idx) // 2], "split"] = "dev"
    G_imgs = [hc.load(f) for f in g["file"]]
    Q_imgs = [hc.load(f) for f in q["file"]]
    print(f"gallery={len(g)} queries={len(q)} dev={sum(q.split == 'dev')} test={sum(q.split == 'test')}", flush=True)

    det = hc.FaceDetector(args.weights)
    G_box = [det.largest_face_box(im) for im in G_imgs]
    Q_box = [det.largest_face_box(im) for im in Q_imgs]
    G_face = [None if b is None else im.crop(b) for im, b in zip(G_imgs, G_box)]
    Q_face = [None if b is None else im.crop(b) for im, b in zip(Q_imgs, Q_box)]
    Qf = [c if c is not None else im for c, im in zip(Q_face, Q_imgs)]
    Gf = [c if c is not None else im for c, im in zip(G_face, G_imgs)]
    G_has = np.array([c is not None for c in G_face])
    print("faces found: gallery", int(G_has.sum()), "/", len(g), " queries",
          sum(c is not None for c in Q_face), "/", len(q), flush=True)

    # ---------- CLIP B/32 ----------
    model, _, pre = open_clip.create_model_and_transforms(hc.CLIP_ARCH, pretrained=hc.fetch("clip", args.weights))
    model.eval()
    tok = open_clip.get_tokenizer(hc.CLIP_ARCH)

    @torch.inference_mode()
    def embed(imgs, bs=16):
        out = []
        for i in range(0, len(imgs), bs):
            x = torch.stack([pre(im) for im in imgs[i:i + bs]])
            f = model.encode_image(x)
            out.append(torch.nn.functional.normalize(f, dim=-1).numpy())
        return np.concatenate(out).astype("float32")

    with torch.inference_mode():
        T = torch.nn.functional.normalize(model.encode_text(tok(hc.PROMPTS)), dim=-1).numpy()

    E_G, E_Q, E_Gf, E_Qf = embed(G_imgs), embed(Q_imgs), embed(Gf), embed(Qf)

    # ---------- HSEmotion ----------
    sess = ort.InferenceSession(hc.fetch("hsemotion", args.weights), providers=["CPUExecutionProvider"])
    name = sess.get_inputs()[0].name

    def hse(imgs):
        out = []
        for im in imgs:
            logits = sess.run(None, {name: hc.hse_input(im)})[0][0]
            p = np.exp(logits - logits.max())
            out.append(p / p.sum())
        return np.array(out, dtype="float32")

    H_G, H_Q = hse(Gf), hse(Qf)
    ZS_Q, ZS_G = hc.zs_probs(E_Qf, T), hc.zs_probs(E_G, T)
    S = hc.hybrid_scores(E_Q, H_Q, ZS_Q, E_G, H_G, ZS_G, G_has)
    S_clip = E_Q @ E_G.T

    lab = q["emotion"].values
    test = np.where(q.split == "test")[0]
    dev = np.where(q.split == "dev")[0]

    def per_query(score, idx, k=5):
        return np.array([np.mean([lab[i] in g["labels"].iloc[j] for j in np.argsort(-score[i])[:k]]) for i in idx])

    def macro(score, idx):
        v = per_query(score, idx)
        e = lab[idx]
        return float(np.mean([v[e == c].mean() for c in hc.EMOS]))

    results = {
        "hybrid_p5_test": float(per_query(S, test).mean()), "hybrid_p5_macro_test": macro(S, test),
        "hybrid_p5_dev": float(per_query(S, dev).mean()),
        "clip_p5_test": float(per_query(S_clip, test).mean()), "clip_p5_macro_test": macro(S_clip, test),
    }
    print({k: round(v, 4) for k, v in results.items()}, flush=True)

    # ---------- latency (bench.py's hybrid_b, gallery precomputed) ----------
    def hybrid_once(im):
        f = det.largest_face(im) or im
        return embed([im]) @ E_G.T, hse([f]), hc.zs_probs(embed([f]), T)

    def live_once(im):
        return hse([det.largest_face(im) or im])

    def time_it(fn, n=12):
        idx = list(range(0, len(Q_imgs), max(1, len(Q_imgs) // n)))[:n]
        fn(Q_imgs[0])
        ts = []
        for i in idx:
            t = time.perf_counter()
            fn(Q_imgs[i])
            ts.append(time.perf_counter() - t)
        return float(np.mean(ts))

    results["latency_held_search_s"] = time_it(hybrid_once)
    results["latency_live_frame_s"] = time_it(live_once)
    print("latency", results["latency_held_search_s"], results["latency_live_frame_s"], flush=True)

    def item(kind, i, path, box, full, face, emo, zs):
        return {"kind": kind, "index": int(i), "file": os.path.relpath(path, args.data),
                "box": None if box is None else [float(v) for v in box],
                "clip_full": full.tolist(), "clip_face": face.tolist(), "emo": emo.tolist(), "zs": zs.tolist()}

    images = [item("gallery", i, g["file"][i], G_box[i], E_G[i], E_Gf[i], H_G[i], ZS_G[i]) for i in range(len(g))]
    images += [item("query", i, q["file"][i], Q_box[i], E_Q[i], E_Qf[i], H_Q[i], ZS_Q[i]) for i in range(len(q))]
    hc.write_json(args.out, {
        "results": results,
        "gallery": [{"id": g["id"][i], "file": os.path.relpath(g["file"][i], args.data),
                     "labels": sorted(g["labels"][i]), "has_face": bool(G_has[i])} for i in range(len(g))],
        "queries": [{"file": os.path.relpath(q["file"][i], args.data), "emotion": lab[i], "split": q["split"][i]}
                    for i in range(len(q))],
        "top5": {int(i): [g["id"][j] for j in np.argsort(-S[i])[:5]] for i in test},
        "images": images,
        "prompts": T.tolist(),
    })
    print("wrote", args.out)


if __name__ == "__main__":
    main()
