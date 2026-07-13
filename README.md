# PrefWatch

A macOS monitoring tool that watches preference changes in real-time and generates the exact commands to reproduce them.

## Key Features

- **Reproducible commands** — each detected change is emitted as the exact command to recreate it: `defaults`/`PlistBuddy` for plist preferences, `pmset` for energy, `lpadmin` for printer queues
- **ALL mode** — watch every domain at once and find out which one changed, without naming it upfront (`fs_usage` + polling)
- **Beyond plists** (needs sudo) — captures toggles stored outside plist files and emits the matching command: Remote Login / Screen Sharing / Remote Management, printer sharing, and per-user ARD privileges (`launchctl`, `kickstart`, `systemsetup`, `sharing`, `networksetup`, `cupsctl`, `dscl`)
- **Contextual notes** — inline `# NOTE:` comments saying how to apply a change (`killall Dock`, logout/login) or why a real change produced no command
- **ByHost auto-detection** — automatically adds `-currentHost` for per-hardware preferences (trackpad, Bluetooth)
- **Noise filtering** — 450+ rules (domain exclusions, key-level filters, sub-key patterns) to surface only real changes
- **Minimal dependencies** — single zsh script + Python 3 (for array/dict detection)

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

Auto-detects Jamf mode when called with positional parameters (`$4`=domain, `$5`=log path, `$6`=include system, `$7`=only cmds, `$8`=exclusions, `$9`=MDM output, `$10`=hot domains). Launches Console.app for live viewing, logs to stdout + file + syslog.

## Scope

PrefWatch monitors plist files, energy settings (`pmset`), printer configuration (CUPS), and out-of-plist state changes (needs sudo — see *Beyond plists* above).

Anything stored elsewhere won't be detected: internal app databases (Safari, Mail, Calendar), protected system stores (Privacy permissions), daemon- or framework-owned state (the Desktop wallpaper), and — usually the first thing people try — settings held in the hardware itself (display and keyboard brightness, HDR, display presets, the battery charge limit). **Getting no output for those is expected, not a bug**: they never reach a plist, so there is nothing to capture and nothing to reproduce. Some are configurable via MDM configuration profiles instead.

PrefWatch annotates its output with inline `# NOTE:` comments in two cases: a change that needs an extra step to apply (logout/login, `killall`, restarting a service, running as root), and a change it detects but cannot turn into a command (a new user account, a Dock reorder — real changes, neither reproducible via `defaults`). Out-of-reach settings get no note either — there is nothing to annotate.

## Detection

- ALL mode without `sudo` falls back to polling only (no `fs_usage`) — still functional, but slower.
- Latency depends on when `cfprefsd` flushes writes to disk. Hot domains are flushed every 0.5s so changes surface in a second or two; a cold domain can take several seconds on its first change — pass it via `--hot-domains` upfront if that matters.

## Security

PrefWatch logs plist diffs to `/var/log/prefwatch-v*.log` and syslog. These may contain user-specific data (IDs, tokens, paths). **Review before sharing** — use `--exclude` to skip sensitive domains.

## License

MIT — see [LICENSE](LICENSE).

---

[CHANGELOG](CHANGELOG.md) · [Issues](https://github.com/Gill0o/PrefWatch/issues) · [Discussions](https://github.com/Gill0o/PrefWatch/discussions)
