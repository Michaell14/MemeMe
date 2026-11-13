# Third-party models

MemeMe's hybrid matcher (`Sources/MemeMeCore/HybridMatcher.swift`) runs two models on the Mac. `scripts/build-hybrid-models.sh` downloads their weights at build time, pinned by SHA-256 in `scripts/hybrid/hybrid_common.py`, and converts them to Core ML. The weights are never committed, but release builds ship the converted models inside `MemeMe.app`.

| Model | Weights | Code license | Weights and training data |
|---|---|---|---|
| OpenCLIP ViT-B-32-quickgelu, LAION-400M, epoch 32 | `vit_b_32-quickgelu-laion400m_e32-46683a32.pt` ([OpenCLIP v0.2-weights release](https://github.com/mlfoundations/open_clip/releases/tag/v0.2-weights)) | MIT ([open_clip](https://github.com/mlfoundations/open_clip/blob/main/LICENSE)) | Released with the MIT-licensed repository. Trained on LAION-400M, whose metadata is CC-BY 4.0 and whose images belong to their owners. LAION withdrew its datasets in December 2023 after reports of abusive images and later re-released them filtered (Re-LAION). Check the provenance before a public or commercial release. |
| HSEmotion EfficientNet-B0, 8 emotions | `enet_b0_8_best_vgaf.onnx` ([face-emotion-recognition](https://github.com/av-savchenko/face-emotion-recognition/tree/main/models/affectnet_emotions)) | Apache-2.0 ([LICENSE](https://github.com/av-savchenko/face-emotion-recognition/blob/main/LICENSE)) | **Research only.** Trained on AffectNet, whose license allows non-commercial research use only. The checkpoint was chosen on VGAF (EmotiW), which is also an academic dataset. Fine for the class demo. Don't ship it in a public or commercial release without replacing it or getting permission. |

The benchmark's Python reference also uses OpenCV's res10 SSD face detector (`scripts/hybrid/`, BSD/Apache-licensed OpenCV samples). The app doesn't ship it; it uses Apple Vision instead.
