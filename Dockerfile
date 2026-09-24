# Build argument for base image selection.
# CUDA 13.0 (not 13.3): toolkit 13.3 needs driver >= 610; 13.0 works on
# driver >= 580, which covers older RunPod hosts that still advertise R580.
ARG BASE_IMAGE=nvidia/cuda:13.0.3-cudnn-runtime-ubuntu24.04

# Stage 1: Base image with common dependencies (no baked models)
FROM ${BASE_IMAGE} AS base

# Build arguments for this stage with sensible defaults for standalone builds
ARG COMFYUI_VERSION=0.36.0
ARG CUDA_VERSION_FOR_COMFY=13.0
ARG ENABLE_PYTORCH_UPGRADE=false
ARG PYTORCH_INDEX_URL

# Prevents prompts from packages asking for user input during installation
ENV DEBIAN_FRONTEND=noninteractive
# Prefer binary wheels over source distributions for faster pip installations
ENV PIP_PREFER_BINARY=1
# Ensures output from python is printed immediately to the terminal without buffering
ENV PYTHONUNBUFFERED=1
# Speed up some cmake builds
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Install Python, git and other necessary tools
RUN apt-get update && apt-get install -y \
    python3.12 \
    python3.12-venv \
    git \
    wget \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    openssh-server \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip

# Clean up to reduce image size
RUN apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Install uv (latest) using official installer and create isolated venv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

# Use the virtual environment for all subsequent commands
ENV PATH="/opt/venv/bin:${PATH}"

# Install comfy-cli + dependencies needed by it to install ComfyUI
# comfy-cli is pinned: its install/torch-index behavior decides what lands in
# the workspace venv, so an unpinned version makes builds non-reproducible.
# 1.20.0+ is required for --cuda-version 13.0.
RUN uv pip install comfy-cli==1.20.0 pip setuptools wheel

# Install ComfyUI
RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
    fi

# Upgrade PyTorch if needed (for newer CUDA versions)
RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      uv pip install --force-reinstall torch torchvision torchaudio --index-url ${PYTORCH_INDEX_URL}; \
    fi

# comfy-cli installs ComfyUI into its own workspace venv (/comfyui/.venv), but
# start.sh launches ComfyUI with /opt/venv's python. That mismatch leaves the
# launch venv missing ComfyUI's runtime deps (e.g. sqlalchemy, pulled in by
# ComfyUI's asset DB), so ComfyUI crashes at startup and surfaces as the
# misleading "ComfyUI server (127.0.0.1:8188) not reachable" error. Mirror
# ComfyUI's full dependency set (core + custom nodes) into /opt/venv so the
# launch venv is complete. Root-cause fix for DR-1170.
#
# The transformers/huggingface-hub pin is part of the SAME step on purpose:
# ComfyUI declares transformers>=4.50.3 and huggingface-hub with NO upper bound,
# so a fresh install can pull transformers 5.x / huggingface-hub 1.x whose
# breaking API changes also crash ComfyUI at startup. Pinning them in the same
# RUN downgrades within one layer, so the unwanted versions aren't left behind
# bloating the image.
#
# torch is installed FIRST, pinned to +cu130 builds: ComfyUI's requirements.txt
# declares a bare `torch`; installing from the cu130 index first satisfies that
# requirement so the later PyPI pass does not replace it with a mismatched
# wheel. cu130 + CUDA 13.0 base need host driver >= 580 (covers R580 and newer
# hosts like RTX PRO 6000 / 5090 on R595).
RUN uv pip install torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 \
      --index-url https://download.pytorch.org/whl/cu130 \
    && uv pip install -r /comfyui/requirements.txt \
    && for r in /comfyui/custom_nodes/*/requirements.txt; do \
         [ -f "$r" ] && uv pip install -r "$r" || true; \
       done \
    && uv pip install "transformers>=4.50.3,<5" "huggingface-hub<1.0"

# SageAttention for PathchSageAttentionKJ (comfyui-kjnodes). The CUDA runtime
# base has no nvcc, so install a prebuilt cu13 / cp312 Linux wheel instead of
# building from source. Keep DynamicVRAM disabled (start.sh) — SA + DynamicVRAM
# has known MiniMax H3 hangs.
RUN uv pip install \
      "https://github.com/snw35/sageattention-wheel/releases/download/cu12-2.2.0-cu13-2.2.0/sageattention-2.2.0%2Bcu13-cp312-cp312-linux_x86_64.whl"

# Change working directory to ComfyUI
WORKDIR /comfyui

# Support for the network volume (models + optional custom_nodes via start.sh)
ADD src/extra_model_paths.yaml ./

# Go back to the root
WORKDIR /

# Install Python runtime dependencies for the handler.
# torchcodec is required by torchaudio's load_with_torchcodec path
# (e.g. LoadAudioFromURL / audio nodes); ffmpeg is already apt-installed above.
# Pin to the ABI-stable line compatible with torch 2.11+.
RUN uv pip install runpod requests websocket-client "torchcodec>=0.12"

# Wire protocol for the ComfyUI-RunOnRunpod plugin. Classic API clients ignore
# these; the plugin requires PROTOCOL_VERSION to match its routes.py value.
ARG WORKER_VERSION=0.1.0
ENV WORKER_VERSION=${WORKER_VERSION}
ARG PROTOCOL_VERSION=1
ENV PROTOCOL_VERSION=${PROTOCOL_VERSION}
# How long the volume-path handler waits for ComfyUI to finish a prompt.
# Must be ≤ the RunPod endpoint execution timeout (and leave headroom).
ENV WORKFLOW_POLL_TIMEOUT=1800
# Expose the ComfyUI version ARG (declared above) to the running handler.
ENV COMFYUI_VERSION=${COMFYUI_VERSION}

# Add application code and scripts
ADD src/start.sh src/network_volume.py handler.py model_fetcher.py test_input.json ./
RUN chmod +x /start.sh

# Add script to install custom nodes
COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install

# Prevent pip from asking for confirmation during uninstall steps in custom nodes
ENV PIP_NO_INPUT=1

# Copy helper script to switch Manager network mode at container start
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

# Set the default command to run when starting the container
CMD ["/start.sh"]

# Alias kept so existing docker-bake / CI targets that used `target = "final"`
# still resolve. No models are downloaded or copied into the image — load them
# from the RunPod network volume instead.
FROM base AS final
