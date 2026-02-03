#!/bin/bash
set -euo pipefail

# Release helper for watch-preferences
# - Copies "watch-preferences/watch-preferences.sh" to
#   "watch-preferences/versions/watch-preferences-vX.Y[.Z].sh"
# - Updates symlink "watch-preferences/versions/latest" -> "watch-preferences-vX.Y[.Z].sh"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BASE_DIR="$SCRIPT_DIR"

SCRIPT_NAME="watch-preferences.sh"
SCRIPT_BASENAME="watch-preferences"

SRC="$BASE_DIR/$SCRIPT_NAME"
VERS_DIR="$BASE_DIR/versions"

if [ ! -f "$SRC" ]; then
  echo "Source not found: $SRC" >&2
  exit 1
fi

mkdir -p "$VERS_DIR"

# Version from first arg (header not used for this script)
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "Usage: watch-preferences/release.sh <version>" >&2
  exit 1
fi

DEST="$VERS_DIR/${SCRIPT_BASENAME}-v${VERSION}.sh"
if [ -e "$DEST" ]; then
  if cmp -s "$SRC" "$DEST"; then
    echo "Already released (unchanged): $DEST"
    ln -sfn "${SCRIPT_BASENAME}-v${VERSION}.sh" "$VERS_DIR/latest"
    echo "Symlink updated: $VERS_DIR/latest -> ${SCRIPT_BASENAME}-v${VERSION}.sh"
    exit 0
  else
    echo "Destination exists with different content: $DEST" >&2
    echo "Bump version and retry: 'watch-preferences/release.sh X.Y[.Z]'" >&2
    exit 1
  fi
fi

cp "$SRC" "$DEST"
chmod +x "$DEST"

ln -sfn "${SCRIPT_BASENAME}-v${VERSION}.sh" "$VERS_DIR/latest"

echo "Released: $DEST"
echo "Symlink updated: $VERS_DIR/latest -> ${SCRIPT_BASENAME}-v${VERSION}.sh"
echo "Tip: git add/commit and optionally tag watch-preferences-v${VERSION}."
