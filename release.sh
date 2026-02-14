#!/bin/bash
set -euo pipefail

# Release helper for PrefWatch
# - Copies prefwatch.sh to release/prefwatch-vX.Y.Z.sh
# - Updates symlink release/latest -> prefwatch-vX.Y.Z.sh

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)

SCRIPT_NAME="prefwatch.sh"
SCRIPT_BASENAME="prefwatch"

SRC="$ROOT_DIR/$SCRIPT_NAME"
RELEASE_DIR="$ROOT_DIR/release"

if [ ! -f "$SRC" ]; then
  echo "Source not found: $SRC" >&2
  exit 1
fi

mkdir -p "$RELEASE_DIR"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "Usage: ./release.sh <version>" >&2
  exit 1
fi

DEST="$RELEASE_DIR/${SCRIPT_BASENAME}-v${VERSION}.sh"
if [ -e "$DEST" ]; then
  if cmp -s "$SRC" "$DEST"; then
    echo "Already released (unchanged): $DEST"
    ln -sfn "${SCRIPT_BASENAME}-v${VERSION}.sh" "$RELEASE_DIR/latest"
    exit 0
  else
    echo "Destination exists with different content: $DEST" >&2
    echo "Bump version and retry: './release.sh X.Y.Z'" >&2
    exit 1
  fi
fi

cp "$SRC" "$DEST"
chmod +x "$DEST"

ln -sfn "${SCRIPT_BASENAME}-v${VERSION}.sh" "$RELEASE_DIR/latest"

echo "Released: $DEST"
echo "Symlink: release/latest -> ${SCRIPT_BASENAME}-v${VERSION}.sh"
