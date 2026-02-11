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

# Keyboard shortcuts → PlistBuddy
/usr/libexec/PlistBuddy -c 'Set :AppleSymbolicHotKeys:32:value:parameters:1 122' ~/Library/Preferences/com.apple.symbolichotkeys.plist

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
- **Contextual notes** — actionable comments with each command (`killall Dock`, `logout/login required`, human-readable values)
- **ByHost auto-detection** — automatically adds `-currentHost` for per-hardware preferences (trackpad, Bluetooth)
- **Noise filtering** — 40+ domain exclusions and global key patterns to surface only real changes
- **Minimal dependencies** — single zsh script + Python 3 (for array/dict detection)

## Quick Start

```bash
# Monitor all preferences (requires sudo)
sudo ./prefwatch.sh

# Monitor a specific domain (no sudo, lower CPU)
./prefwatch.sh com.apple.dock

# Verbose mode
sudo ./prefwatch.sh -v
```

## Requirements

- macOS 10.14+ (primarily tested on Tahoe, partially on Sonoma)
- Python 3 for array/dict detection (`xcode-select --install` if missing)
- `sudo` required for ALL mode (`fs_usage`)

## Usage

**ALL mode** (default) — monitors all domains via `fs_usage` + polling. Requires sudo.

```bash
sudo ./prefwatch.sh
```

**Domain mode** — monitors a single domain via mtime polling. No sudo needed.

```bash
./prefwatch.sh com.apple.dock
```

| Option | Short | Description | Default |
|--------|-------|-------------|---------|
| `[domain]` | -- | Domain to monitor | `ALL` |
| `--verbose` | `-v` | Show diffs and debug info | Off |
| `--log <path>` | `-l` | Custom log file path | Auto |
| `--no-system` | -- | Exclude `/Library/Preferences` | Include |
| `--exclude <glob>` | `-e` | Domain patterns to exclude | Built-in |
| `--only-cmds` | `-q` | Show only executable commands | On |

## Jamf Pro Integration

Auto-detects Jamf mode when called with positional parameters (`$4`=domain, `$5`=log path, `$6`=include system, `$7`=only cmds, `$8`=exclusions). Launches Console.app for live viewing, logs to stdout + file + syslog.

## Known Limitations

**Not detectable**
- Finder sidebar favorites (`.sfl2` binary), per-folder views (`.DS_Store`)
- TCC permissions — Camera, Microphone, etc. (SQLite, SIP-protected)
- Modern Login Items (Background Task Management framework)
- Wallpaper (`desktoppicture.db` SQLite, since Ventura)
- Screen Time (SQLite)
- Firewall rules (`socketfilterfw`)
- Keychain / Wi-Fi passwords (`security`)
- FileVault status (APFS metadata, `fdesetup`)
- Startup Disk (`nvram` / `bless`)
- Focus / Do Not Disturb (assertion-based + SQLite)
- User accounts (Directory Services, `dscl`)
- Safari bookmarks, history, extensions (`~/Library/Safari/`, not preferences)
- Bluetooth on/off (IOBluetooth daemon, runtime state)
- Computer name (`scutil`, SystemConfiguration framework)
- iPhone widgets on Mac (WidgetKit, iCloud sync)
- Default browser / email app (LaunchServices API, excluded as noise)
- Touch ID fingerprints (Secure Enclave, `bioutil`)

**Partial:**
- Keyboard shortcuts — use domain mode: `./prefwatch.sh com.apple.symbolichotkeys -v`

## License

MIT — see [LICENSE](LICENSE).

---

[CHANGELOG](CHANGELOG.md) · [Issues](https://github.com/Gill0o/PrefWatch/issues) · [Discussions](https://github.com/Gill0o/PrefWatch/discussions)
