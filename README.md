# Watch Preferences

![Version](https://img.shields.io/badge/version-2.9.25--beta-orange.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)
![Shell](https://img.shields.io/badge/shell-zsh-blue.svg)
![Status](https://img.shields.io/badge/status-BETA-orange.svg)

A macOS shell script that monitors preference domains (plist files) in real-time and generates executable commands (`defaults write` / `PlistBuddy`) to reproduce configuration changes on other machines. Built for Jamf Pro workflows and macOS system administration.

## What It Does

1. You run the script
2. You change a setting in System Settings, Finder, Dock, or any app
3. The script outputs the exact command to reproduce that change

```
$ ./watch-preferences.sh com.apple.dock -v
[2026-02-05 14:30:15] Diff com.apple.dock: + "orientation" => "left"
[2026-02-05 14:30:15] Cmd: defaults write com.apple.dock "orientation" -string "left"
```

## Requirements

- macOS 10.14+ (tested on Sonoma & Tahoe)
- Zsh (default macOS shell since Catalina)
- Python 3 (recommended, for array/dict change detection). Install Command Line Tools if missing: `xcode-select --install`
- Standard macOS utilities: `defaults`, `plutil`, `PlistBuddy`, `fs_usage`
- ALL mode requires `sudo` (for `fs_usage`)

## Quick Start

```bash
# Monitor ALL preference domains (requires sudo for fs_usage)
sudo ./watch-preferences.sh -v

# Monitor a specific domain (no sudo needed)
./watch-preferences.sh com.apple.dock -v
./watch-preferences.sh com.apple.finder -v
./watch-preferences.sh NSGlobalDomain -v

# Quiet mode: only output executable commands (default)
./watch-preferences.sh com.apple.dock

# Custom log file
./watch-preferences.sh com.apple.dock -l /tmp/dock-changes.log
```

## Two Monitoring Modes

### Domain Mode (recommended for targeted monitoring)

```bash
./watch-preferences.sh com.apple.dock
```

- Monitors a single domain via **mtime polling** (0.5s interval)
- Low CPU (~1-2%)
- No sudo required
- Detects all changes including keyboard shortcuts (`com.apple.symbolichotkeys`)

### ALL Mode (broad discovery)

```bash
sudo ./watch-preferences.sh ALL -v
```

- Monitors **all** preference domains simultaneously
- Uses `fs_usage` (filesystem event tracing) + polling fallback
- Takes an initial snapshot, then reports changes as they happen
- Higher CPU (~5-10% during changes)
- Requires sudo for `fs_usage`

## CLI Options

| Option | Short | Description | Default |
|--------|-------|-------------|---------|
| `[domain]` | -- | Preference domain to monitor | `ALL` |
| `--verbose` | `-v` | Show diff details, key names, and commands | Off (quiet) |
| `--log <path>` | `-l` | Custom log file path | Auto-generated |
| `--no-system` | -- | Exclude `/Library/Preferences` in ALL mode | Include |
| `--exclude <glob>` | `-e` | Comma-separated domain patterns to exclude | Built-in list |
| `--only-cmds` | `-q` | Show only executable commands | On (default) |
| `--help` | `-h` | Show help | -- |

## Output Format

### Scalar values: `defaults write`

For simple key-value changes (strings, booleans, integers, floats):

```bash
defaults write com.apple.dock "orientation" -string "left"
defaults write com.apple.dock "tilesize" -int 48
defaults write com.apple.dock "autohide" -bool TRUE
defaults write com.apple.dock "magnification" -float 1.5
```

The script detects the actual plist type via `defaults read-type` to avoid misdetection (e.g., a float `1.0` detected as boolean).

### Array operations: `PlistBuddy Add`

For adding items to arrays (Dock icons, keyboard layouts):

```bash
# Adding a keyboard layout
/usr/libexec/PlistBuddy -c 'Add :AppleEnabledInputSources:3 dict' ~/Library/Preferences/com.apple.HIToolbox.plist
/usr/libexec/PlistBuddy -c 'Add :AppleEnabledInputSources:3:InputSourceKind string Keyboard Layout' ~/Library/Preferences/com.apple.HIToolbox.plist
/usr/libexec/PlistBuddy -c 'Add :AppleEnabledInputSources:3:KeyboardLayout ID integer 252' ~/Library/Preferences/com.apple.HIToolbox.plist
```

### Nested dict changes: `PlistBuddy Set`

For changes inside nested dictionaries (keyboard shortcuts in `symbolichotkeys`):

```bash
# Changing a keyboard shortcut key binding
/usr/libexec/PlistBuddy -c 'Set :AppleSymbolicHotKeys:32:value:parameters:1 122' ~/Library/Preferences/com.apple.symbolichotkeys.plist
```

### Array deletions: `PlistBuddy Delete`

For removing items from arrays (removing a Dock icon, removing a keyboard layout):

```bash
# WARNING: Array deletion - indexes change after each deletion
# For multiple deletions: execute from HIGHEST index to LOWEST
/usr/libexec/PlistBuddy -c 'Delete :persistent-apps:3' ~/Library/Preferences/com.apple.dock.plist
```

### ByHost preferences: `-currentHost`

For per-machine preferences (trackpad, display), the script auto-detects ByHost plists:

```bash
defaults write com.apple.AppleMultitouchTrackpad "ActuateDetents" -currentHost -int 1
defaults write com.apple.AppleMultitouchTrackpad "ForceSuppressed" -currentHost -bool FALSE
```

## Jamf Pro Integration

When run via Jamf Pro, the script auto-detects Jamf mode (positional parameters):

```bash
# $1-$3: Reserved by Jamf (mount_point, computer_name, username)
# $4: Domain (ALL or specific, e.g. com.apple.dock)
# $5: Log file path (optional)
# $6: Include system preferences (true/false, default: true)
# $7: Only show commands (true/false, default: true)
# $8: Excluded domains (comma-separated glob patterns)
```

Features specific to Jamf workflows:
- Auto-launches **Console.app** with the log file for real-time viewing
- Stops monitoring when Console.app is closed
- Runs as root with `sudo -u` to read the console user's preferences
- Triple logging: stdout + log file + `syslog` (`/usr/bin/logger`)

## Intelligent Noise Filtering

The script filters at three levels to keep output clean:

### 1. Domain exclusions (40+ patterns)

Entire domains that produce only background noise:

| Category | Examples |
|----------|----------|
| Background daemons | `com.apple.cfprefsd*`, `com.apple.notificationcenterui*`, `ContextStoreAgent*` |
| Cloud sync | `com.apple.CloudKit*`, `com.apple.bird`, `com.apple.cloudd` |
| Event counters | `com.apple.cseventlistener`, `com.apple.spotlightknowledge`, `com.apple.amsengagementd` |
| Telemetry observers | `com.apple.suggestions.*Observer*`, `com.apple.personalizationportrait.*Observer*` |
| MDM internals | `com.jamf*`, `com.jamfsoftware*` |
| Third-party updaters | `com.microsoft.autoupdate*`, `*.zoom.updater*` |

### 2. Per-key intelligent filtering

Domains with useful *and* noisy keys are filtered at key level:

| Domain | Filtered (noise) | Kept (useful) |
|--------|-------------------|---------------|
| `com.apple.dock` | `workspace-*`, `mod-count`, `GUID`, `lastShowIndicatorTime` | `orientation`, `autohide`, `tilesize`, `persistent-apps` |
| `com.apple.finder` | `FXRecentFolders`, `GoToField*`, `name` | `ShowPathbar`, `FXPreferredViewStyle`, `AppleShowAllFiles` |
| `com.apple.HIToolbox` | `AppleSavedCurrentInputSource` (transient switch) | `AppleEnabledInputSources` (layout additions) |
| `com.apple.Spotlight` | `engagementCount*`, `lastWindowPosition`, `NSStatusItem*` | `EnabledPreferenceRules`, `orderedItems` |
| `com.apple.controlcenter` | `NSStatusItem*` (UI positioning) | Preference toggles |

### 3. Global noisy patterns

Applied to all domains: `NSWindow Frame*`, `*timestamp*`, `*LastUpdate*`, `*Cache*`, `*UUID*`, `*RecentFolders`, SHA256 hash keys, `ALL_CAPS_FEATURE_FLAGS`, etc.

Override with `--exclude` to use only your custom exclusions, or use `-v` (verbose) to see filtered keys.

## Tested Categories

Systematically tested on macOS Tahoe (26.x):

| Category | Tested | Status |
|----------|--------|--------|
| **Dock**: position, size, magnification, auto-hide, add/remove icons | `com.apple.dock` | Working |
| **Finder**: default view style (list/column/gallery/icon), show path bar, show status bar | `com.apple.finder` | Working |
| **Mission Control**: auto-rearrange spaces, group windows by app | `com.apple.dock` | Working |
| **Keyboard layouts**: add/remove input sources | `com.apple.HIToolbox` | Working |
| **Keyboard shortcuts**: custom key bindings (symbolichotkeys) | `com.apple.symbolichotkeys` | Working (domain mode) |
| **Trackpad**: force click, three-finger tap, actuate detents | `com.apple.AppleMultitouchTrackpad` | Working |
| **Accessibility**: reduce transparency, increase contrast, reduce motion | `com.apple.universalaccess` | Working |
| **Safari, Mail, third-party apps** | Various | Working |
| **Spotlight**: search categories (EnabledPreferenceRules) | `com.apple.Spotlight` | Partial |

## Known Limitations

### Not Detectable (not plist-based)

| What | Storage | Why |
|------|---------|-----|
| **Finder sidebar favorites** | `.sfl2` binary format | Not a plist file |
| **Finder per-folder view settings** | `.DS_Store` files | Not a plist file |
| **TCC permissions** (Camera, Microphone, etc.) | SQLite database (`TCC.db`) | Protected by SIP |
| **Login Items** (modern) | Background Task Management framework | Not plist-based |

### Partial Detection

| What | Issue | Workaround |
|------|-------|------------|
| **Keyboard shortcuts** in ALL mode | `fs_usage` doesn't always catch `symbolichotkeys` writes | Use domain mode: `./watch-preferences.sh com.apple.symbolichotkeys -v` |
| **Spotlight "associated content"** toggle | macOS writes to different domains for enable vs disable (asymmetric) | Deletion detected, re-enable detected via different domain |
| **Display resolution** | ByHost plist detected but domain is noisy (`com.apple.windowserver`) | Filtered by default |

### System Requirements

- **SIP**: Can be enabled (recommended)
- **Full Disk Access**: Required for some system preferences in ALL mode
- **Python 3**: Required for array/dict change detection. Without it, only scalar changes are detected.

## Architecture

```
watch-preferences.sh (2300 lines, zsh)
├── CLI / Jamf argument parsing
├── Domain exclusion engine (glob patterns, cached)
├── Intelligent key filtering (is_noisy_key: global + per-domain patterns)
├── Plist manipulation (plutil + Python plistlib fallback for NSData)
├── PlistBuddy command generation
│   ├── Add (array additions — emit_array_additions)
│   ├── Set (nested dict changes — emit_nested_dict_changes)
│   └── Delete (array deletions — emit_array_deletions)
├── JSON diff engine (Python, embedded)
│   ├── Array element matching (unordered comparison)
│   ├── Recursive leaf change detection (nested dicts)
│   └── _skip_keys metadata (prevents duplicate defaults write)
├── Monitoring
│   ├── Domain mode: mtime polling (stat -f %m, 0.5s)
│   └── ALL mode: fs_usage + find -newer polling
└── Logging (stdout + file + syslog)
```

## Project Structure

```
Watch-preferences/
├── watch-preferences.sh    # Main script (latest version)
├── versions/               # All historical versions
│   ├── latest              # Symlink to current version
│   └── watch-preferences-v2.9.*.sh
├── CHANGELOG.md            # Detailed version history
├── release.sh              # Version release helper
├── pre-commit              # Git pre-commit hook
└── README.md
```

## Version Management

1. Update version in `watch-preferences.sh` header
2. Update `CHANGELOG.md`
3. Commit: the pre-commit hook automatically creates a versioned copy in `versions/`
4. Optionally tag: `git tag -a watch-preferences-v2.9.25 -m "Version 2.9.25-beta"`

## License

MIT License - see [LICENSE](LICENSE).

## Issues and Support

- Report bugs: [GitHub Issues](https://github.com/Gill0o/Watch-preferences/issues)
- Questions: [GitHub Discussions](https://github.com/Gill0o/Watch-preferences/discussions)

## Version History

Current version: **2.9.25-beta** (2026-02-05)

See [CHANGELOG.md](CHANGELOG.md) for complete version history.

### Recent Changes

- **v2.9.25**: Extended noise filtering (cseventlistener, spotlightknowledge, controlcenter, HIToolbox)
- **v2.9.24**: Intelligent Spotlight filtering, Observer domain exclusions
- **v2.9.23**: Fix `_skip_keys` subshell bug (process substitution)
- **v2.9.22**: Nested dict change detection (`PlistBuddy Set` for symbolichotkeys)
- **v2.9.20**: PlistBuddy-only for deletions (removed redundant `defaults delete`)
- **v2.9.19**: Instant detection on startup (baseline snapshot before polling)

---

**Built for macOS system administrators and Jamf Pro workflows.**
