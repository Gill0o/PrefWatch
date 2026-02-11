# PrefWatch

![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)
![Shell](https://img.shields.io/badge/shell-zsh-blue.svg)

A macOS monitoring tool that watches preference changes in real-time and generates the exact commands to reproduce them.

```bash
sudo ./prefwatch.sh
```

Change any setting — Dock, Finder, trackpad, keyboard, energy, printers — and PrefWatch outputs the command to reproduce it:

```bash
# Preferences → defaults write
defaults write com.apple.dock "autohide" -bool TRUE

# Dock icons, keyboard layouts → PlistBuddy
# NOTE: Run 'killall Dock' to apply Dock changes
/usr/libexec/PlistBuddy -c 'Add :persistent-apps:5:tile-data:bundle-identifier string com.apple.Safari' ~/Library/Preferences/com.apple.dock.plist

# Energy/Battery → pmset
# Energy: AC Power — powermode changed: Automatic → High Performance
pmset -c powermode 2

# Printers → lpadmin
# CUPS: printer added — HP_LaserJet
lpadmin -p "HP_LaserJet" -v "lpd://192.168.1.50" -m everywhere -E
```

## Key Features

- **Full command coverage** — `defaults write`, `PlistBuddy`, `pmset`, `lpadmin` depending on what changed
- **ALL mode** — discover which domain changed without knowing in advance (`fs_usage` + polling)
- **Contextual notes** — each command includes actionable comments (`killall Dock`, `logout/login required`, human-readable values)
- **ByHost auto-detection** — automatically adds `-currentHost` for per-hardware preferences (trackpad, Bluetooth)
- **Noise filtering** — 40+ domain exclusions and global key patterns so you only see real preference changes
- **Zero dependencies** — single zsh script, Python 3 only needed for array/dict detection
- **Jamf Pro native** — runs as a Jamf policy with positional parameters, Console.app live view, syslog output

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

### Scalar preferences — `defaults write`

```bash
defaults write com.apple.dock "orientation" -string "left"
defaults write com.apple.dock "tilesize" -int 48
defaults write com.apple.dock "autohide" -bool TRUE
defaults write com.apple.finder "FXPreferredViewStyle" -string "clmv"

# ByHost preferences → auto-detected -currentHost flag
defaults write com.apple.AppleMultitouchTrackpad "ActuateDetents" -currentHost -int 1
```

### Arrays and nested dicts — `PlistBuddy`

```bash
# Add a Dock icon
# NOTE: Run 'killall Dock' to apply Dock changes
/usr/libexec/PlistBuddy -c 'Add :persistent-apps:5 dict' ~/Library/Preferences/com.apple.dock.plist
/usr/libexec/PlistBuddy -c 'Add :persistent-apps:5:tile-data:bundle-identifier string com.apple.Safari' ~/Library/Preferences/com.apple.dock.plist

# Add a keyboard layout
# NOTE: Keyboard layout changes require logout/login to take effect
/usr/libexec/PlistBuddy -c 'Add :AppleEnabledInputSources:3 dict' ~/Library/Preferences/com.apple.HIToolbox.plist
/usr/libexec/PlistBuddy -c 'Add :AppleEnabledInputSources:3:InputSourceKind string Keyboard\ Layout' ~/Library/Preferences/com.apple.HIToolbox.plist
/usr/libexec/PlistBuddy -c 'Add :AppleEnabledInputSources:3:KeyboardLayout\ Name string French' ~/Library/Preferences/com.apple.HIToolbox.plist

# Keyboard shortcut change
/usr/libexec/PlistBuddy -c 'Set :AppleSymbolicHotKeys:32:value:parameters:1 122' ~/Library/Preferences/com.apple.symbolichotkeys.plist

# Remove a Dock icon
# WARNING: for multiple deletions, execute from HIGHEST index to LOWEST
/usr/libexec/PlistBuddy -c 'Delete :persistent-apps:3' ~/Library/Preferences/com.apple.dock.plist
```

### Energy/Battery — `pmset`

```bash
# Energy: AC Power — powermode changed: Automatic → High Performance
pmset -c powermode 2

# Energy: Battery Power — displaysleep changed: 5 min → 10 min
pmset -b displaysleep 10

# Energy: Battery Power — powernap changed: On → Off
pmset -b powernap 0
```

### Printers — `lpadmin`

```bash
# CUPS: printer added — HP_LaserJet
lpadmin -p "HP_LaserJet" -v "lpd://192.168.1.50" -m everywhere -E

# CUPS: printer removed — Old_Printer
lpadmin -x "Old_Printer"
```

## Noise Filtering

The script automatically filters background noise at three levels:

1. **Domain exclusions** (40+ patterns) — background daemons, cloud sync, telemetry, MDM internals
2. **Per-key filtering** — within useful domains (Dock, Finder, Spotlight), noisy keys like timestamps, window positions, and counters are filtered
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
- **Energy/Battery monitoring** (`pmset_watch`) — detects power setting changes in ALL mode, emits `pmset -b`/`-c` commands with human-readable labels

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
