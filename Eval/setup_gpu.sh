#!/usr/bin/env bash
# Install vLLM on a Linux GPU instance and start the inference server.
# Tested on Ubuntu 22.04 with CUDA 12.x (A10G, A100, H100).
# For TPU v5e: see https://docs.vllm.ai/en/latest/getting_started/tpu-installation.html
set -euo pipefail

MODEL="${1:-meta-llama/Llama-3.2-3B-Instruct}"
PORT="${2:-8000}"

echo "=== Recap Eval: GPU / vLLM setup ==="
echo "Model : $MODEL"
echo "Port  : $PORT"
echo ""

pip install vllm
pip install -r "$(dirname "$0")/requirements.txt"

echo ""
echo "Starting vLLM server with prefix caching enabled..."
echo "(Ctrl-C to stop)"
echo ""

python -m vllm.entrypoints.openai.api_server \
    --model "$MODEL" \
    --port "$PORT" \
    --enable-prefix-caching \
    --max-model-len 4096

# To replay from your Mac once the server is running:
#
#   python Eval/replay.py \
#       --input    Runs/<session>.jsonl \
#       --output   Runs/baseline_vllm.jsonl \
#       --base-url http://<gpu-ip>:8000/v1 \
#       --api-key  EMPTY \
#       --backend  vllm \
#       --model    meta-llama/Llama-3.2-3B-Instruct
