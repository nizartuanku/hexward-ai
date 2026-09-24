#!/usr/bin/env bash
#
# docker/entrypoint.sh — starts the wrapped llama.cpp server with
# Hexward's grammar and (if the operator asked for it) an
# auto-downloaded model, then execs it as PID 1.
#
# Zero outbound network calls from hexward-ai ITSELF is a hard
# requirement (spec §7) — but that requirement is about the model
# serving path (no cloud fallback, ever, once serving traffic), not about
# how the operator gets model weights onto the box in the first place.
# HEXWARD_AI_HF_REPO below is an opt-in convenience for lab/dev use that
# reaches Hugging Face once, at startup, before any evidence packet is
# ever processed; production and any offline network should instead
# mount a pre-downloaded, checksum-verified .gguf file at
# HEXWARD_AI_MODEL_PATH and leave HEXWARD_AI_HF_REPO unset, which is the
# default and needs no network at all.
set -euo pipefail

MODEL_PATH="${HEXWARD_AI_MODEL_PATH:-/models/model.gguf}"
GRAMMAR_FILE="${HEXWARD_AI_GRAMMAR_FILE:-/opt/hexward-ai/grammar/response.gbnf}"
HOST="${HEXWARD_AI_HOST:-0.0.0.0}"
PORT="${HEXWARD_AI_PORT:-8435}"
CTX_SIZE="${HEXWARD_AI_CTX_SIZE:-4096}"

if [ ! -f "$GRAMMAR_FILE" ]; then
  echo "hexward-ai: FATAL — grammar file not found at $GRAMMAR_FILE (this ships inside the image; if you overrode HEXWARD_AI_GRAMMAR_FILE, mount your own file there)." >&2
  exit 1
fi

MODEL_ARGS=()
if [ -f "$MODEL_PATH" ]; then
  echo "hexward-ai: using local model at $MODEL_PATH"
  MODEL_ARGS=(-m "$MODEL_PATH")
elif [ -n "${HEXWARD_AI_HF_REPO:-}" ]; then
  echo "hexward-ai: no file at $MODEL_PATH — downloading ${HEXWARD_AI_HF_REPO} from Hugging Face instead (lab/dev convenience; verify licence and checksum, and prefer a pre-downloaded, checksum-verified file for anything that must stay offline)."
  MODEL_ARGS=(--hf-repo "$HEXWARD_AI_HF_REPO")
  if [ -n "${HEXWARD_AI_HF_FILE:-}" ]; then
    MODEL_ARGS+=(--hf-file "$HEXWARD_AI_HF_FILE")
  fi
else
  cat >&2 <<EOF
hexward-ai: FATAL — no model available.

Expected a model file at: $MODEL_PATH
(mount it with, e.g., -v /path/on/host/model.gguf:$MODEL_PATH:ro)

hexward-ai never bundles model weights in the image (spec §3) — download
one of the tiers listed in README.md / docs/INSTALL.md, verify it against
the SHA256SUMS the model publisher provides, and mount it at the path
above. For a quick lab/dev smoke test only, you may instead set
HEXWARD_AI_HF_REPO (and optionally HEXWARD_AI_HF_FILE) to let llama.cpp
download it from Hugging Face at startup — see docker-compose.ai.yml for
the GitHub-lab example using SmolLM3-3B.
EOF
  exit 1
fi

echo "hexward-ai: starting on ${HOST}:${PORT}, grammar ${GRAMMAR_FILE}, ctx-size ${CTX_SIZE}"
exec /app/llama-server \
  --host "$HOST" \
  --port "$PORT" \
  --ctx-size "$CTX_SIZE" \
  --grammar-file "$GRAMMAR_FILE" \
  "${MODEL_ARGS[@]}" \
  "$@"
