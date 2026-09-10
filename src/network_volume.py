"""
Network Volume diagnostics for worker-comfyui.

This module provides tools to debug network volume model path issues.
Enable diagnostics by setting NETWORK_VOLUME_DEBUG=true environment variable.
"""

import os

# Expected model types and their file extensions
MODEL_TYPES = {
    "checkpoints": [".safetensors", ".ckpt", ".pt", ".pth", ".bin"],
    "clip": [".safetensors", ".pt", ".bin"],
    "clip_vision": [".safetensors", ".pt", ".bin"],
    "configs": [".yaml", ".json"],
    "controlnet": [".safetensors", ".pt", ".pth", ".bin"],
    "embeddings": [".safetensors", ".pt", ".bin"],
    "loras": [".safetensors", ".pt"],
    "upscale_models": [".safetensors", ".pt", ".pth"],
    "vae": [".safetensors", ".pt", ".bin"],
    "unet": [".safetensors", ".pt", ".bin"],
    "diffusion_models": [".safetensors", ".ckpt", ".pt", ".pth", ".bin", ".gguf"],
    "text_encoders": [".safetensors", ".pt", ".bin"],
}


def is_network_volume_debug_enabled():
    """Check if network volume debug mode is enabled via environment variable."""
    return os.environ.get("NETWORK_VOLUME_DEBUG", "false").lower() == "true"


