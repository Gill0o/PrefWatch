#!/bin/zsh
# ============================================================================
# Merge dev → main, removing dev-only files automatically
# Usage: ./merge-to-main.sh <version> [commit message]
# Example: ./merge-to-main.sh v1.0.1 "Merge dev — v1.0.1"
# ============================================================================

# Dev-only files that should never appear on main
DEV_ONLY_FILES=(
  pre-commit
  release.sh
  "release/"
  merge-to-main.sh
)

# Always return to dev on exit (success or failure)
trap 'git checkout dev 2>/dev/null' EXIT

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

# Parse arguments
TAG="$1"
if [ -z "$TAG" ]; then
  echo "ERROR: version tag required (e.g. ./merge-to-main.sh v1.0.1)"
  exit 1
fi
MSG="${2:-Merge dev — $TAG}"

# Check if tag already exists
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "ERROR: tag $TAG already exists — delete it first or use a different version"
  exit 1
fi

echo "Switching to main..."
git checkout main || exit 1

echo "Syncing with remote main..."
git fetch origin main
git reset --hard origin/main

echo "Merging dev --no-commit..."
git merge dev --no-commit --no-ff 2>/dev/null || true

# Resolve any conflicts by taking dev version
conflicted=($(git diff --name-only --diff-filter=U 2>/dev/null))
if [ ${#conflicted[@]} -gt 0 ]; then
  echo "  Resolving ${#conflicted[@]} conflict(s) with dev version..."
  for f in "${conflicted[@]}"; do
    git checkout --theirs "$f" 2>/dev/null && git add "$f"
  done
fi

# Remove dev-only files if present
for f in "${DEV_ONLY_FILES[@]}"; do
  if [ -e "$f" ]; then
    echo "  Removing dev-only: $f"
    git rm -rf "$f" 2>/dev/null || true
  fi
done

echo "Committing..."
git commit -m "$MSG" || { echo "ERROR: commit failed"; exit 1; }

echo "Pushing main..."
git push origin main || { echo "ERROR: push failed — is branch protection disabled?"; exit 1; }

echo "Creating tag $TAG..."
git tag -a "$TAG" -m "PrefWatch $TAG"
git push origin "$TAG" || { echo "ERROR: tag push failed"; exit 1; }

echo ""
echo "Done — merged, pushed, and tagged $TAG."
