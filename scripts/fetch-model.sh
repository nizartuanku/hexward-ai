#!/usr/bin/env bash
#
# scripts/fetch-model.sh — download one hexward-ai tier model, pinned to an
# exact Hugging Face commit, and refuse to keep it unless its size and
# SHA-256 match the values in profiles/<tier>.env.
#
# Usage:  scripts/fetch-model.sh <lab|smb|enterprise-4b|enterprise-8b> [dest-dir]
#         (dest-dir defaults to ./models)
#
# This is the only network step in the whole AI Assist path, and it runs
# once, on your command, before anything is served. After it succeeds the
# sidecar needs no internet at all.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIER="${1:-}"
DEST="${2:-./models}"
PROFILE="$HERE/profiles/${TIER}.env"

if [ -z "$TIER" ] || [ ! -f "$PROFILE" ]; then
  echo "usage: $0 <tier> [dest-dir]" >&2
  echo "tiers: $(cd "$HERE/profiles" && ls *.env | sed 's/\.env$//' | tr '\n' ' ')" >&2
  exit 2
fi
# shellcheck disable=SC1090
set -a; . "$PROFILE"; set +a

for tool in curl sha256sum; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done

mkdir -p "$DEST"
OUT="$DEST/$HEXWARD_AI_MODEL_FILE"
URL="https://huggingface.co/${HEXWARD_AI_HF_REPO_PIN}/resolve/${HEXWARD_AI_HF_REVISION}/${HEXWARD_AI_MODEL_FILE}"

verify() {
  local f="$1" size
  size=$(stat -L -c %s "$f" 2>/dev/null || stat -L -f %z "$f")
  if [ "$size" != "$HEXWARD_AI_MODEL_BYTES" ]; then
    echo "size mismatch for $f: got $size, want $HEXWARD_AI_MODEL_BYTES" >&2
    return 1
  fi
  echo "${HEXWARD_AI_MODEL_SHA256}  $f" | sha256sum -c --quiet -
}

if [ -f "$OUT" ] && verify "$OUT" 2>/dev/null; then
  echo "already present and verified: $OUT"
else
  echo "downloading $HEXWARD_AI_MODEL_FILE (${HEXWARD_AI_MODEL_BYTES} bytes, licence ${HEXWARD_AI_MODEL_LICENSE})"
  echo "from $URL"
  curl -fL --retry 3 --retry-delay 5 -C - -o "$OUT.part" "$URL"
  if ! verify "$OUT.part"; then
    echo "VERIFICATION FAILED — deleting $OUT.part; nothing was installed." >&2
    rm -f "$OUT.part"
    exit 1
  fi
  mv "$OUT.part" "$OUT"
  echo "verified sha256 ${HEXWARD_AI_MODEL_SHA256}"
fi

cat <<MSG

Ready. Start the sidecar for this tier with:

  HEXWARD_AI_MODELS_DIR=$(cd "$DEST" && pwd) docker compose --env-file profiles/${TIER}.env -f docker-compose.tier.yml up -d

MSG
