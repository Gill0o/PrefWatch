# PrefWatch

A macOS monitoring tool that watches preference changes in real-time and generates the exact commands to reproduce them.

## Key Features

- **Reproducible commands** — each detected change is emitted as the exact command to recreate it: `defaults`/`PlistBuddy` for plist preferences, `pmset` for energy, `lpadmin` for printer queues
- **ALL mode** — watch every domain at once and find out which one changed, without naming it upfront (`fs_usage` + polling)
- **Beyond plists** (needs sudo) — captures toggles stored outside plist files and emits the matching command: Remote Login / Screen Sharing / Remote Management, printer sharing, and per-user ARD privileges (`launchctl`, `kickstart`, `systemsetup`, `sharing`, `networksetup`, `cupsctl`, `dscl`)
- **Contextual notes** — actionable comments with each command (`killall Dock`, `logout/login required`, human-readable values)
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
| `--mdm` | -- | Replace user home path with `$loggedInUser` in PlistBuddy commands | Off |

## Jamf Pro Integration

Auto-detects Jamf mode when called with positional parameters (`$4`=domain, `$5`=log path, `$6`=include system, `$7`=only cmds, `$8`=exclusions, `$9`=MDM output, `$10`=hot domains). Launches Console.app for live viewing, logs to stdout + file + syslog.

## Scope

PrefWatch monitors plist files, energy settings (`pmset`), printer configuration (CUPS), and out-of-plist state changes (needs sudo — see *Beyond plists* above). Settings stored elsewhere — internal app databases, protected system stores, or state managed entirely by a daemon or OS framework — won't be detected (e.g. Safari, Mail, Calendar, the Desktop wallpaper, Privacy permissions); some are configurable via MDM configuration profiles instead.

**Hardware-driven settings produce no output — that's expected, not a bug.** Display and keyboard brightness, HDR, display presets, the battery charge limit and the like are held in the SMC/firmware and read through private APIs, never written to a plist — so there is nothing to capture, and nothing to reproduce.

For detected changes that need extra steps to apply (logout/login, `killall`, restarting a service, running as root, etc.), PrefWatch emits inline `# NOTE:` comments. This only covers changes it detects — settings outside its reach (see *Scope*) produce no output and no note.

## Notes

- ALL mode without `sudo` falls back to polling only (no `fs_usage`) — still functional, but slower.
- Detection latency depends on when `cfprefsd` flushes buffered writes to disk. In ALL mode, "hot" domains (the common System Settings panels by default — see `HOT_DOMAINS`) are flushed preemptively every 0.5s, forcing `cfprefsd` to sync them so changes surface within a second or two. Domains already detected once in the session stay hot for 30s after their last change. A cold (never-detected, non-hot) domain may take several seconds on its first change while `cfprefsd` buffers the write — pass it via `--hot-domains <list>` upfront if you need faster detection.

## Security

PrefWatch logs plist diffs to `/var/log/prefwatch-v*.log` and syslog. These may contain user-specific data (IDs, tokens, paths). **Review before sharing** — use `--exclude` to skip sensitive domains.

## License

MIT — see [LICENSE](LICENSE).

---

[CHANGELOG](CHANGELOG.md) · [Issues](https://github.com/Gill0o/PrefWatch/issues) · [Discussions](https://github.com/Gill0o/PrefWatch/discussions)
