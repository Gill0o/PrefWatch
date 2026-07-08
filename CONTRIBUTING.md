# Contributing to PrefWatch

Thanks for your interest in contributing to PrefWatch! This guide covers how the project is developed and how to get a change merged.

## Table of Contents
- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Branching Strategy](#branching-strategy)
- [Development Workflow](#development-workflow)
- [Commit Guidelines](#commit-guidelines)
- [CHANGELOG](#changelog)
- [Testing](#testing)
- [Pull Request Process](#pull-request-process)
- [Coding Standards](#coding-standards)

## Code of Conduct

- Be respectful and inclusive
- Accept constructive criticism gracefully
- Focus on what's best for the project and its users

## Getting Started

1. **Fork the repository** on GitHub.
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/<you>/PrefWatch.git
   cd PrefWatch
   ```
3. **Add the upstream remote**:
   ```bash
   git remote add upstream https://github.com/Gill0o/PrefWatch.git
   ```
4. **Install the pre-commit hook** (optional — reminds you to update the CHANGELOG):
   ```bash
   cp pre-commit .git/hooks/pre-commit
   chmod +x .git/hooks/pre-commit
   ```

## Branching Strategy

- **`main`** — release-only. Every commit is a squashed release cut by the maintainer; it is protected and **cannot be pushed to directly**. Do not target it.
- **`dev`** — the integration branch where all work lands. **Open your PRs against `dev`.** Releases are cut from `dev` by the maintainer.

Create a topic branch from `dev` in your fork:
```bash
git remote add upstream https://github.com/Gill0o/PrefWatch.git   # once
git fetch upstream
git checkout -b feature/short-description upstream/dev
```

Branch naming:
- Features: `feature/description`
- Bug fixes: `fix/description`
- Documentation: `docs/description`

## Development Workflow

1. **Branch** from `dev` (above).
2. **Make focused, atomic changes.** `prefwatch.sh` is a single zsh script — keep new logic in the matching section (see [Coding Standards](#coding-standards)).
3. **Test thoroughly** (see [Testing](#testing)) — especially round-tripping any emitted `defaults`/`PlistBuddy` command.
4. **Update the CHANGELOG** (see below) and any affected docs (README).
5. **Commit** following the guidelines below.
6. **Push to your fork** and **open a PR against `dev`**.

> Versioning, release archiving (`release/`), tagging, and the merge to `main` are handled by the maintainer — you don't bump the version or tag anything.

## Commit Guidelines

### Format
```
<type>(<scope>): <subject>

<body>

<footer>
```
`scope` is optional (most commits omit it). Keep the subject imperative and under ~72 chars.

### Types
- `feat` — new feature
- `fix` — bug fix
- `docs` — documentation only
- `style` — formatting, no logic change
- `refactor` — no feature or bug fix
- `perf` — performance
- `test` — tests
- `chore` — maintenance

### Examples
```
feat: emit a `killall Dock` NOTE for Dock preference changes

fix: place -currentHost before the verb in emitted ByHost writes

  The flag after the key was rejected by `defaults`, so ByHost prefs
  (Control Center modules, trackpad, ColorSync) wrote nothing.

docs: clarify NOTE scope for undetectable settings
```

## CHANGELOG

Add an entry under the top **`## X.Y.Z — unreleased`** section in the same commit as your code change. Use the project's section headers — **`### Feature`**, **`### Fix`**, **`### Noise`**, **`### Performance`**, **`### UX`** (singular, not Keep-a-Changelog's `Added`/`Fixed`). One tight line per entry: what changed, briefly why.

```markdown
## X.Y.Z — unreleased

### Feature
- Short description of the change and why it matters.
```

Leave the `— unreleased` marker as-is; the maintainer dates it at release.

## Testing

There is no automated test suite — testing is manual. Before opening a PR:

- [ ] **Syntax**: `zsh -n prefwatch.sh` passes (the CI runs this; the script is zsh-only).
- [ ] **Specific domain**: `./prefwatch.sh com.apple.dock` (no sudo).
- [ ] **ALL mode**: `sudo ./prefwatch.sh`.
- [ ] **Round-trip emitted commands**: run each generated `defaults`/`PlistBuddy` command against a scratch domain and read it back — do NOT judge correctness by reading the command. Escaping, `-currentHost` placement, and array indexes have all bitten this way.
- [ ] **Exclusions** still work (`--exclude 'com.apple.Safari*'`).
- [ ] **Log output** is correct.
- [ ] If possible, test on more than one macOS version (Sonoma / Sequoia / Tahoe behave differently).

Jamf mode is auto-detected from positional parameters (`$4`=domain, `$5`=log, `$6`=include system, `$7`=only-cmds, `$8`=exclusions, `$9`=MDM output, `$10`=hot domains) — relevant for deployment testing, not day-to-day dev.

## Pull Request Process

1. Target the **`dev`** branch.
2. Update the **CHANGELOG** and any affected docs.
3. Complete manual testing (above).
4. Fill out the PR template.
5. Request review and address feedback; squash if asked.

### PR Checklist
- [ ] Branch based on `upstream/dev`, no conflicts
- [ ] Targets `dev` (not `main`)
- [ ] Code follows the style below
- [ ] CHANGELOG updated (under `— unreleased`)
- [ ] Docs updated if behaviour changed
- [ ] Manual testing complete (incl. round-trip of emitted commands)

## Coding Standards

### Shell
- `prefwatch.sh` is **zsh** (`#!/bin/zsh`) and uses zsh-only constructs — validate with `zsh -n`. Helper scripts (`release.sh`, `pre-commit`) are bash.
- The script runs under `set -e`; guard any command that may legitimately fail with `|| true` / `|| :`.
- Quote variables: `"$var"`. Expand arrays as `"${arr[@]}"`.
- Lowercase for locals (`local my_var`), UPPERCASE for globals/constants (`HOT_DOMAINS`).
- Comment the *why*, not the *what*. Keep functions small and focused.

### Where things live
`prefwatch.sh` is a single zsh script split into sections marked by `# ----` banners:

1. **Preflight & Environment** — CLI/Jamf argument parsing, execution security, environment setup
2. **Utilities** — small shared helpers
3. **Filtering** — `DEFAULT_EXCLUSIONS`, `is_excluded_domain`, `is_noisy_key` / `is_noisy_pbcmd` / `is_noisy_command`
4. **Logging** — `log_line` / `log_user` / `log_system` / `_log`
5. **Plist & PlistBuddy** — dump, type/value extraction, and PlistBuddy conversion helpers
6. **Command Emission** — `_build_defaults_write_cmd` / `_build_defaults_delete_cmd`, `_emit_cmd`, `_process_*`
7. **Diff Engine** — array / nested-dict diffing and the parallel Python workers
8. **Domain Diff** — `show_domain_diff` (via `defaults export`)
9. **Monitoring** — the watchers (`fs_watch`, `poll_watch`, `cups_*`, `pmset_watch`, `ard_privs_watch`, …) and the main loop

Put new logic in the matching section and mirror the existing helper. Common cases:
- **Exclude a noisy domain** → add a glob to `DEFAULT_EXCLUSIONS`
- **Filter a noisy key** → add a pattern to `is_noisy_key`
- **New contextual NOTE** → add a case to `_emit_contextual_note`
- **New watcher** → add it to the Monitoring section and register it (start + trap + `_watch_active`)

### zsh gotchas to know
- `local x` (no `=`) re-run inside a loop prints `x=value` to stdout — declare loop locals once before the loop or always initialise them.
- `$(...)` and `&` are real subshells (global writes are lost); a `while … done < <(cmd)` or `<<<` does **not** subshell (unlike the last stage of a `|` pipe, which in zsh runs in the current shell).

## Questions?

- Open a [Question issue](https://github.com/Gill0o/PrefWatch/issues/new?template=question.md)
- Browse existing [Issues](https://github.com/Gill0o/PrefWatch/issues) and [Discussions](https://github.com/Gill0o/PrefWatch/discussions)

Thank you for helping make PrefWatch better! 🙏
