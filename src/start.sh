#!/usr/bin/env bash

# Start SSH server if PUBLIC_KEY is set (enables remote access and dev-sync.sh)
if [ -n "$PUBLIC_KEY" ]; then
    mkdir -p ~/.ssh
    echo "$PUBLIC_KEY" > ~/.ssh/authorized_keys
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/authorized_keys

    # Generate host keys if they don't exist (removed during image build for security)
    for key_type in rsa ecdsa ed25519; do
        key_file="/etc/ssh/ssh_host_${key_type}_key"
        if [ ! -f "$key_file" ]; then
            ssh-keygen -t "$key_type" -f "$key_file" -q -N ''
        fi
    done

    service ssh start && echo "worker-comfyui: SSH server started" || echo "worker-comfyui: SSH server could not be started" >&2
fi

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

# ---------------------------------------------------------------------------
# GPU pre-flight check
# Verify that the GPU is accessible before starting ComfyUI. If PyTorch
# cannot initialize CUDA the worker will never be able to process jobs,
# so we fail fast with an actionable error message.
# ---------------------------------------------------------------------------
echo "worker-comfyui: Checking GPU availability..."
if ! GPU_CHECK=$(python3 -c "
import torch
try:
    torch.cuda.init()
    name = torch.cuda.get_device_name(0)
    cap = torch.cuda.get_device_capability(0)
    # Launch a real kernel. The driver-only calls above succeed even when this
    # PyTorch build has no compiled kernels for the GPU architecture (e.g. an
    # older torch on a newer GPU). Without this, the worker boots, ComfyUI dies
    # on the first GPU op, and it surfaces as the misleading 'server not
    # reachable' error instead of a clear cause here.
    _ = (torch.zeros(8, device='cuda') + 1).sum().item()
    torch.cuda.synchronize()
    print(f'OK: {name} (sm_{cap[0]}{cap[1]}), torch {torch.__version__}, cuda {torch.version.cuda}')
except Exception as e:
    print(f'FAIL: {e}')
    exit(1)
" 2>&1); then
    echo "worker-comfyui: GPU is not available or incompatible with this PyTorch build:"
    echo "worker-comfyui: $GPU_CHECK"
    echo "worker-comfyui: A 'no kernel image is available' error means this torch build"
    echo "worker-comfyui: lacks kernels for this GPU. Otherwise the GPU may not be"
    echo "worker-comfyui: properly initialized — please contact RunPod support."
    exit 1
fi
echo "worker-comfyui: GPU available — $GPU_CHECK"

# Ensure ComfyUI-Manager runs in offline network mode inside the container
comfy-manager-set-mode offline || echo "worker-comfyui - Could not set ComfyUI-Manager network_mode" >&2

# ---------------------------------------------------------------------------
# Network-volume custom nodes
# Register /runpod-volume/custom_nodes via an overlay yaml only when present.
# ComfyUI fails to start if custom_nodes is listed in yaml but the path is
# missing, so we never bake that key into the default extra_model_paths.yaml.
# Python deps are installed into /opt/venv with uv pip (not bare pip).
# ---------------------------------------------------------------------------
COMFY_EXTRA_ARGS=()
VOLUME_CUSTOM_NODES="${NETWORK_VOLUME_CUSTOM_NODES_PATH:-/runpod-volume/custom_nodes}"
STAGED_CUSTOM_NODES="/tmp/runpod_volume_custom_nodes"
ENABLE_VOLUME_CUSTOM_NODES="${NETWORK_VOLUME_CUSTOM_NODES:-true}"
SKIP_VOLUME_NODE_DEPS="${SKIP_VOLUME_NODE_DEPS:-false}"

setup_volume_custom_nodes() {
    if [ "${ENABLE_VOLUME_CUSTOM_NODES}" != "true" ]; then
        echo "worker-comfyui: NETWORK_VOLUME_CUSTOM_NODES!=true — skipping volume custom nodes"
        return 0
    fi

    if [ ! -d "${VOLUME_CUSTOM_NODES}" ]; then
        echo "worker-comfyui: No custom nodes directory at ${VOLUME_CUSTOM_NODES} (skipping)"
        return 0
    fi

    rm -rf "${STAGED_CUSTOM_NODES}"
    mkdir -p "${STAGED_CUSTOM_NODES}"

    local enabled=0
    local skipped=0
    shopt -s nullglob
    for node_dir in "${VOLUME_CUSTOM_NODES}"/*/; do
        local name
        name="$(basename "${node_dir}")"

        # Skip hidden / Manager metadata dirs
        case "${name}" in
            .*|__pycache__|websocket_image_save) continue ;;
        esac

        if [ -d "/comfyui/custom_nodes/${name}" ]; then
            echo "worker-comfyui: skip volume custom node '${name}' (already baked into image)"
            skipped=$((skipped + 1))
            continue
        fi

        ln -sfn "${node_dir%/}" "${STAGED_CUSTOM_NODES}/${name}"
        enabled=$((enabled + 1))
        echo "worker-comfyui: enabled volume custom node '${name}'"

        if [ "${SKIP_VOLUME_NODE_DEPS}" = "true" ]; then
            continue
        fi

        if [ -f "${node_dir}/requirements.txt" ]; then
            echo "worker-comfyui: installing deps for volume custom node '${name}' into /opt/venv"
            if ! uv pip install --no-cache-dir -r "${node_dir}/requirements.txt"; then
                echo "worker-comfyui: WARNING — failed to install requirements for '${name}'" >&2
            fi
        fi
    done
    shopt -u nullglob

    if [ "${enabled}" -eq 0 ]; then
        echo "worker-comfyui: no volume custom nodes to load (enabled=0, skipped=${skipped})"
        return 0
    fi

    cat > /tmp/extra_custom_nodes_paths.yaml <<EOF
runpod_volume_custom_nodes:
  custom_nodes: ${STAGED_CUSTOM_NODES}
EOF
    COMFY_EXTRA_ARGS+=(--extra-model-paths-config /tmp/extra_custom_nodes_paths.yaml)
    echo "worker-comfyui: registered ${enabled} volume custom node(s) (skipped baked duplicates: ${skipped})"
}

setup_volume_custom_nodes

# MiniMaxH3 (and similar large video models) can hang forever at the first
# sampler step under DynamicVRAM / ModelPatcherDynamic — ComfyUI sees
# "First sampler step" then never advances and never errors (upstream
# #15628 / #15566). On large-VRAM RunPod hosts (e.g. 96GB PRO 6000) we do
# not need streaming weights; load models normally instead.
# Override with COMFY_DISABLE_DYNAMIC_VRAM=false if you need DynamicVRAM.
: "${COMFY_DISABLE_DYNAMIC_VRAM:=true}"
if [ "${COMFY_DISABLE_DYNAMIC_VRAM}" = "true" ]; then
    COMFY_EXTRA_ARGS+=(--disable-dynamic-vram --highvram)
    echo "worker-comfyui: DynamicVRAM disabled (--disable-dynamic-vram --highvram)"
fi

echo "worker-comfyui: Starting ComfyUI"

# Allow operators to tweak verbosity; default is DEBUG.
: "${COMFY_LOG_LEVEL:=DEBUG}"

# PID file used by the handler to detect if ComfyUI is still running
COMFY_PID_FILE="/tmp/comfyui.pid"

# Serve the API and don't shutdown the container
if [ "$SERVE_API_LOCALLY" == "true" ]; then
    python -u /comfyui/main.py --disable-auto-launch --disable-metadata --listen --verbose "${COMFY_LOG_LEVEL}" --log-stdout "${COMFY_EXTRA_ARGS[@]}" &
    echo $! > "$COMFY_PID_FILE"

    echo "worker-comfyui: Starting RunPod Handler"
    python -u /handler.py --rp_serve_api --rp_api_host=0.0.0.0
else
    python -u /comfyui/main.py --disable-auto-launch --disable-metadata --verbose "${COMFY_LOG_LEVEL}" --log-stdout "${COMFY_EXTRA_ARGS[@]}" &
    echo $! > "$COMFY_PID_FILE"

    echo "worker-comfyui: Starting RunPod Handler"
    python -u /handler.py
fi
