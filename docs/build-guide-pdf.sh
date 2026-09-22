#!/usr/bin/env bash
# ==============================================================================
# build-guide-pdf.sh — render docs/index.html to docs/guide.pdf
#
# Uses headless Chromium in a container so no local PDF toolchain is required.
# Re-run this after editing index.html, then rebuild the docs container.
#
# Usage:
#   docs/build-guide-pdf.sh
# ==============================================================================

set -Eeuo pipefail

DOCS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${DOCS_DIR}/guide.pdf"
IMAGE="${GUIDE_PDF_IMAGE:-docker.io/zenika/alpine-chrome:latest}"

if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: podman or docker is required to render the PDF" >&2
  exit 1
fi

RUNNER=podman
command -v podman >/dev/null 2>&1 || RUNNER=docker

echo "Rendering ${OUT} from index.html ..."
"${RUNNER}" run --rm \
  -v "${DOCS_DIR}:/docs:Z" \
  --user 0 \
  "${IMAGE}" \
  --no-sandbox --headless --disable-gpu \
  --print-to-pdf=/docs/guide.pdf \
  "file:///docs/index.html"

if [[ ! -s "${OUT}" ]]; then
  echo "ERROR: PDF was not created" >&2
  exit 1
fi

ls -lh "${OUT}"
echo "Done. Rebuild the docs container to publish the updated PDF."
