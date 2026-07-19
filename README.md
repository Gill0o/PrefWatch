# PrefWatch

A macOS monitoring tool that watches preference changes in real-time and generates the exact commands to reproduce them.

## Key Features

- **Reproducible commands** — every change is emitted as the command that recreates it: `defaults`/`PlistBuddy`, `pmset` for energy, `lpadmin` for printer queues
- **ALL mode** — watch every domain at once; no need to know which one changed (`fs_usage` + polling)
- **Beyond plists** (sudo) — toggles stored outside plists, with the matching command: Remote Login / Screen Sharing / Remote Management, printer sharing, per-user ARD privileges
- **Contextual notes** — inline `# NOTE:` comments: how to apply a change (`killall Dock`, logout/login), or why a real change produced no command
- **ByHost support** — emits `-currentHost` for per-hardware prefs (trackpad, Bluetooth)
- **Noise filtering** — 450+ rules, so only real changes surface
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
```

## Usage

| Option | Short | Description | Default |
|--------|-------|-------------|---------|
| `[domain]` | -- | Domain to monitor (no sudo needed) | `ALL` (sudo) |
| `--verbose` | `-v` | Show diffs and debug info | Off |
| `--log <path>` | `-l` | Custom log file path | Auto |
| `--no-system` | -- | Exclude `/Library/Preferences` | Include |
| `--exclude <glob>` | `-e` | Domain patterns to exclude | Built-in |
| `--hot-domains <list>` | -- | Comma-separated domains kept permanently active for instant first-change detection (pass `NONE` to disable) | common System Settings panels (see `HOT_DOMAINS`) |
| `--mdm` | -- | Make PlistBuddy paths fleet-deployable: `$loggedInUser` for the home, `$UUID` for ByHost files | Off |

## Jamf Pro Integration

Jamf reserves `$1`–`$3` (mount point, computer name, user), so PrefWatch takes its parameters from `$4` onward: `$4`=domain, `$5`=log path, `$6`=include system, `$7`=only cmds, `$8`=exclusions, `$9`=MDM output, `$10`=hot domains. Launches Console.app for live viewing; logs to stdout + file + syslog.

## Scope

PrefWatch monitors plist files and out-of-plist state: energy (`pmset`), printers (CUPS), and sudo-gated sharing / Remote Management (see *Beyond plists*).

Anything stored elsewhere won't be detected: internal app databases (Safari, Mail, Calendar), protected system stores (Privacy permissions), daemon-owned state (the Desktop wallpaper), and the hardware itself (display and keyboard brightness, HDR, battery charge limit). **No output there is expected, not a bug** — none of it reaches a plist PrefWatch watches, so there is nothing to capture or reproduce.

Inline `# NOTE:` comments cover two cases: how to apply a change (logout/login, `killall`, restart a service, run as root), and why a real change produced no command (a new user account, a Dock reorder). Out-of-reach settings get no note either.

## Detection

- ALL mode without `sudo` falls back to polling only (no `fs_usage`) — still functional, but slower.
- Latency depends on when `cfprefsd` flushes writes to disk. Hot domains are flushed every 0.5s so changes surface in a second or two; a cold domain can take several seconds on its first change — pass it via `--hot-domains` upfront if that matters.

## Security

PrefWatch logs plist diffs to `/var/log/prefwatch-v*.log` and syslog. These may contain user-specific data (IDs, tokens, paths). **Review before sharing** — use `--exclude` to skip sensitive domains.

## License

MIT — see [LICENSE](LICENSE).

---

[CHANGELOG](CHANGELOG.md) · [Issues](https://github.com/Gill0o/PrefWatch/issues) · [Discussions](https://github.com/Gill0o/PrefWatch/discussions)
