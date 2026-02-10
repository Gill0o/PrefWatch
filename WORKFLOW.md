# Git Workflow Guide for PrefWatch

This document explains the recommended Git workflow for the PrefWatch project.

## 📋 Table of Contents
- [Overview](#overview)
- [Branch Strategy](#branch-strategy)
- [Common Workflows](#common-workflows)
- [GitHub Settings](#github-settings)
- [Release Process](#release-process)
- [Best Practices](#best-practices)

## Overview

This project uses a **simplified Git Flow** strategy optimized for a shell script project with version management. The workflow balances simplicity with professional practices.

## Branch Strategy

### 🌳 Branch Structure

```
main (production-ready)
  ├─── feature/add-json-export
  ├─── fix/parsing-error
  └─── hotfix/critical-bug
```

### Branch Types and Rules

#### 1. `main` Branch
- **Purpose**: Production-ready code
- **Protection**: Should be protected (see GitHub Settings)
- **Updates**: Only through Pull Requests
- **Tagging**: All releases are tagged here
- **Rule**: Never commit directly to main

#### 2. Feature Branches
- **Naming**: `feature/short-description`
- **Created from**: `main`
- **Merged to**: `main` (via PR)
- **Lifespan**: Short-lived (delete after merge)
- **Purpose**: New features, enhancements

#### 3. Fix Branches
- **Naming**: `fix/short-description`
- **Created from**: `main`
- **Merged to**: `main` (via PR)
- **Purpose**: Non-critical bug fixes

#### 4. Hotfix Branches
- **Naming**: `hotfix/description`
- **Created from**: `main`
- **Merged to**: `main` (via PR)
- **Purpose**: Critical production fixes
- **Note**: Should be fast-tracked

## Common Workflows

### 🚀 Starting a New Feature

```bash
# 1. Ensure you're on main and up to date
git checkout main
git pull origin main

# 2. Create a feature branch
git checkout -b feature/add-json-export

# 3. Make your changes
# Edit files...

# 4. Update version and changelog
# Edit prefwatch.sh (update version number)
# Edit CHANGELOG.md (add your changes)

# 5. Commit your changes
git add prefwatch.sh CHANGELOG.md
git commit -m "feat(export): add JSON export functionality"
# The pre-commit hook will create versioned file automatically

# 6. Stage the versioned files
git add versions/prefwatch-v2.5.0.sh versions/latest

# 7. Push to your fork
git push origin feature/add-json-export

# 8. Create Pull Request on GitHub
# Go to GitHub and create PR from your feature branch to main
```

### 🐛 Fixing a Bug

```bash
# 1. Create fix branch from main
git checkout main
git pull origin main
git checkout -b fix/correct-array-parsing

# 2. Fix the bug
# Edit files...

# 3. Update version (PATCH version) and changelog
# prefwatch.sh: 2.4.0 -> 2.4.1
# CHANGELOG.md: Add fix description

# 4. Commit
git add prefwatch.sh CHANGELOG.md
git commit -m "fix(parsing): correct array index handling"

# 5. Push and create PR
git push origin fix/correct-array-parsing
```

### 🔥 Hotfix for Critical Issue

```bash
# 1. Create hotfix from main
git checkout main
git pull origin main
git checkout -b hotfix/security-vulnerability

# 2. Fix the critical issue
# Edit files...

# 3. Update version and changelog
# Bump PATCH version: 2.4.0 -> 2.4.1
# Add urgent fix to CHANGELOG.md

# 4. Commit and push
git add prefwatch.sh CHANGELOG.md
git commit -m "fix(security): patch command injection vulnerability"
git push origin hotfix/security-vulnerability

# 5. Create PR with [URGENT] or [HOTFIX] label
# Request immediate review

# 6. After merge, verify the tag
git checkout main
git pull origin main
git tag -a prefwatch-v2.4.1 -m "Hotfix: Security vulnerability"
git push origin --tags
```

### 🔄 Syncing Your Fork

```bash
# Add upstream remote (only once)
git remote add upstream https://github.com/Gill0o/Watch-preferences.git

# Sync your fork regularly
git checkout main
git fetch upstream
git merge upstream/main
git push origin main
```

### 🧹 Cleaning Up Old Branches

```bash
# Delete local branch
git branch -d feature/completed-feature

# Delete remote branch
git push origin --delete feature/completed-feature

# Prune deleted remote branches
git fetch --prune
```

## GitHub Settings

### Recommended Repository Settings

#### Branch Protection Rules for `main`

Enable these protections on GitHub:
1. **Require pull request reviews before merging**
   - Required approving reviews: 1 (or more)
   - Dismiss stale reviews when new commits are pushed

2. **Require status checks to pass**
   - If you add CI/CD later

3. **Require branches to be up to date**
   - Ensures no merge conflicts

4. **Do not allow bypassing the above settings**
   - Even admins should follow the rules

5. **Restrict who can push to matching branches**
   - Optional: only maintainers

#### How to Set Up (for repository owner)
```
GitHub Repo → Settings → Branches → Add rule
Branch name pattern: main
☑ Require a pull request before merging
☑ Require approvals (1)
☑ Dismiss stale pull request approvals when new commits are pushed
☑ Require conversation resolution before merging
```

### Labels

Create these labels for issues and PRs:
- `bug` (red): Something isn't working
- `enhancement` (blue): New feature or request
- `documentation` (light blue): Improvements to documentation
- `question` (purple): Questions about usage
- `help wanted` (green): Extra attention needed
- `good first issue` (green): Good for newcomers
- `priority: high` (red): High priority
- `priority: low` (grey): Low priority

## Release Process

### Creating a New Release

1. **Ensure main is up to date**
   ```bash
   git checkout main
   git pull origin main
   ```

2. **Verify version files exist**
   ```bash
   ls -la versions/prefwatch-v2.4.0.sh
   ls -la versions/latest
   ```

3. **Create Git tag**
   ```bash
   git tag -a prefwatch-v2.4.0 -m "Version 2.4.0: Major refactoring"
   git push origin --tags
   ```

4. **Create GitHub Release**
   - Go to GitHub → Releases → Create new release
   - Select the tag you just pushed
   - Release title: `v2.4.0 - Major Refactoring`
   - Description: Copy from CHANGELOG.md
   - Attach the versioned script: `versions/prefwatch-v2.4.0.sh`
   - Publish release

### Release Checklist
- [ ] Version updated in script header
- [ ] CHANGELOG.md updated with all changes
- [ ] All changes committed and pushed to main
- [ ] Git tag created and pushed
- [ ] GitHub Release created with notes
- [ ] Release announcement made (if applicable)
- [ ] Documentation updated on GitHub Pages (if applicable)

## Best Practices

### ✅ Do's

1. **Always work in branches**
   - Never commit directly to main

2. **Keep commits atomic**
   - One logical change per commit

3. **Write clear commit messages**
   - Follow the conventional commits format

4. **Update CHANGELOG.md**
   - Document all user-facing changes

5. **Test before pushing**
   - Run the script with various parameters

6. **Sync regularly**
   - Pull from main before starting work

7. **Use meaningful branch names**
   - `feature/add-json-export` not `my-changes`

8. **Delete merged branches**
   - Keep repository clean

### ❌ Don'ts

1. **Don't commit directly to main**
   - Always use PRs

2. **Don't force push to shared branches**
   - Unless you know what you're doing

3. **Don't commit large binary files**
   - Keep the repo lightweight

4. **Don't mix unrelated changes**
   - Keep PRs focused

5. **Don't forget to update version**
   - Update both script and CHANGELOG

6. **Don't leave stale branches**
   - Clean up after merge

### 📝 Commit Message Examples

**Good:**
```
feat(export): add JSON export format option
fix(parsing): correct nested dictionary handling
docs(readme): update installation instructions
refactor(logging): simplify log function signatures
```

**Bad:**
```
update
fixed stuff
changes
wip
```

## Visual Workflow Diagram

```
┌─────────────┐
│    main     │ ◄────────────────┐
└──────┬──────┘                  │
       │                         │
       │ git checkout -b         │ PR merge
       │ feature/X               │ (after review)
       │                         │
       ▼                         │
┌─────────────┐                  │
│  feature/X  │ ─────────────────┘
└──────┬──────┘
       │
       │ commits
       │
       ▼
┌─────────────┐
│    push     │ ──────► GitHub PR
└─────────────┘
```

## Quick Reference Commands

```bash
# Start new feature
git checkout main && git pull && git checkout -b feature/name

# Commit changes
git add . && git commit -m "type(scope): message"

# Push and create PR
git push origin feature/name

# Update from main
git checkout feature/name && git merge main

# Delete branch after merge
git branch -d feature/name
git push origin --delete feature/name

# Create release tag
git tag -a prefwatch-v2.4.0 -m "Version 2.4.0"
git push origin --tags
```

## Need Help?

- See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed contribution guidelines
- Open a [Question Issue](https://github.com/Gill0o/Watch-preferences/issues/new?template=question.md)
- Review [existing issues](https://github.com/Gill0o/Watch-preferences/issues)

---

**Remember**: A clean, organized workflow makes collaboration easier and the project more maintainable! 🚀
