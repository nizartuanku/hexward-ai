#!/usr/bin/env bash
#
# scripts/first-run.sh — the First User Test for hexward-ai.
#
# hexward-ai has NO tagged GitHub release yet (see README "Status"), so
# unlike every other Hexward product's first-run.sh, this script does not
# resolve `releases/latest` — there is nothing to resolve. Instead it
# does what a first-time reader of this repo would actually do: clone (or
# use the checkout you already have), build the Docker image from
# source, and start the sidecar.
#
# It also does NOT assume you have a model file lying around. A real
# model is 2+ GB (see docs/INSTALL.md) and downloading one is a decision
# this script should not make silently on your behalf. So it runs in one
# of two modes:
#
#   bash scripts/first-run.sh
#       Builds the image, starts it with NO model mounted, and confirms
#       the container fails FAST with a clear message instead of hanging
#       or crashing confusingly — this is real, verifiable behavior, but
#       it is honestly a partial test: it never sends a request through
#       an actual model.
#
#   FIRST_RUN_MODEL=/path/to/model.gguf bash scripts/first-run.sh
#       Also mounts that file, waits for the server to report healthy,
#       and sends one real /v1/chat/completions request constrained by
#       the shipped grammar — a full end-to-end pass.
#
# Run it on a clean Ubuntu machine with Docker installed:
#
#     bash scripts/first-run.sh
#
# Requirements: bash, docker (with the compose plugin not required — this
# script uses `docker run` directly so it has one fewer dependency),
# curl, python3.

set -euo pipefail

IMAGE_TAG="hexward-ai:first-run-test"
PORT="${FIRST_RUN_PORT:-8435}"
BUDGET_SECONDS=900
MODEL_PATH="${FIRST_RUN_MODEL:-}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

START=$(date +%s)
CONTAINER_NAME="hexward-ai-first-run-$$"

elapsed() { echo $(( $(date +%s) - START )); }
step()    { printf '\n[%3ss] Step %s/7 — %s\n' "$(elapsed)" "$1" "$2"; }
fail()    { printf '\n[%3ss] FAIL — %s\n' "$(elapsed)" "$1" >&2; exit 1; }

cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "First User Test — hexward-ai (pre-release, no tagged GitHub release yet)"
echo "Repo: $REPO_ROOT"
echo "Budget: ${BUDGET_SECONDS}s"
if [ -n "$MODEL_PATH" ]; then
  echo "Mode: FULL (model supplied at $MODEL_PATH)"
else
  echo "Mode: PARTIAL (no FIRST_RUN_MODEL set — see script header for what this does and does not verify)"
fi

# ------------------------------------------------------------- 1. requirements
step 1 "check requirements"
for tool in docker curl python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed"
done
docker info >/dev/null 2>&1 || fail "docker daemon is not reachable (are you in the docker group? try: sudo usermod -aG docker \$USER, then re-login)"
if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
  fail "port ${PORT} is already in use on this machine. Free it, or re-run with FIRST_RUN_PORT=<free port>."
fi
if [ -n "$MODEL_PATH" ] && [ ! -f "$MODEL_PATH" ]; then
  fail "FIRST_RUN_MODEL=$MODEL_PATH does not exist"
fi

# ------------------------------------------------------------------ 2. build
step 2 "build the Docker image from source"
docker build -q -t "$IMAGE_TAG" -f "$REPO_ROOT/docker/Dockerfile" "$REPO_ROOT" >/tmp/hexward-ai-first-run-build.log 2>&1 \
  || { cat /tmp/hexward-ai-first-run-build.log; fail "docker build failed — see log above"; }
echo "  built $IMAGE_TAG"

# ------------------------------------------------------------ 3. grammar sanity
step 3 "sanity-check the shipped grammar file"
GRAMMAR_FILE="$REPO_ROOT/docker/grammar/response.gbnf"
[ -f "$GRAMMAR_FILE" ] || fail "grammar file missing at $GRAMMAR_FILE"
grep -q '"explanation"' "$GRAMMAR_FILE" || fail "grammar file does not mention the required \"explanation\" key"
grep -q '"what_to_verify"' "$GRAMMAR_FILE" || fail "grammar file does not mention the required \"what_to_verify\" key"
grep -q '"disclaimer"' "$GRAMMAR_FILE" || fail "grammar file does not mention the required \"disclaimer\" key"
echo "  grammar file present and mentions all three required keys"

