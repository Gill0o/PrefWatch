#!/bin/zsh
# ============================================================================
# Merge dev → main, removing dev-only files automatically
# Produces a clean main history: v1.0.0 base + one squash commit per release
# Usage: ./merge-to-main.sh <version> [commit message]
# Example: ./merge-to-main.sh v1.0.2 "Merge dev — v1.0.2"
# ============================================================================

# Base tag — main is always reset to this before squash-merging
BASE_TAG="v1.0.0"

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
  echo "ERROR: version tag required (e.g. ./merge-to-main.sh v1.0.2)"
  exit 1
fi
MSG="${2:-Merge dev — $TAG}"

# Check if tag already exists
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "ERROR: tag $TAG already exists — delete it first or use a different version"
  exit 1
fi

# Verify base tag exists
if ! git rev-parse "$BASE_TAG" >/dev/null 2>&1; then
  echo "ERROR: base tag $BASE_TAG not found"
  exit 1
fi

echo "Switching to main..."
git checkout main || exit 1

echo "Resetting main to $BASE_TAG (clean base)..."
git reset --hard "$BASE_TAG"

echo "Squash-merging dev..."
git merge dev --squash 2>/dev/null || true

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

echo "Force-pushing main (rewritten history)..."
git push --force-with-lease origin main || { echo "ERROR: push failed — is branch protection disabled?"; exit 1; }

# Delete old remote tags for versions > BASE_TAG (they point to polluted history)
for old_tag in $(git tag -l 'v*' | grep -v "^${BASE_TAG}$" | grep -v "^${TAG}$"); do
  echo "  Cleaning old tag: $old_tag"
  git push origin ":refs/tags/$old_tag" 2>/dev/null || true
  git tag -d "$old_tag" 2>/dev/null || true
done

echo "Creating tag $TAG..."
git tag -a "$TAG" -m "PrefWatch $TAG"
git push origin "$TAG" || { echo "ERROR: tag push failed"; exit 1; }

echo ""
echo "Done — main reset to $BASE_TAG + squash $TAG, pushed and tagged."
