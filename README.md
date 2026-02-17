# PrefWatch

A macOS monitoring tool that watches preference changes in real-time and generates the exact commands to reproduce them.

## Key Features

- **Full command coverage** — `defaults write`, `PlistBuddy`, `pmset`, `lpadmin` depending on what changed
- **ALL mode** — discover which domain changed without knowing in advance (`fs_usage` + polling)
- **Contextual notes** — actionable comments with each command (`killall Dock`, `logout/login required`, human-readable values)
- **ByHost auto-detection** — automatically adds `-currentHost` for per-hardware preferences (trackpad, Bluetooth)
- **Noise filtering** — 100+ domain exclusions and global key patterns to surface only real changes
- **Minimal dependencies** — single zsh script + Python 3 (for array/dict detection)

## Quick Start

Run in Terminal. Output is also logged and viewable in Console.app.

```bash
# Monitor all preferences
sudo ./prefwatch.sh

# Monitor a specific domain (no sudo, lower CPU)
./prefwatch.sh com.apple.dock

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
| `--only-cmds` | `-q` | Show only executable commands | On |

## Jamf Pro Integration

Auto-detects Jamf mode when called with positional parameters (`$4`=domain, `$5`=log path, `$6`=include system, `$7`=only cmds, `$8`=exclusions). Launches Console.app for live viewing, logs to stdout + file + syslog.

## Scope

PrefWatch monitors plist-based preferences, energy settings (`pmset`), and printer configuration (`lpadmin`). Settings stored outside these sources are out of scope by design:

- **Some Apple apps** (Safari, Messages, etc.) — recent macOS versions store preferences outside plists (CloudKit, sandbox databases)
- **Some System Settings** — certain panels write to SQLite databases or SIP-protected frameworks
- **Secure Enclave / FileVault** — hardware-level security, not accessible via plists
- **Runtime state** — transient settings that don't persist to disk

## Notes

- ALL mode takes an initial baseline snapshot before monitoring. Wait for "you can now make your changes" before modifying settings.
- There may be a delay between a preference change and its appearance in the console, depending on when `cfprefsd` flushes to disk.

## License

MIT — see [LICENSE](LICENSE).

---

[CHANGELOG](CHANGELOG.md) · [Issues](https://github.com/Gill0o/PrefWatch/issues) · [Discussions](https://github.com/Gill0o/PrefWatch/discussions)
