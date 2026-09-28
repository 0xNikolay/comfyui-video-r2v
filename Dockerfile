# clean base image containing only comfyui, comfy-cli and comfyui-manager.
# NOTE: this base image already ships the Runpod handler -- including the
# runpod.serverless.start({"handler": handler}) call -- so no handler is added
# here. That is why Runpod's "Could not find runpod.serverless.start() in your
# branch" pre-deploy check fires: it greps the repo, and the handler lives one
# layer down, in this image.
FROM runpod/worker-comfyui:5.10.0-base

# ---------------------------------------------------------------------------
# Models are NOT baked into the image.
#
# A Runpod network volume is attached to the endpoint and mounted at RUNTIME
# (serverless: /runpod-volume, pods: /workspace). `docker build` never sees it,
# so weights cannot be downloaded during the build. Baking them instead is what
# stalled the previous build: the downloads below total ~66 GB, which blows the
# 30-minute docker-build timeout and pushes the image past the 80 GB limit.
#
# Instead:
#   * extra_model_paths.yaml points ComfyUI at /runpod-volume/models/...
#   * download-models.sh populates the volume on first start (idempotent), so
#     later cold starts are fast.
# ---------------------------------------------------------------------------

# Install the custom nodes the workflow needs (the MiniMaxH3 packs included).
# comfy-node-install is worker-comfyui's wrapper around `comfy node install`: it
# adds --mode=remote and fails the build, listing offenders, if any node cannot
# be installed.
# ComfyUI-Manager is omitted on purpose -- the base image already ships it and
# start.sh switches it to offline mode.
RUN comfy-node-install --fast-deps \
      image-resize-comfyui \
      https://github.com/ltdrdata/ComfyUI-Impact-Pack \
      https://github.com/ltdrdata/ComfyUI-Inspire-Pack \
      https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite \
      https://github.com/city96/ComfyUI-GGUF \
      https://github.com/chrisgoringe/cg-use-everywhere \
      https://github.com/Comfy-Org/ComfyUI-Frame-Interpolation \
      https://github.com/M1kep/ComfyLiterals \
      https://github.com/ClownsharkBatwing/RES4LYF \
      https://github.com/aria1th/ComfyUI-LogicUtils \
      https://github.com/kijai/ComfyUI-KJNodes \
      https://github.com/rgthree/rgthree-comfy \
      https://github.com/yolain/ComfyUI-Easy-Use \
      https://github.com/cubiq/ComfyUI_essentials \
      https://github.com/kijai/ComfyUI-SolAttn_triton \
      https://github.com/seesee75-commits/ComfyUI-MiniMaxH3-Director \
      https://github.com/tritant/ComfyUI_MiniMax_H3_Extender

# Static input images referenced by the workflow's LoadImage nodes (small, baked).
# Only the two images api-workflow.json actually loads are fetched.
RUN wget -q -O '/comfyui/input/image - 2026-09-20T151715.583.webp' "https://cool-anteater-319.convex.cloud/api/storage/f3e96993-faf9-4205-9c02-4a93f0aa5ad4" \
 && wget -q -O '/comfyui/input/image - 2026-09-20T154518.188.webp' "https://cool-anteater-319.convex.cloud/api/storage/40aa33b2-47d2-4dac-926a-cac028751019"

# Make ComfyUI search the network volume for every model type the workflow uses.
# (Replaces the base image's file, which only mapped the legacy unet/clip keys.)
COPY extra_model_paths.yaml /comfyui/extra_model_paths.yaml

# Populate the network volume on first start, then start the worker exactly as
# the base image would. Set HF_TOKEN on the endpoint if any weight repo is gated.
COPY download-models.sh /usr/local/bin/download-models.sh
RUN chmod +x /usr/local/bin/download-models.sh
CMD ["/usr/local/bin/download-models.sh"]
