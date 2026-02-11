# PrefWatch

![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)
![Shell](https://img.shields.io/badge/shell-zsh-blue.svg)

A macOS monitoring tool that watches preference changes in real-time and generates the exact `defaults write` or `PlistBuddy` commands to reproduce them.

```bash
sudo ./prefwatch.sh
```

The script monitors **all** preference domains and outputs only executable commands:

```
# Simple settings → defaults write
defaults write com.apple.finder "FXPreferredViewStyle" -string "clmv"
defaults write com.apple.dock "autohide" -bool TRUE
defaults write NSGlobalDomain "AppleShowAllExtensions" -bool TRUE

# Complex changes (Dock icons, keyboard layouts) → PlistBuddy
/usr/libexec/PlistBuddy -c 'Add :persistent-apps:5 dict' ~/Library/Preferences/com.apple.dock.plist
/usr/libexec/PlistBuddy -c 'Add :persistent-apps:5:tile-data:bundle-identifier string com.apple.Safari' ~/Library/Preferences/com.apple.dock.plist
```

Change Finder view, add an app to the Dock, flip a trackpad setting — every change becomes a copy-paste command. The script automatically picks `defaults write` or `PlistBuddy` depending on the type of change.

## Key Features

- **Zero dependencies** — single zsh script, no package manager, no Python runtime required for basic use
- **ALL mode** — discover which domain changed without knowing in advance (`fs_usage` + polling)
- **Full type coverage** — scalars (`defaults write`), arrays, nested dicts, and array deletions (`PlistBuddy`)
- **ByHost auto-detection** — automatically adds `-currentHost` for per-hardware preferences (trackpad, Bluetooth)
- **Noise filtering** — 40+ domain exclusions and global key patterns so you only see real preference changes
- **Jamf Pro native** — runs as a Jamf policy with positional parameters, Console.app live view, syslog output
- **CUPS printer monitoring** *(beta)* — detects printer add/remove and emits `lpadmin` commands

## Quick Start

```bash
# Monitor all preferences (recommended first use)
sudo ./prefwatch.sh

# Verbose mode: see diffs and key names
sudo ./prefwatch.sh -v

# Monitor a specific domain (no sudo, lower CPU)
./prefwatch.sh com.apple.dock
./prefwatch.sh com.apple.finder

# Custom log file
./prefwatch.sh com.apple.dock -l /tmp/dock-changes.log
```

## Requirements

- macOS 10.14+ (tested on Sonoma and Tahoe)
- Python 3 for array/dict detection (`xcode-select --install` if missing)
- `sudo` required for ALL mode (`fs_usage`)

## Monitoring Modes

**ALL mode** (default) — monitors all preference domains using `fs_usage` + polling. Requires sudo. Best for discovery: "I changed something, what domain was it?"

```bash
sudo ./prefwatch.sh
```

**Domain mode** — monitors a single domain via mtime polling (0.5s). Low CPU, no sudo. Best when you know which domain to watch.

```bash
./prefwatch.sh com.apple.dock
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

## Experimental Features

The following features are included but considered **beta** — they may change in future versions:

- **CUPS printer monitoring** (`cups_watch`) — detects printer add/remove in ALL mode, emits `lpadmin` commands
- **Print preset filtering** (`com.apple.print.custompresets*`) — filters Fiery driver defaults, keeps useful keys (Duplex, PageSize, ColorMode, etc.)
- **Energy/Battery monitoring** (`pmset_watch`) — detects power setting changes in ALL mode, emits `pmset -b`/`-c` commands

## Known Limitations

**Not detectable** (not stored in plist files):
- Finder sidebar favorites (`.sfl2` binary)
- Finder per-folder view settings (`.DS_Store`)
- TCC permissions — Camera, Microphone, etc. (SQLite, SIP-protected)
- Spotlight "Help Apple improve Search" (server-side / CloudKit sync)
- Modern Login Items (Background Task Management framework)

**Partial detection:**
- Keyboard shortcuts in ALL mode — use domain mode instead: `./prefwatch.sh com.apple.symbolichotkeys -v`
- Energy/Battery settings — only in ALL mode (via `pmset` polling), not available in domain mode
- Python 3 required for array/dict changes — without it, only scalar changes are detected

## License

MIT License — see [LICENSE](LICENSE).

## Links

- [CHANGELOG.md](CHANGELOG.md) — full version history
- [Issues](https://github.com/Gill0o/PrefWatch/issues) — bug reports
- [Discussions](https://github.com/Gill0o/PrefWatch/discussions) — questions

---

**Built for macOS system administrators and MDM workflows.**
