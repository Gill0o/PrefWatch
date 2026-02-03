# Watch Preferences

![Version](https://img.shields.io/badge/version-2.4.0-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)

A powerful macOS shell script for monitoring and capturing system preference changes in real-time. Perfect for system administrators, IT professionals, and anyone managing macOS configurations with Jamf Pro or other MDM solutions.

## 🎯 Purpose

**Watch Preferences** monitors macOS preference domains (plist files) and automatically generates executable `defaults` commands that can be used to reproduce the same configuration changes on other machines. This is invaluable for:

- Creating Jamf Pro configuration profiles
- Documenting user preference changes
- Replicating configurations across multiple Macs
- Troubleshooting preference-related issues
- Learning which preferences control specific UI behaviors

## ✨ Key Features

- **Real-time monitoring** of preference changes using multiple detection methods
- **Automatic command generation** for `defaults write`, `defaults delete`, and array operations
- **PlistBuddy alternatives** for complex dictionary and array operations
- **Smart filtering** to exclude noisy system preferences
- **ALL mode** to monitor all preference domains simultaneously
- **Comprehensive logging** with timestamps and change details
- **Type detection** for strings, booleans, integers, floats, arrays, and dictionaries
- **Array change tracking** including additions and deletions with correct indexing
- **ByHost preferences support** with automatic `-currentHost` flag detection

## 📋 Requirements

- macOS 10.14 or later
- Bash or Zsh shell
- Standard macOS utilities: `defaults`, `plutil`, `PlistBuddy`, `fs_usage`

## 🚀 Quick Start

### Basic Usage (CLI Mode)

Monitor ALL preference domains (default behavior):
```bash
./watch-preferences.sh              # Monitor all domains (quiet mode)
./watch-preferences.sh -v           # Monitor all with verbose output
./watch-preferences.sh --log /tmp/all.log  # Monitor all with custom log
```

Monitor a specific preference domain:
```bash
./watch-preferences.sh com.apple.dock
./watch-preferences.sh com.apple.finder -v
```

With custom log file and verbose output:
```bash
./watch-preferences.sh com.apple.finder --log /tmp/finder.log --verbose
# Or using short flags:
./watch-preferences.sh com.apple.finder -l /tmp/finder.log -v
```

Monitor with system preferences excluded and custom exclusions:
```bash
./watch-preferences.sh --no-system --exclude "com.apple.Safari*,com.adobe.*"
# Or using short flags:
./watch-preferences.sh --no-system -e "com.apple.Safari*,com.adobe.*"
```

Show help and available options:
```bash
./watch-preferences.sh --help
```

### With Jamf Pro (Automatic Detection)

When run via Jamf Pro, the script automatically detects Jamf mode and uses parameters starting at $4:

```bash
# Jamf Pro automatically passes $1=mount_point, $2=computer_name, $3=username
# Your parameters start at $4:
# $4: Domain (ALL or specific domain like com.apple.dock)
# $5: Log file path (optional, auto-generated if not specified)
# $6: Include system preferences (true/false, default: true)
# $7: Only show commands (true/false, default: true)
# $8: Excluded domains (glob patterns, comma-separated)

# Example Jamf policy script:
#!/bin/zsh
/path/to/watch-preferences.sh ALL "" true false "com.apple.Safari*,com.apple.security*"
```

## 📖 Detailed Usage

### CLI Mode Options

**Syntax:** `./watch-preferences.sh [domain] [OPTIONS]`

| Option | Short | Description | Default |
|--------|-------|-------------|---------|
| `[domain]` | — | Preference domain to watch (optional) | `ALL` |
| `--log <path>` | `-l` | Custom log file path | Auto-generated¹ |
| `--include-system` | `-s` | Include system preferences in ALL mode | Enabled |
| `--no-system` | — | Exclude system preferences in ALL mode | — |
| `--verbose` | `-v` | Show detailed debug output with timestamps | — |
| `--only-cmds` | `-q` | Show only executable commands (no debug) | Enabled |
| `--exclude <glob>` | `-e` | Comma-separated glob patterns to exclude | Built-in² |
| `--help` | `-h` | Show help message and exit | — |

**Examples:**
```bash
# Monitor all domains (default)
./watch-preferences.sh
./watch-preferences.sh -v

# Monitor specific domain with verbose output
./watch-preferences.sh com.apple.dock -v

# Monitor all domains, custom log, exclude Safari
./watch-preferences.sh -l /tmp/prefs.log -e "com.apple.Safari*"

# Monitor all user preferences only (no system)
./watch-preferences.sh --no-system

# Show only commands (quiet mode, good for piping)
./watch-preferences.sh --only-cmds
```

¹ **Auto-generated paths:**
- ALL mode: `/var/log/preferences.watch.log`
- Domain mode: `/var/log/<domain>.prefs.log`

² **Built-in exclusions** include noisy system domains like `com.apple.cfprefsd.*`, `com.jamf*`, etc.

### Jamf Pro Mode Parameters

| Parameter | Description | Default | Example |
|-----------|-------------|---------|---------|
| `$4` (DOMAIN) | Preference domain to watch or "ALL" | `ALL` | `com.apple.dock` or `ALL` |
| `$5` (LOG_FILE) | Custom log file path | Auto-generated¹ | `/var/log/custom.log` |
| `$6` (INCLUDE_SYSTEM) | Include system preferences in ALL mode | `true` | `false` |
| `$7` (ONLY_CMDS) | Show only executable commands | `true` | `false` |
| `$8` (EXCLUDE_DOMAINS) | Comma-separated glob patterns to exclude | Built-in² | `"com.apple.Safari*"` |

### Output Examples

**Standard output:**
```bash
[2025-02-03 14:30:15] Change detected in com.apple.dock
[2025-02-03 14:30:15] + persistent-apps:0:tile-data:file-label: "Safari"
[2025-02-03 14:30:15] Cmd: defaults write com.apple.dock persistent-apps -array-add '<dict><key>tile-data</key><dict><key>file-label</key><string>Safari</string></dict></dict>'
```

**Commands-only output** (with `--only-cmds` or `-q`):
```bash
defaults write com.apple.dock persistent-apps -array-add '<dict><key>tile-data</key><dict><key>file-label</key><string>Safari</string></dict></dict>'
defaults write com.apple.HIToolbox AppleEnabledInputSources -array-add '<dict><key>InputSourceKind</key><string>Keyboard Layout</string><key>KeyboardLayout ID</key><integer>252</integer></dict>'
```

## 🔧 Advanced Features

### Excluded Domains (Smart Filtering)

The script automatically excludes noisy system domains that change frequently but are rarely useful:

- `com.apple.cfprefsd.*`
- `com.apple.notificationcenterui.*`
- `com.apple.Spotlight.*`
- `com.apple.security.*`
- And many more...

Add custom exclusions:
```bash
./watch-preferences.sh ALL --exclude "my.custom.domain*,another.domain"
# Or with short flag:
./watch-preferences.sh ALL -e "my.custom.domain*,another.domain"
```

### PlistBuddy Commands

For complex dictionaries and arrays, the script generates both `defaults` and `PlistBuddy` alternatives:

```bash
# defaults command (simpler but sometimes fails with complex types)
defaults write com.apple.HIToolbox AppleEnabledInputSources -array-add '<dict>...</dict>'

# PlistBuddy alternative (more reliable for complex structures)
/usr/libexec/PlistBuddy -c "Add :AppleEnabledInputSources:3:InputSourceKind string 'Keyboard Layout'" ~/Library/Preferences/com.apple.HIToolbox.plist
```

### Array Deletion Warnings

When deleting array elements, the script provides index warnings:

```bash
# WARNING: Array deletion - indices shift after each deletion
# For multiple deletions: execute from HIGHEST index to LOWEST
defaults delete com.apple.HIToolbox ":AppleEnabledInputSources:3"
```

## 📂 Project Structure

```
Watch-preferences/
├── watch-preferences.sh    # Main script (latest version)
├── versions/               # All historical versions
│   ├── latest             # Symlink to current version
│   ├── watch-preferences-v2.4.0.sh
│   └── ...
├── CHANGELOG.md           # Detailed version history
├── release.sh             # Version release helper
├── pre-commit             # Git pre-commit hook
└── README.md              # This file
```

## 🔄 Version Management

This project uses automated versioning:

1. Update version number in [watch-preferences.sh](watch-preferences.sh) header
2. Update [CHANGELOG.md](CHANGELOG.md) with changes
3. Commit: the pre-commit hook automatically creates a versioned copy
4. Tag: `git tag -a watch-preferences-v2.4.0 -m "Version 2.4.0"`

## 🤝 Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

### Development Workflow

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make your changes
4. Update CHANGELOG.md
5. Commit and push
6. Create a Pull Request

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🐛 Issues and Support

- Report bugs via [GitHub Issues](https://github.com/Gill0o/Watch-preferences/issues)
- For questions, use [GitHub Discussions](https://github.com/Gill0o/Watch-preferences/discussions)

## 🙏 Acknowledgments

- Built for the macOS system administration community
- Optimized for Jamf Pro workflows
- Inspired by the need to document and replicate user preferences

## 📊 Version History

Current version: **2.4.0** (2025-02-03)

See [CHANGELOG.md](CHANGELOG.md) for complete version history.

### Recent Changes

- Complete code refactoring into 10 clearly defined sections
- Full English translation (internationalization)
- Improved readability with visual separators
- Maintained 100% backward compatibility

---

**Made with ❤️ for macOS system administrators**
