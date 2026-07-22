# PrefWatch

A macOS monitoring tool that watches preference changes in real-time and generates the exact commands to reproduce them.

## Key Features

- **Reproducible commands** — every change is emitted as the command that recreates it: `defaults`/`PlistBuddy` for plist prefs, and the matching tool for settings stored outside plists — `scutil` (hostname), `systemsetup` (time zone, NTP), `spctl`/`socketfilterfw` (Gatekeeper, firewall), `mdutil` (Spotlight indexing), `utiluti` (default apps), plus `pmset` (energy), `lpadmin` (printers), sharing services & ARD (with sudo)
- **ALL mode** — watch every domain at once; no need to know which one changed (`fs_usage` + polling)
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
| `--debug` | -- | Log `# FILTERED: <dom> <key> (reason)` when a detected change is suppressed (answers "why didn't my change appear?") | Off |
| `--log <path>` | `-l` | Custom log file path | Auto |
| `--no-system` | -- | Exclude `/Library/Preferences` | Include |
| `--exclude <glob>` | `-e` | Domain patterns to exclude | Built-in |
| `--hot-domains <list>` | -- | Comma-separated domains kept permanently active for instant first-change detection (pass `NONE` to disable) | common System Settings panels (see `HOT_DOMAINS`) |
| `--mdm` | -- | Make PlistBuddy paths fleet-deployable: `$loggedInUser` for the home, `$UUID` for ByHost files | Off |
| `--no-console` | -- | Don't open Console.app or stop when it closes — run until Ctrl+C (interactive/VM testing) | Off |

## Jamf Pro Integration

Jamf reserves `$1`–`$3` (mount point, computer name, user), so PrefWatch takes its parameters from `$4` onward: `$4`=domain, `$5`=log path, `$6`=include system, `$7`=only cmds, `$8`=exclusions, `$9`=MDM output, `$10`=hot domains, `$11`=debug. Launches Console.app for live viewing; logs to stdout + file + syslog.

## Scope

PrefWatch only sees what lands in a watched plist, plus the out-of-band cases above. Everything else is invisible: internal app databases (Safari, Mail, Calendar), protected system stores (Privacy permissions), and the hardware itself (display and keyboard brightness, HDR, battery charge limit). **No output there is expected, not a bug.**

Inline `# NOTE:` comments cover two cases: how to apply a change (logout/login, `killall`, restart a service, run as root), and why a real change isn't a single reproducible command — pointing at the right tool instead (`desktoppr` for the wallpaper, `dockutil` for a Dock reorder, `fdesetup` for FileVault) or explaining it (a new user account). Out-of-reach settings get no note either.

## Detection

- ALL mode without `sudo` falls back to polling only (no `fs_usage`) — still functional, but slower.
- Latency depends on when `cfprefsd` flushes writes to disk. Hot domains are flushed every 0.5s so changes surface in a second or two; a cold domain can take several seconds on its first change — pass it via `--hot-domains` upfront if that matters.

## Security

PrefWatch logs plist diffs to `/var/log/prefwatch-v*.log` and syslog. These may contain user-specific data (IDs, tokens, paths). **Review before sharing** — use `--exclude` to skip sensitive domains.

## License

MIT — see [LICENSE](LICENSE).

---

[CHANGELOG](CHANGELOG.md) · [Issues](https://github.com/Gill0o/PrefWatch/issues) · [Discussions](https://github.com/Gill0o/PrefWatch/discussions)
