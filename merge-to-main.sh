#!/bin/zsh
# ============================================================================
# Merge dev → main, removing dev-only files automatically
# Produces a clean main history: one squash commit per release
# First run cleans polluted history (resets to BASE_TAG), subsequent runs
# build incrementally from the last release tag.
# Usage: ./merge-to-main.sh <version> [commit message]
# Example: ./merge-to-main.sh v1.0.2 "Merge dev — v1.0.2"
# ============================================================================

# Base tag — used for initial cleanup if main history is polluted
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
git fetch origin main 2>/dev/null || true

# Determine if main history is clean (parent of HEAD is a tagged release)
# Clean: v1.0.0 → squash_v1.0.1 → squash_v1.0.2 (each parent is tagged)
# Polluted: individual dev commits mixed in
NEED_FORCE=false
MAIN_PARENT=$(git rev-parse HEAD~1 2>/dev/null)
BASE_COMMIT=$(git rev-parse "$BASE_TAG" 2>/dev/null)

if [ "$MAIN_PARENT" = "$BASE_COMMIT" ] || git describe --exact-match "$MAIN_PARENT" 2>/dev/null | grep -q '^v'; then
  echo "Clean main history — building incrementally from HEAD..."
  # Main is clean, just sync with remote and build on top
  git reset --hard origin/main 2>/dev/null || true
else
  echo "Polluted main history — resetting to $BASE_TAG (one-time cleanup)..."
  git reset --hard "$BASE_TAG"
  NEED_FORCE=true
fi

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

# Replace "unreleased" with today's date in CHANGELOG
if [ -f "CHANGELOG.md" ]; then
  TODAY=$(/bin/date +%Y-%m-%d)
  /usr/bin/sed -i '' "s/— unreleased/— $TODAY/" CHANGELOG.md
  git add CHANGELOG.md
fi

echo "Committing..."
git commit -m "$MSG" || { echo "ERROR: commit failed"; exit 1; }

if [ "$NEED_FORCE" = "true" ]; then
  echo "Force-pushing main (cleaned history)..."
  git push --force-with-lease origin main || { echo "ERROR: push failed — is branch protection disabled?"; exit 1; }
else
  echo "Pushing main..."
  git push origin main || { echo "ERROR: push failed — is branch protection disabled?"; exit 1; }
fi

echo "Creating tag $TAG..."
git tag -a "$TAG" -m "PrefWatch $TAG"
git push origin "$TAG" || { echo "ERROR: tag push failed"; exit 1; }

# Create GitHub release with CHANGELOG notes for this version
echo "Creating GitHub release..."
RELEASE_NOTES=$(/usr/bin/awk '/^## /{if(n++)exit}n' CHANGELOG.md)
gh release create "$TAG" --title "PrefWatch $TAG" --notes "$RELEASE_NOTES" || echo "WARNING: gh release failed (install gh CLI or create manually)"

# Return to dev and bump patch version for next development cycle
git checkout dev

CURRENT_VER="${TAG#v}"
MAJOR="${CURRENT_VER%%.*}"
REST="${CURRENT_VER#*.}"
MINOR="${REST%%.*}"
PATCH="${REST#*.}"
NEXT_VER="${MAJOR}.${MINOR}.$((PATCH + 1))"

echo "Bumping dev to v$NEXT_VER..."
/usr/bin/sed -i '' "s/^# Version:.*$/# Version: $NEXT_VER/" prefwatch.sh

# Update released version date and add new CHANGELOG section on dev
TODAY=$(/bin/date +%Y-%m-%d)
/usr/bin/sed -i '' "s/## $CURRENT_VER — unreleased/## $CURRENT_VER — $TODAY/" CHANGELOG.md
/usr/bin/sed -i '' "1a\\
\\
## $NEXT_VER — unreleased\\
" CHANGELOG.md

git add prefwatch.sh CHANGELOG.md
git commit -m "bump: start v$NEXT_VER development"
git push origin dev

echo ""
echo "Done — released $TAG on main, dev bumped to v$NEXT_VER."
