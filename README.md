# Watch Preferences

![Version](https://img.shields.io/badge/version-2.9.29--beta-orange.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)
![Shell](https://img.shields.io/badge/shell-zsh-blue.svg)
![Status](https://img.shields.io/badge/status-BETA-orange.svg)

A macOS monitoring tool that watches preference changes in real-time and generates the exact commands to reproduce them.

Change Finder view, add an app to the Dock, flip a trackpad setting — every change becomes a copy-paste command. The script automatically picks `defaults write` or `PlistBuddy` depending on the type of change.

## Quick Start

```bash
# Monitor all preferences (recommended first use)
sudo ./watch-preferences.sh

# Verbose mode: see diffs and key names
sudo ./watch-preferences.sh -v

# Monitor a specific domain (no sudo, lower CPU)
./watch-preferences.sh com.apple.dock
./watch-preferences.sh com.apple.finder

# Custom log file
./watch-preferences.sh com.apple.dock -l /tmp/dock-changes.log
```

## Requirements

- macOS 10.14+ (tested on Sonoma and Tahoe)
- Python 3 for array/dict detection (`xcode-select --install` if missing)
- `sudo` required for ALL mode (`fs_usage`)

## Monitoring Modes

**ALL mode** (default) — monitors all preference domains using `fs_usage` + polling. Requires sudo. Best for discovery: "I changed something, what domain was it?"

```bash
sudo ./watch-preferences.sh
```

**Domain mode** — monitors a single domain via mtime polling (0.5s). Low CPU, no sudo. Best when you know which domain to watch.

```bash
./watch-preferences.sh com.apple.dock
```

## CLI Options

| Option | Short | Description | Default |
|--------|-------|-------------|---------|
| `[domain]` | -- | Preference domain to monitor | `ALL` |
| `--verbose` | `-v` | Show diff details and commands | Off |
| `--log <path>` | `-l` | Custom log file path | Auto |
| `--no-system` | -- | Exclude `/Library/Preferences` | Include |
| `--exclude <glob>` | `-e` | Domain patterns to exclude | Built-in |
| `--only-cmds` | `-q` | Show only executable commands | On |
| `--help` | `-h` | Show help | -- |

## Output Examples

The script generates copy-paste commands for every type of preference change:

```bash
# Scalar values → defaults write
defaults write com.apple.dock "orientation" -string "left"
defaults write com.apple.dock "tilesize" -int 48
defaults write com.apple.dock "autohide" -bool TRUE

# Array additions → PlistBuddy Add (Dock icons, keyboard layouts)
/usr/libexec/PlistBuddy -c 'Add :AppleEnabledInputSources:3 dict' ~/Library/Preferences/com.apple.HIToolbox.plist
/usr/libexec/PlistBuddy -c 'Add :AppleEnabledInputSources:3:InputSourceKind string Keyboard Layout' ~/Library/Preferences/com.apple.HIToolbox.plist

# Nested dict changes → PlistBuddy Set (keyboard shortcuts)
/usr/libexec/PlistBuddy -c 'Set :AppleSymbolicHotKeys:32:value:parameters:1 122' ~/Library/Preferences/com.apple.symbolichotkeys.plist

# Array deletions → PlistBuddy Delete
# WARNING: for multiple deletions, execute from HIGHEST index to LOWEST
/usr/libexec/PlistBuddy -c 'Delete :persistent-apps:3' ~/Library/Preferences/com.apple.dock.plist

# ByHost preferences → auto-detected -currentHost flag
defaults write com.apple.AppleMultitouchTrackpad "ActuateDetents" -currentHost -int 1
```

## Noise Filtering

The script automatically filters background noise at three levels so you only see meaningful preference changes:

1. **Domain exclusions** (40+ patterns) — background daemons, cloud sync, telemetry, MDM internals
2. **Per-key filtering** — within useful domains (Dock, Finder, Spotlight), noisy keys like timestamps, window positions, and counters are filtered while preference keys are kept
3. **Global patterns** — `NSWindow Frame*`, `*timestamp*`, `*Cache*`, `*UUID*`, hash keys, etc.

Use `-v` (verbose) to see everything including filtered keys. Use `--exclude` to add your own exclusions.

## Jamf Pro Integration

The script auto-detects Jamf mode when called with positional parameters:

```bash
# $4: Domain (ALL or specific)
# $5: Log file path
# $6: Include system preferences (true/false)
# $7: Only show commands (true/false)
# $8: Excluded domains (comma-separated globs)
```

In Jamf mode: auto-launches Console.app for live viewing, stops when Console is closed, reads the logged-in user's preferences via `sudo -u`, and logs to stdout + file + syslog.

## Known Limitations

**Not detectable** (not stored in plist files):
- Finder sidebar favorites (`.sfl2` binary)
- Finder per-folder view settings (`.DS_Store`)
- TCC permissions — Camera, Microphone, etc. (SQLite, SIP-protected)
- Modern Login Items (Background Task Management framework)

**Partial detection:**
- Keyboard shortcuts in ALL mode — use domain mode instead: `./watch-preferences.sh com.apple.symbolichotkeys -v`
- Python 3 required for array/dict changes — without it, only scalar changes are detected

## License

MIT License — see [LICENSE](LICENSE).

## Links

- [CHANGELOG.md](CHANGELOG.md) — full version history
- [Issues](https://github.com/Gill0o/Watch-preferences/issues) — bug reports
- [Discussions](https://github.com/Gill0o/Watch-preferences/discussions) — questions

---

**Built for macOS system administrators and Jamf Pro workflows.**