def run_network_volume_diagnostics():
    """
    Run comprehensive network volume diagnostics and print helpful output.
    Only runs when NETWORK_VOLUME_DEBUG=true environment variable is set.
    """
    print("=" * 70)
    print("NETWORK VOLUME DIAGNOSTICS (NETWORK_VOLUME_DEBUG=true)")
    print("=" * 70)

    # Check extra_model_paths.yaml
    extra_model_paths_file = "/comfyui/extra_model_paths.yaml"
    print("\n[1] Checking extra_model_paths.yaml configuration...")
    if os.path.isfile(extra_model_paths_file):
        print(f"    ✓ FOUND: {extra_model_paths_file}")
        with open(extra_model_paths_file, "r") as f:
            content = f.read()
            print("\n    Configuration content:")
            for line in content.split("\n"):
                print(f"      {line}")
    else:
        print(f"    ✗ NOT FOUND: {extra_model_paths_file}")
        print(
            "    This file is required for ComfyUI to find models on the network volume."
        )

    overlay = "/tmp/extra_custom_nodes_paths.yaml"
    print("\n[1b] Checking volume custom-nodes overlay...")
    if os.path.isfile(overlay):
        print(f"    ✓ FOUND: {overlay}")
        with open(overlay, "r") as f:
            for line in f.read().split("\n"):
                print(f"      {line}")
    else:
        print(f"    (none) {overlay} not present — volume custom nodes not registered")

    # Check network volume mount
    runpod_volume = "/runpod-volume"
    print(f"\n[2] Checking network volume mount at {runpod_volume}...")
    if os.path.isdir(runpod_volume):
        print(f"    ✓ MOUNTED: {runpod_volume}")
    else:
        print(f"    ✗ NOT MOUNTED: {runpod_volume}")
        print(
            "    Make sure you have attached a network volume to your serverless endpoint."
        )
        print("=" * 70)
        return

    # Check directory structure
    print("\n[3] Checking directory structure...")
    models_dir = os.path.join(runpod_volume, "models")
    if os.path.isdir(models_dir):
        print(f"    ✓ FOUND: {models_dir}")
    else:
        print(f"    ✗ NOT FOUND: {models_dir}")
        print("\n    ⚠️  PROBLEM: The 'models' directory does not exist!")
        print("    You need to create the following structure on your network volume:")
        print_expected_structure()
        # Continue — custom_nodes may still exist without models/

    # List model directories and their contents
    print("\n[4] Scanning model directories...")
    found_any_models = False

    if os.path.isdir(models_dir):
        for model_type, extensions in MODEL_TYPES.items():
            model_path = os.path.join(models_dir, model_type)
            if os.path.isdir(model_path):
                files = []
                try:
                    for f in os.listdir(model_path):
                        file_path = os.path.join(model_path, f)
                        if os.path.isfile(file_path):
                            # Check if file has valid extension
                            ext = os.path.splitext(f)[1].lower()
                            if ext in extensions:
                                size = os.path.getsize(file_path)
                                size_str = format_size(size)
                                files.append(f"{f} ({size_str})")
                                found_any_models = True
                            else:
                                files.append(f"{f} (⚠️ ignored - invalid extension)")
                except Exception as e:
                    print(f"    {model_type}/: Error reading directory - {e}")
                    continue

                if files:
                    print(f"\n    {model_type}/:")
                    for f in files:
                        print(f"      - {f}")
                else:
                    print(f"\n    {model_type}/: (empty)")
            else:
                print(f"\n    {model_type}/: (directory not found)")
    else:
        print("    (skipped — models/ missing)")

    # Custom nodes on volume
    print("\n[4b] Scanning custom_nodes on volume...")
    custom_nodes_dir = os.path.join(runpod_volume, "custom_nodes")
    staged_dir = "/tmp/runpod_volume_custom_nodes"
    found_nodes = False
    if os.path.isdir(custom_nodes_dir):
        print(f"    ✓ FOUND: {custom_nodes_dir}")
        try:
            entries = sorted(os.listdir(custom_nodes_dir))
        except Exception as e:
            entries = []
            print(f"    Error reading directory - {e}")
        for name in entries:
            path = os.path.join(custom_nodes_dir, name)
            if not os.path.isdir(path) or name.startswith("."):
                continue
            found_nodes = True
            baked = os.path.isdir(os.path.join("/comfyui/custom_nodes", name))
            has_req = os.path.isfile(os.path.join(path, "requirements.txt"))
            staged = os.path.isdir(os.path.join(staged_dir, name)) or os.path.islink(
                os.path.join(staged_dir, name)
            )
            flags = []
            if baked:
                flags.append("baked-in-image→skipped")
            if has_req:
                flags.append("has requirements.txt")
            if staged:
                flags.append("staged for load")
            flag_str = f" ({', '.join(flags)})" if flags else ""
            print(f"      - {name}/{flag_str}")
        if not found_nodes:
            print("    (directory empty — no node packages)")
    else:
        print(f"    ✗ NOT FOUND: {custom_nodes_dir}")
        print("    Place node packs at /runpod-volume/custom_nodes/<NodePack>/")

    # Summary
    print("\n[5] Summary")
    if found_any_models:
        print("    ✓ Models found on network volume!")
    else:
        print("    ⚠️  No valid model files found on network volume!")
        print("\n    Make sure your models have the correct file extensions:")
        print("    - Checkpoints: .safetensors, .ckpt, .pt, .pth, .bin")
        print("    - LoRAs: .safetensors, .pt")
        print("    - VAE: .safetensors, .pt, .bin")
        print("    - etc.")

    if found_nodes:
        print("    ✓ Custom node packages found on network volume!")
    else:
        print("    ⚠️  No custom node packages found under custom_nodes/")

    print_expected_structure()
    print("=" * 70)


def print_expected_structure():
    """Print the expected directory structure for the network volume."""
    print("\n    Expected directory structure:")
    print("    /runpod-volume/")
    print("    ├── models/")
    print("    │   ├── checkpoints/")
    print("    │   ├── diffusion_models/")
    print("    │   ├── text_encoders/")
    print("    │   ├── loras/")
    print("    │   ├── vae/")
    print("    │   └── ...")
    print("    └── custom_nodes/")
    print("        ├── SomeNodePack/          <- git clone / unpacked repo")
    print("        │   ├── __init__.py")
    print("        │   └── requirements.txt   <- installed at boot into /opt/venv")
    print("        └── AnotherNodePack/")


def format_size(size_bytes):
    """Format bytes into human-readable size."""
    for unit in ["B", "KB", "MB", "GB"]:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} TB"
