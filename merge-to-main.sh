#!/bin/zsh
# ============================================================================
# Merge dev → main, removing dev-only files automatically
# Usage: ./merge-to-main.sh [commit message]
# ============================================================================

set -e

# Dev-only files that should never appear on main
DEV_ONLY_FILES=(
  pre-commit
  release.sh
  "release/"
  merge-to-main.sh
)

# Ensure we're on dev
current_branch=$(git branch --show-current)
if [ "$current_branch" != "dev" ]; then
  echo "ERROR: must be on dev branch (currently on $current_branch)"
  exit 1
fi

# Ensure working tree is clean
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "ERROR: working tree not clean — commit or stash first"
  exit 1
fi

MSG="${1:-Merge dev into main}"

echo "Switching to main..."
git checkout main

echo "Merging dev --no-commit..."
git merge dev --no-commit --no-ff 2>/dev/null || true

# Remove dev-only files if present
for f in "${DEV_ONLY_FILES[@]}"; do
  if [ -e "$f" ]; then
    echo "  Removing dev-only: $f"
    git rm -rf "$f" 2>/dev/null || true
  fi
done

echo "Committing..."
git commit -m "$MSG"

echo "Pushing main..."
git push origin main

echo "Switching back to dev..."
git checkout dev

echo "Done."
