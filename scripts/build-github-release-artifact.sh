#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-${GITHUB_REF_NAME:-}}"
OUTPUT_DIR="${2:-$ROOT_DIR/dist}"
REF="${3:-$VERSION}"

if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "usage: $0 <vX.Y.Z> [output-dir] [git-ref]" >&2
  exit 2
fi

if ! git -C "$ROOT_DIR" cat-file -e "$REF:skills/novel-assistant/SKILL.md" 2>/dev/null; then
  echo "release ref does not contain skills/novel-assistant: $REF" >&2
  exit 3
fi

mkdir -p "$OUTPUT_DIR"
ARTIFACT="$OUTPUT_DIR/novel-assistant-${VERSION}.tar.gz"
CHECKSUM="$ARTIFACT.sha256"

# git archive fixes file order and timestamps to the selected commit. gzip -n
# removes host/time metadata, so rebuilding the same ref yields the same bytes.
git -C "$ROOT_DIR" archive \
  --format=tar \
  --prefix=novel-assistant/ \
  "$REF:skills/novel-assistant" \
  | gzip -n > "$ARTIFACT"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$OUTPUT_DIR" && sha256sum "$(basename "$ARTIFACT")") > "$CHECKSUM"
else
  (cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$ARTIFACT")") > "$CHECKSUM"
fi

printf 'artifact=%s\nchecksum=%s\n' "$ARTIFACT" "$CHECKSUM"
