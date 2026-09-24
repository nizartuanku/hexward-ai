# hexward-ai — Dockerfile
#
# Build: docker build -t hexward/hexward-ai:0.2.0 -f docker/Dockerfile .
# Run:   docker compose -f docker-compose.ai.yml up
#
# Wraps the upstream llama.cpp OpenAI-compatible server (built and
# published by the llama.cpp project itself, not forked or patched here)
# with Hexward's prompt templates and the GBNF grammar that forces valid
# JSON output, per spec §3. The model is deliberately NOT baked into this
# image — see docs/CONCEPTS.md "Why the model is not in the image" and
# spec §3: weights are downloaded separately and verified against a
# published SHA256SUMS, the same discipline every Hexward product release
# already uses for its own binaries.
#
# Pinned by tag AND digest for reproducibility. Bump both together when
# upgrading llama.cpp; `docker buildx imagetools inspect
# ghcr.io/ggml-org/llama.cpp:server` prints the current digest.
FROM ghcr.io/ggml-org/llama.cpp:server@sha256:a94b642b3e2620749bf2ff5672df922c23a6202710e54a8f7667e58df70aba5a

LABEL org.opencontainers.image.title="hexward-ai" \
      org.opencontainers.image.description="Hexward AI Assist sidecar: llama.cpp + Hexward prompt templates + JSON grammar, OpenAI-compatible /v1/chat/completions" \
      org.opencontainers.image.source="https://github.com/nizartuanku/hexward-ai" \
      org.opencontainers.image.licenses="Apache-2.0"

COPY docker/grammar/ /opt/hexward-ai/grammar/
COPY docker/prompts/ /opt/hexward-ai/prompts/
COPY docker/entrypoint.sh /opt/hexward-ai/entrypoint.sh

# The base image runs as root by default (needed to bind low ports in
# some deployments); hexward-ai never needs a low port, so it drops to a
# fixed unprivileged UID here rather than inheriting root.
RUN chmod +x /opt/hexward-ai/entrypoint.sh && \
    mkdir -p /models && \
    (getent group hexward-ai || addgroup --gid 10435 hexward-ai) && \
    (id -u hexward-ai >/dev/null 2>&1 || adduser --uid 10435 --gid 10435 --disabled-password --gecos "" hexward-ai) && \
    chown -R hexward-ai:hexward-ai /models /opt/hexward-ai

USER hexward-ai
# The base image's llama-server binary resolves its own shared
# libraries via a CWD-relative rpath, NOT $ORIGIN (verified directly:
# ldd reports "not found" for libllama-server-impl.so from any other
# working directory, even though the file exists and is world-readable
# at /app). So WORKDIR must stay /app, not a hexward-ai-specific path,
# or the container exits immediately with "error while loading shared
# libraries" — this is not cosmetic.
WORKDIR /app

# 8435 — the registered Hexward port for AI Assist (spec [K-3]), the slot
# after TopoLight's 8433/8434. Never 8422-8434 (already taken by other
# products) and never a port in the 80xx/443x ranges common products bind.
EXPOSE 8435

ENV HEXWARD_AI_HOST=0.0.0.0 \
    HEXWARD_AI_PORT=8435 \
    HEXWARD_AI_MODEL_PATH=/models/model.gguf \
    HEXWARD_AI_GRAMMAR_FILE=/opt/hexward-ai/grammar/response.gbnf \
    HEXWARD_AI_CTX_SIZE=4096

ENTRYPOINT ["/opt/hexward-ai/entrypoint.sh"]
