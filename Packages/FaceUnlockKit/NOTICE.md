# NOTICE — FaceUnlockKit third-party components

FaceUnlockKit is a port of the face-unlock core of **Glance**. It includes code and a model from the components below.

## Glance (MIT)

- Source: <https://github.com/jonnyoo/glance> (ported from commit `b97f521397ec1197ba17768ba797cae1e628848d`)
- Copyright (c) 2026 Jonathan Zhou
- License: MIT. Full text in [`LICENSES/Glance-MIT.txt`](LICENSES/Glance-MIT.txt).
- Every adapted source file starts with "Adapted from Glance (MIT) by Jonathan Zhou".

## SkyLightWindow (MIT)

- Source: <https://github.com/Lakr233/SkyLightWindow>
- Copyright (c) 2025 Lakr Aream
- License: MIT. Full text in [`LICENSES/SkyLightWindow-MIT.txt`](LICENSES/SkyLightWindow-MIT.txt).
- Glance's `NotchSkyLight.swift` is based on it, and `Sources/FaceUnlockKit/System/LockScreenWindowHelper.swift` is based on that file.

## InsightFace ArcFace model (`w600k_mbf`): non-commercial research use only

- File: `Sources/FaceUnlockKit/Resources/ArcFaceModel/` is Glance's `glance/Models/ArcFace.mlpackage`, copied byte for byte. Only the folder was renamed (the `.mlpackage` extension was dropped) so that SwiftPM doesn't try to run `coremlc`.
  - `Data/com.apple.CoreML/model.mlmodel`, sha256 `858f0f0f3bf3766ce41e39f2c26c86bab47b84100e7eaecf4c5ef87b3b3fad3a`
  - `Data/com.apple.CoreML/weights/weight.bin`, sha256 `994e849b8fd0d44dbb33b4aac42d1e0b49b8410ede0f9d32b93ae5d827ed6e68`
- Origin: InsightFace (<https://github.com/deepinsight/insightface>), `buffalo_s` model pack, recognition model
  `w600k_mbf` (MobileFaceNet backbone, trained on WebFace600K). Glance's `tools/convert_arcface.py` converted it to Core ML.
- License: InsightFace releases its pretrained models and the training data behind them **for non-commercial research
  purposes only**. The MIT license on Glance's code and on this package does **not** apply to the model weights. Any
  commercial use needs a separate license from InsightFace (the licensing contact is listed in the InsightFace
  README).
- This package is meant for a personal, non-commercial app. If you ship anything commercially, swap in a model whose
  license allows it, keeping the same contract: input `input_image` 112×112 RGB, output `embedding` with 512 floats.
  Change `ArcFaceEmbedder.modelIdentifier` too, so that old enrollments are flagged as stale.

## Security disclaimer (inherited from Glance)

A MacBook webcam sees a flat 2D image. Liveness checks reasonably defeat a printed photo or a photo on a phone screen,
but they do **not** reliably defeat a video of the enrolled user. macOS has no API that lets a third-party app authorize
a login, so this package unlocks by typing the stored login password on the lock screen. It is a convenience feature,
not a security upgrade.
