# NOTICE

This repository contains **only installer scripts, documentation, and two
vendored bootstrap archives**. It does not contain AUTOMATIC1111 source code,
model weights, or extension source code. Those are downloaded from their
upstream projects at install time.

## This repository

- `install.ps1`, `install.bat`, `README.md`, `docs/preview.png`:
  MIT License, Copyright (c) 2026 DragonTs and contributors. See `LICENSE`.

## Vendored bootstrap files

- `vendor/pip-24.2-py3-none-any.whl`
  - pip 24.2, MIT License
  - https://github.com/pypa/pip
- `vendor/clip-openai.zip`
  - OpenAI CLIP source snapshot, MIT License
  - https://github.com/openai/CLIP
  - The archive is vendored because GitHub's codeload endpoint is unreliable
    from some networks.

## Downloaded at install time (not redistributed here)

| Component | License | Upstream |
| --- | --- | --- |
| AUTOMATIC1111 Stable Diffusion WebUI | AGPL-3.0 | https://github.com/AUTOMATIC1111/stable-diffusion-webui |
| PyTorch / torchvision | BSD-style | https://github.com/pytorch/pytorch |
| Python 3.10.11 embeddable | PSF-2.0 | https://www.python.org/ |
| Stable Diffusion 1.5 weights (`v1-5-pruned-emaonly.safetensors`) | CreativeML Open RAIL-M | https://huggingface.co/runwayml/stable-diffusion-v1-5 |
| AnimateDiff extension (`sd-webui-animatediff`) | CC BY-NC-SA 4.0 | https://github.com/continue-revolution/sd-webui-animatediff |
| AnimateDiff V2 motion module (`mm_sd_v15_v2.ckpt`) | Apache-2.0 (per model card) | https://huggingface.co/guoyww/animatediff |
| Chinese localization (`zh_CN`) | MIT | https://github.com/dtlnor/stable-diffusion-webui-localization-zh_CN |
| Gradio | Apache-2.0 | https://github.com/gradio-app/gradio |
| PyAV (`av`) | BSD-3-Clause | https://github.com/PyAV-Org/PyAV |
| imageio-ffmpeg | BSD-2-Clause | https://github.com/imageio/imageio-ffmpeg |

## Important

- **AnimateDiff extension code is CC BY-NC-SA 4.0**, which restricts
  commercial use. Check the upstream license before any commercial use.
- The SD 1.5 weights are released under CreativeML Open RAIL-M, which includes
  use-based restrictions. Read the model card before publishing generated
  content.
- Model weights are downloaded from ModelScope / HuggingFace mirrors. Their
  availability and licenses are controlled by their publishers, not by this
  repository.
- This project is not affiliated with AUTOMATIC1111, Stability AI, or the
  AnimateDiff authors. All trademarks belong to their respective owners.