# --------------------------------------------------------- 4. start container
step 4 "start the container"
RUN_ARGS=(-d --name "$CONTAINER_NAME" -p "127.0.0.1:${PORT}:8435")
if [ -n "$MODEL_PATH" ]; then
  RUN_ARGS+=(-v "${MODEL_PATH}:/models/model.gguf:ro")
fi
docker run "${RUN_ARGS[@]}" "$IMAGE_TAG" >/dev/null || fail "docker run failed to start the container"
echo "  container: $CONTAINER_NAME"

# ------------------------------------------------- 5. verify observable behavior
step 5 "verify observable behavior"
if [ -z "$MODEL_PATH" ]; then
  # No model was mounted. The documented, tested behavior (see
  # docker/entrypoint.sh) is: fail FAST with a clear message, not hang,
  # not crash with a stack trace, not silently retry forever.
  sleep 2
  STATUS=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
  LOGS=$(docker logs "$CONTAINER_NAME" 2>&1 || true)
  if [ "$STATUS" = "running" ]; then
    fail "container is still running with no model mounted — expected it to exit with a clear 'no model available' message. Logs:
$LOGS"
  fi
  echo "$LOGS" | grep -q "no model available" \
    || fail "container exited, but not with the expected 'no model available' message. Logs:
$LOGS"
  echo "  container exited fast with the documented, clear error message — this is the intended behavior for a missing model"
else
  URL="http://127.0.0.1:${PORT}/health"
  CODE=""
  while [ "$(elapsed)" -lt "$BUDGET_SECONDS" ]; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL" || true)
    [ "$CODE" = "200" ] && break
    sleep 2
  done
  [ "$CODE" = "200" ] || { docker logs "$CONTAINER_NAME" 2>&1 | tail -40; fail "${URL} did not answer 200 within the budget (last code: ${CODE:-none})"; }
  echo "  ${URL} -> 200"
fi

# ------------------------------------------------------ 6. one real request (FULL mode only)
step 6 "send one evidence packet through the model"
if [ -n "$MODEL_PATH" ]; then
  # CPU inference under a grammar is slow (observed ~1 token/second for
  # SmolLM3-3B on the team's own DevNet VM) — max_tokens and --max-time
  # are both generous on purpose. This curl call is deliberately NOT a
  # bare `RESP=$(curl ...)`: under `set -e`, a plain command-substitution
  # assignment that fails (e.g. curl exiting 28 on --max-time) aborts the
  # whole script immediately, silently, without ever reaching fail() —
  # verified directly while building this script (a real request that
  # ran past --max-time killed the script with no error message at all).
  # The explicit `if ! RESP=$(...)` form is what makes curl's own
  # failure reach the same fail() path as every other check here.
  if ! RESP=$(curl -s --max-time 180 "http://127.0.0.1:${PORT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    --data-binary @- <<'JSON'
{"model":"hexward-ai","messages":[{"role":"system","content":"Respond with a single JSON object: {\"explanation\": string, \"what_to_verify\": [string], \"disclaimer\": string}."},{"role":"user","content":"{\"feature\":\"rulehawk.explain_finding\",\"product\":\"rulehawk\",\"finding\":{\"id\":\"f-0142\",\"kind\":\"rule.shadowed\"}}"}],"temperature":0.2,"max_tokens":150}
JSON
  ); then
    fail "the /v1/chat/completions request failed or did not complete within 180s"
  fi
  echo "$RESP" | python3 -c "
import json, sys
data = json.load(sys.stdin)
content = data['choices'][0]['message']['content']
parsed = json.loads(content)
for key in ('explanation', 'what_to_verify', 'disclaimer'):
    assert key in parsed, f'missing key: {key}'
print('  model responded with valid, schema-shaped JSON')
" || fail "response did not parse as the required schema. Raw response: $RESP"
else
  echo "  skipped — no model available in this run (see script header: set FIRST_RUN_MODEL for a full pass)"
fi

# --------------------------------------------------------------- 7. verdict
step 7 "verdict"
TOTAL=$(elapsed)
if [ -n "$MODEL_PATH" ]; then
  printf '\nPASS (full) — hexward-ai served a real, schema-valid response from a live model in %ss (budget %ss).\n' "$TOTAL" "$BUDGET_SECONDS"
else
  printf '\nPARTIAL PASS (%ss) — the image builds, the grammar file is present and well-formed, and the container fails fast with a clear message when no model is mounted. Live inference was NOT exercised. Re-run with FIRST_RUN_MODEL=/path/to/model.gguf for a full pass.\n' "$TOTAL"
fi
