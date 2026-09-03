# PrefWatch

A macOS monitoring tool that watches preference changes in real-time and generates the exact commands to reproduce them.

## Key Features

- **Reproducible commands** — every change is emitted as the exact command that recreates it: `defaults`/`PlistBuddy` or the right built-in CLI (`scutil`, `systemsetup`, `spctl`/`socketfilterfw`, `mdutil`, `pmset`, `lpadmin`, `cupsctl`, `launchctl`, `dscl`)
- **ALL mode** — watch every domain at once; no need to know which one changed
- **Contextual notes** — inline `# NOTE:` comments: how to apply a change, the tool when `defaults` can't, or why it isn't reproducible (see Scope)
- **ByHost support** — emits `-currentHost` for per-hardware prefs (trackpad, Bluetooth)
- **Noise filtering** — 500+ rules, so only real changes surface
- **Minimal dependencies** — one zsh script + Python 3

## Quick Start

Run in Terminal. Output is also logged and viewable in Console.app.

```bash
# Monitor all preferences
sudo ./prefwatch.sh

# Monitor a specific domain (no sudo, lower CPU)
./prefwatch.sh com.apple.finder

# Verbose mode
sudo ./prefwatch.sh -v

# Stop it
sudo pkill -f 'prefwatch\.sh'
```

## Usage

| Option | Short | Description | Default |
|--------|-------|-------------|---------|
| `[domain]` | -- | Domain to monitor (no sudo needed) | `ALL` (sudo) |
| `--verbose` | `-v` | Show diffs and debug info | Off |
| `--debug` | -- | Log `# FILTERED: <dom> <key> (reason)` when a detected change is suppressed (answers "why didn't my change appear?") | Off |
| `--log <path>` | `-l` | Custom log file path | Auto |
| `--no-system` | -- | Exclude `/Library/Preferences` | Include |
| `--exclude <glob>` | `-e` | Domain patterns to exclude | Built-in |
| `--hot-domains <list>` | -- | Comma-separated domains kept permanently active for instant first-change detection (pass `NONE` to disable) | common System Settings panels (see `HOT_DOMAINS`) |
| `--mdm` | -- | Make emitted commands fleet-deployable from a root Jamf policy: user-domain commands are prefixed with a `runAsUser` helper, PlistBuddy paths use `$loggedInUser`/`$UUID` (ByHost) | Off |
| `--no-console` | -- | Don't open Console.app or stop when it closes — run until Ctrl+C (interactive/VM testing) | Off |

## Jamf Pro Integration

Jamf reserves `$1`–`$3` (mount point, computer name, user), so PrefWatch takes its parameters from `$4` onward: `$4`=domain, `$5`=log path, `$6`=include system, `$7`=only cmds, `$8`=exclusions, `$9`=MDM output, `$10`=hot domains, `$11`=debug. Launches Console.app for live viewing; logs to stdout + file + syslog.

## Scope

PrefWatch reproduces what lands in a watched plist (`defaults`/`PlistBuddy`), plus the out-of-band settings its CLIs cover (above).

A few changes it **detects but can't reduce to one built-in command** — it emits an explanatory `# NOTE:` instead: the wallpaper, FileVault (needs a recovery key), the battery charge limit (SMC-managed), a new user account, a Dock reorder. Where an install-first helper reproduces it, the NOTE names the tool (see [Third-party tools](#third-party-tools)).

Everything else is **invisible** — no output is expected, not a bug: internal app databases (Safari, Mail, Calendar), protected system stores (Privacy/TCC permissions), sandboxed app prefs (App Store apps keep theirs under `~/Library/Containers`), and hardware state (display & keyboard brightness, HDR).

A `# NOTE:` also rides on a reproduced change: how to apply it (logout/login, `killall`, restart a service, run as root), or a caveat on the emitted command — a positional array index or a ByHost/display UUID that won't transplant, or a pane that writes every default on first open.

## Third-party tools

For settings with no built-in command, a `# NOTE:` names the tool — and emits its command outright for default apps:

- [`utiluti`](https://github.com/scriptingosx/utiluti) — default apps (URL schemes & file types)
- [`dockutil`](https://github.com/kcrawford/dockutil) — Dock items and order
- [`desktoppr`](https://github.com/scriptingosx/desktoppr) — desktop wallpaper

## Detection

- ALL mode without `sudo` covers `~/Library/Preferences`. Root is what adds `/Library/Preferences`, the sharing commands, launchd state and `fs_usage`.
- Latency depends on when `cfprefsd` flushes writes to disk. Hot domains are flushed every 0.5s so changes surface in a second or two; a cold domain can take about ten seconds on its first change — pass it via `--hot-domains` upfront if that matters.

## Security

PrefWatch logs plist diffs to `/var/log/prefwatch-v*.log` and syslog. These may contain user-specific data (IDs, tokens, paths). **Review before sharing** — use `--exclude` to skip sensitive domains.

## License

MIT — see [LICENSE](LICENSE).

---

[CHANGELOG](CHANGELOG.md) · [Issues](https://github.com/Gill0o/PrefWatch/issues) · [Discussions](https://github.com/Gill0o/PrefWatch/discussions)
