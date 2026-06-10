#!/usr/bin/env bash
# Install Ollama and pull the baseline model for Mac evaluation.
# Runs on any Mac (Apple Silicon or Intel); uses Metal for acceleration.
set -euo pipefail

echo "=== Recap Eval: Mac / Ollama setup ==="

if ! command -v ollama &>/dev/null; then
    echo "Installing Ollama via Homebrew..."
    brew install ollama
fi

echo "Pulling llama3.2:3b (~2 GB, cached after first pull)..."
ollama pull llama3.2:3b

pip install -r "$(dirname "$0")/requirements.txt"

echo ""
echo "Done. Start the server in a separate terminal:"
echo "  ollama serve"
echo ""
echo "Then replay a session:"
echo "  python Eval/replay.py \\"
echo "      --input  Runs/<session>.jsonl \\"
echo "      --output Runs/baseline_ollama.jsonl"
