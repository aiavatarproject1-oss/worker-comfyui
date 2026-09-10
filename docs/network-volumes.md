# Network Volumes & Model Paths

This document explains how to use RunPod **Network Volumes** with `worker-comfyui`, how model paths are resolved inside the container, and how to debug cases where models are not detected.

> **Scope**
>
> These instructions apply to **serverless endpoints** using this worker. Pods mount network volumes at `/workspace` by default, while serverless workers see them at `/runpod-volume`.

## Directory Mapping

For **serverless endpoints**:

- Network volume root is mounted at: `/runpod-volume`
- ComfyUI models are expected under: `/runpod-volume/models/...`

For **Pods**:

- Network volume root is mounted at: `/workspace`
- Equivalent ComfyUI model path: `/workspace/models/...`

If you use the S3-compatible API, the same paths map as:

- Serverless: `/runpod-volume/my-folder/file.txt`
- Pod: `/workspace/my-folder/file.txt`
- S3 API: `s3://<NETWORK_VOLUME_ID>/my-folder/file.txt`

## Expected Directory Structure

Models and optional custom nodes must be placed in the following structure on your network volume:

```text
/runpod-volume/
├── models/
│   ├── checkpoints/      # Stable Diffusion checkpoints (.safetensors, .ckpt)
│   ├── loras/            # LoRA files (.safetensors, .pt)
│   ├── vae/              # VAE models (.safetensors, .pt)
│   ├── clip/             # CLIP models (.safetensors, .pt)
│   ├── clip_vision/      # CLIP Vision models
│   ├── controlnet/       # ControlNet models (.safetensors, .pt)
│   ├── embeddings/       # Textual inversion embeddings (.safetensors, .pt)
│   ├── upscale_models/   # Upscaling models (.safetensors, .pt)
│   ├── unet/             # UNet models (legacy path)
│   ├── diffusion_models/ # UNETLoader / modern diffusion weights
│   ├── text_encoders/    # CLIPLoader / DualCLIP / text encoders
│   └── configs/          # Model configs (.yaml, .json)
└── custom_nodes/         # Optional — loaded at worker boot
    └── SomeNodePack/     # One git clone / unpacked package per folder
        ├── __init__.py
        └── requirements.txt
```

> **Note**
>
> Only create the subdirectories you actually need; empty or missing folders are fine.

## Custom nodes on the network volume

On serverless boot, if `/runpod-volume/custom_nodes/` exists and `NETWORK_VOLUME_CUSTOM_NODES` is not `false`:

1. Each immediate subfolder is treated as a ComfyUI custom-node package.
2. Packages whose name already exists under `/comfyui/custom_nodes/` (baked into the image) are **skipped**.
3. Remaining packages are registered via `--extra-model-paths-config` (so a missing volume path never blocks ComfyUI startup).
4. Unless `SKIP_VOLUME_NODE_DEPS=true`, each package's `requirements.txt` is installed with `uv pip` into `/opt/venv`.

From a Pod (volume mounted at `/workspace`), the same layout is:

```text
/workspace/custom_nodes/ComfyUI-KJNodes/
/workspace/custom_nodes/ComfyUI-VideoHelperSuite/
```

**Caveats:** boot-time pip increases cold start; nodes that need system packages, CUDA compile, or tightly pinned stacks are safer baked into the Dockerfile. Never rely on ComfyUI-Manager at runtime — it is forced offline.

## Supported File Extensions

ComfyUI only recognizes files with specific extensions when scanning model directories.

| Model Type     | Supported Extensions                        |
| -------------- | ------------------------------------------- |
| Checkpoints    | `.safetensors`, `.ckpt`, `.pt`, `.pth`, `.bin` |
| LoRAs          | `.safetensors`, `.pt`                       |
| VAE            | `.safetensors`, `.pt`, `.bin`               |
| CLIP           | `.safetensors`, `.pt`, `.bin`               |
| ControlNet     | `.safetensors`, `.pt`, `.pth`, `.bin`       |
| Embeddings     | `.safetensors`, `.pt`, `.bin`               |
| Upscale Models | `.safetensors`, `.pt`, `.pth`               |

Files with other extensions (for example `.txt`, `.zip`) are **ignored** by ComfyUI’s model discovery.

## Common Issues

- **Wrong root directory**
  - Models placed directly under `/runpod-volume/checkpoints/...` instead of `/runpod-volume/models/checkpoints/...`.
- **Incorrect extensions**
  - Files named without one of the supported extensions are skipped.
- **Empty directories**
  - No actual model files present in `models/checkpoints` (or other folders).
- **Volume not attached**
  - Endpoint created without selecting a network volume under **Advanced → Select Network Volume**.

If any of the above is true, ComfyUI will silently fail to discover models from the network volume.

## Debugging with `NETWORK_VOLUME_DEBUG`

The worker exposes an opt‑in debug mode controlled via the `NETWORK_VOLUME_DEBUG` environment variable.

### When to Use

Enable this when:

- Models on your network volume are not appearing in ComfyUI
- You suspect the directory structure or file extensions are wrong
- You want to quickly verify what the worker can actually see on `/runpod-volume`

### How to Enable

1. Go to your serverless **Endpoint → Manage → Edit**.
2. Under **Environment Variables**, add:

   - `NETWORK_VOLUME_DEBUG=true`

3. Save and wait for workers to restart (or scale to zero and back up).
4. Send any request to your endpoint (even a minimal one) to trigger the diagnostics.

### Reading the Diagnostics

When enabled, each request prints a detailed report to the worker logs, for example:

```text
======================================================================
NETWORK VOLUME DIAGNOSTICS (NETWORK_VOLUME_DEBUG=true)
======================================================================

[1] Checking extra_model_paths.yaml configuration...
    ✓ FOUND: /comfyui/extra_model_paths.yaml

[2] Checking network volume mount at /runpod-volume...
    ✓ MOUNTED: /runpod-volume

[3] Checking directory structure...
    ✓ FOUND: /runpod-volume/models

[4] Scanning model directories...

    checkpoints/:
      - my-model.safetensors (6.5 GB)

    loras/:
      - style-lora.safetensors (144.2 MB)

[5] Summary
    ✓ Models found on network volume!
======================================================================
```

If there is a problem, the diagnostics will instead highlight it, for example:

- Missing `models/` directory
- No valid model files in any subdirectory
- Files present but ignored due to wrong extensions

### Disabling Debug Mode

Once you have resolved your issue, disable diagnostics to keep logs clean:

- Remove the `NETWORK_VOLUME_DEBUG` environment variable, **or**
- Set `NETWORK_VOLUME_DEBUG=false`

This returns the worker to normal behavior without extra log noise.


