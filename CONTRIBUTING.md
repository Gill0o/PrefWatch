# Contributing to PrefWatch

Thank you for your interest in contributing to PrefWatch! This document provides guidelines and instructions for contributing to the project.

## Table of Contents
- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Branching Strategy](#branching-strategy)
- [Commit Guidelines](#commit-guidelines)
- [Version Management](#version-management)
- [Testing](#testing)
- [Pull Request Process](#pull-request-process)
- [Coding Standards](#coding-standards)

## Code of Conduct

This project follows a code of conduct to ensure a welcoming environment for all contributors:
- Be respectful and inclusive
- Accept constructive criticism gracefully
- Focus on what's best for the community
- Show empathy towards other community members

## Getting Started

1. **Fork the repository** on GitHub
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/Gill0o/PrefWatch.git
   cd PrefWatch
   ```
3. **Add the upstream remote**:
   ```bash
   git remote add upstream https://github.com/Gill0o/PrefWatch.git
   ```
4. **Install the pre-commit hook** (optional but recommended):
   ```bash
   cp pre-commit .git/hooks/pre-commit
   chmod +x .git/hooks/pre-commit
   ```

## Development Workflow

### 1. Create a Feature Branch
Always create a new branch for your work:
```bash
git checkout main
git pull upstream main
git checkout -b feature/your-feature-name
```

Branch naming conventions:
- Features: `feature/description`
- Bug fixes: `fix/description`
- Documentation: `docs/description`
- Hotfixes: `hotfix/description`

### 2. Make Your Changes
- Keep changes focused and atomic
- Test thoroughly on your local machine
- Update documentation as needed
- Add or update tests if applicable

### 3. Commit Your Changes
Follow the commit message guidelines (see below).

### 4. Push to Your Fork
```bash
git push origin feature/your-feature-name
```

### 5. Create a Pull Request
- Go to GitHub and create a PR from your branch to the upstream `main` branch
- Fill out the PR template completely
- Link any related issues

## Branching Strategy

This project uses a simplified Git Flow:

### Main Branches
- **`main`**: Production-ready code. Protected branch requiring PR reviews.
- **`develop`**: (Optional) Integration branch for features before release.

### Supporting Branches

#### Feature Branches
- Naming: `feature/short-description`
- Created from: `main` (or `develop`)
- Merged back into: `main` (or `develop`)
- Used for: New features or enhancements

Example:
```bash
git checkout -b feature/add-json-export main
# ... make changes ...
git push origin feature/add-json-export
# Create PR to main
```

#### Fix Branches
- Naming: `fix/short-description`
- Created from: `main`
- Merged back into: `main`
- Used for: Bug fixes

#### Hotfix Branches
- Naming: `hotfix/description`
- Created from: `main`
- Merged back into: `main` AND `develop` (if exists)
- Used for: Critical production fixes that can't wait for the next release

Example:
```bash
git checkout -b hotfix/critical-parsing-error main
# ... fix the issue ...
git checkout main
git merge --no-ff hotfix/critical-parsing-error
git tag -a v2.4.1 -m "Hotfix: Critical parsing error"
```

## Commit Guidelines

### Commit Message Format
```
<type>(<scope>): <subject>

<body>

<footer>
```

### Types
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, no logic change)
- `refactor`: Code refactoring (no feature or bug fix)
- `perf`: Performance improvements
- `test`: Adding or updating tests
- `chore`: Maintenance tasks, dependency updates

### Examples
```bash
feat(monitoring): add support for JSON export format

Implements JSON export of preference changes to make it easier
to parse output programmatically. Adds new parameter $9 for
output format selection.

Closes #42

---

fix(parsing): correct PlistBuddy command generation for arrays

The previous implementation didn't handle nested dictionaries
correctly. This fix adds proper escaping and nesting.

Fixes #38

---

docs(readme): update installation instructions

Added clarification for Jamf Pro deployment and macOS 15 compatibility.
```

## Version Management

This project uses semantic versioning (MAJOR.MINOR.PATCH):
- **MAJOR**: Breaking changes
- **MINOR**: New features (backward compatible)
- **PATCH**: Bug fixes (backward compatible)

### Updating Version

1. **Update the version** in the script header:
   ```bash
   # Version: 2.5.0
   ```

2. **Update CHANGELOG.md** with your changes:
   ```markdown
   ## 2.5.0 — 2025-02-03
   - **NEW FEATURE**: Description of your feature
   - Added support for X
   - Improved Y
   ```

3. **Commit both files**:
   ```bash
   git add prefwatch.sh CHANGELOG.md
   git commit -m "feat: your feature description"
   ```

4. **The pre-commit hook** will automatically:
   - Create a versioned copy in `versions/`
   - Update the `latest` symlink
   - Stage the new files

5. **Tag the release** (after merge to main):
   ```bash
   git tag -a prefwatch-v2.5.0 -m "Version 2.5.0"
   git push upstream main --tags
   ```

## Testing

### Manual Testing Checklist
Before submitting a PR, test your changes:

- [ ] Test with a specific domain: `./prefwatch.sh com.apple.dock`
- [ ] Test with ALL domains: `./prefwatch.sh ALL`
- [ ] Test with various parameter combinations
- [ ] Test on both zsh and bash (if possible)
- [ ] Test on different macOS versions (if available)
- [ ] Verify generated `defaults` commands work correctly
- [ ] Check that exclusions still work properly
- [ ] Verify log output is correct

### Test Environment
```bash
# Basic test
./prefwatch.sh com.apple.dock 30

# Test with ONLY_CMDS
./prefwatch.sh ALL 60 "" "" "" true true

# Test with exclusions
./prefwatch.sh ALL 60 "" "" "" true false "com.apple.Safari*"
```

## Pull Request Process

1. **Update documentation** if you've changed functionality
2. **Update CHANGELOG.md** with your changes
3. **Ensure all tests pass** (manual testing)
4. **Fill out the PR template** completely
5. **Request review** from maintainers
6. **Address review feedback** promptly
7. **Squash commits** if requested before merge

### PR Checklist
- [ ] Branch is up to date with `main`
- [ ] Code follows project style guidelines
- [ ] Documentation is updated
- [ ] CHANGELOG.md is updated
- [ ] Version number is updated (if needed)
- [ ] Manual testing is complete
- [ ] PR template is filled out
- [ ] No merge conflicts

## Coding Standards

### Shell Script Guidelines
- Use `#!/bin/bash` or `#!/bin/zsh` shebang as appropriate
- Use `set -euo pipefail` for error handling
- Quote all variables: `"$VARIABLE"`
- Use lowercase for local variables: `local my_var="value"`
- Use UPPERCASE for global constants: `TIMEOUT=300`
- Add comments for complex logic
- Keep functions focused and small
- Use meaningful function and variable names

### Code Organization
The main script is organized into 10 sections:
1. Configuration & Security
2. Basic Utility Functions
3. Filtering & Exclusion Functions
4. Logging Functions
5. Plist Manipulation Functions
6. PlistBuddy Conversion Functions
7. Array Operations Functions
8. Diff & Comparison Functions
9. Monitoring (Watch) Functions
10. Main Execution

When adding new functionality, place it in the appropriate section.

### Documentation Standards
- Add comments explaining "why", not "what"
- Document function parameters and return values
- Update README.md for user-facing changes
- Update CHANGELOG.md for all changes
- Keep code examples up to date

### Example Function Documentation
```bash
# Extracts the type and value from a plist entry
# Parameters:
#   $1 - Domain name (e.g., "com.apple.dock")
#   $2 - Key path (e.g., "persistent-apps:0:tile-data")
#   $3 - Plist file path
# Returns:
#   Echoes "type value" (e.g., "string MyValue")
# Example:
#   extract_type_value "com.apple.dock" "orientation" "/path/to/plist"
function extract_type_value() {
    # Implementation...
}
```

## Questions?

If you have questions not covered in this guide:
- Open a [Question Issue](https://github.com/Gill0o/PrefWatch/issues/new?template=question.md)
- Check existing [Issues](https://github.com/Gill0o/PrefWatch/issues)
- Review [Discussions](https://github.com/Gill0o/PrefWatch/discussions)

## Thank You!

Your contributions make this project better for everyone. We appreciate your time and effort! 🙏
