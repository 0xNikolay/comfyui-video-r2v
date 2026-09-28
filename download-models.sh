#!/usr/bin/env bash
# Populate the Runpod network volume with the MiniMax-H3 weights the workflow
# needs, then hand off to the worker-comfyui entrypoint.
#
# Why this exists: a network volume is mounted at RUNTIME (serverless:
# /runpod-volume, pods: /workspace), so `docker build` cannot see it. Downloading
# the ~45 GB of weights into the image instead is what stalled the previous build
# (over the 30-minute docker-build timeout, and past the 80 GB image limit).
#
# Idempotent: a model already present on the volume is skipped. Run it once on a
# Pod to prepopulate (MODELS_ONLY=1), or just let the first worker run it -- later
# cold starts are then instant.
set -euo pipefail

# Where do models live? The mounted network volume if present, else ComfyUI's own
# models dir so the image still works with no volume attached.
if [ -n "${RUNPOD_VOLUME_PATH:-}" ] && [ -d "$RUNPOD_VOLUME_PATH" ]; then
  VOL="$RUNPOD_VOLUME_PATH"
elif [ -d /runpod-volume ]; then
  VOL=/runpod-volume
elif [ -d /workspace ]; then
  VOL=/workspace
else
  VOL=/comfyui
fi
MODELS="$VOL/models"
echo "download-models: using volume root $VOL"

# Serialize concurrent first-boot downloads across workers sharing the volume.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$VOL/.download-models.lock"
  flock 9
fi

# Optional token for gated HuggingFace repos (set HF_TOKEN on the endpoint).
HF_AUTH=()
if [ -n "${HF_TOKEN:-}" ]; then
  HF_AUTH=(--header="Authorization: Bearer ${HF_TOKEN}")
fi

download() {
  local rel_path="$1" url="$2" filename="$3"
  local dest="$MODELS/$rel_path/$filename"
  if [ -f "$dest" ]; then
    echo "download-models: present, skipping -> $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  echo "download-models: downloading $filename -> $dest"
  if wget --tries=5 --timeout=60 --waitretry=10 --progress=dot:giga \
        "${HF_AUTH[@]}" -O "$dest.part" "$url"; then
    mv -f "$dest.part" "$dest"
  else
    rm -f "$dest.part"
    echo "download-models: FAILED $url" >&2
    return 1
  fi
}

# --- Required by api-workflow.json (~45 GB total) ---------------------------
download vae              "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_video_vae_fp16.safetensors" "minimax_h3_video_vae_fp16.safetensors"
download vae              "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_audio_vae_fp32.safetensors" "minimax_h3_audio_vae_fp32.safetensors"
download text_encoders    "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
download diffusion_models "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/diffusion_models/minimax_h3_ref2va_pruned_fp8_scaled.safetensors" "minimax_h3_ref2va_pruned_fp8_scaled.safetensors"
download loras            "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors" "minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors"
download loras            "https://huggingface.co/Plaguekind/H3-Loras/resolve/main/PlagueKind-tiddies-realismslider.safetensors" "MiniMaxH3/PlagueKind-tiddies-realismslider.safetensors"
download loras            "https://huggingface.co/cdkkkk/setup/resolve/main/h3/breastplayjiggle_h3_v2.safetensors" "MiniMaxH3/breastplayjiggle_h3_v2.safetensors"

# --- Optional (~21 GB): not referenced by api-workflow.json ---------------
# Uncomment if you switch UNETLoader to the int8 checkpoint.
# download diffusion_models "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" "minimax_h3_ref2va_pruned_int8_convrot.safetensors"

echo "download-models: all required models present"

if [ "${MODELS_ONLY:-0}" = "1" ]; then
  echo "download-models: MODELS_ONLY=1 set -- not starting the worker"
  exit 0
fi

exec /start.sh
