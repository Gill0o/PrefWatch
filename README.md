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

### Basic Usage

Monitor a specific preference domain:
```bash
./watch-preferences.sh com.apple.dock
```

Monitor ALL preference domains (recommended):
```bash
./watch-preferences.sh ALL
```

### With Jamf Pro Parameters

```bash
# $4: Domain (ALL or specific domain like com.apple.dock)
# $5: Timeout in seconds (0 = infinite)
# $6: Include system preferences (true/false, default: true)
# $7: Only show commands (true/false, default: false)
# $8: Excluded domains (glob patterns, comma-separated)

./watch-preferences.sh ALL 300 true false "com.apple.Safari*,com.apple.security*"
```

## 📖 Detailed Usage

### Parameters

| Parameter | Description | Default | Example |
|-----------|-------------|---------|---------|
| `$1` (DOMAIN) | Preference domain to watch or "ALL" | Required | `com.apple.dock` or `ALL` |
| `$2` (TIMEOUT) | Monitoring duration in seconds (0 = infinite) | 0 | `300` |
| `$3` (LOG_FILE) | Custom log file path | Auto-generated | `/tmp/my-log.log` |
| `$4` (Reserved) | Reserved for future use | - | - |
| `$5` (Reserved) | Reserved for future use | - | - |
| `$6` (INCLUDE_SYSTEM) | Include system preferences in ALL mode | `true` | `false` |
| `$7` (ONLY_CMDS) | Show only executable commands (no timestamps) | `false` | `true` |
| `$8` (EXCLUDE_DOMAINS) | Comma-separated glob patterns to exclude | Built-in defaults | `"com.apple.Safari*"` |

### Output Examples

**Standard output:**
```bash
[2025-02-03 14:30:15] Change detected in com.apple.dock
[2025-02-03 14:30:15] + persistent-apps:0:tile-data:file-label: "Safari"
[2025-02-03 14:30:15] Cmd: defaults write com.apple.dock persistent-apps -array-add '<dict><key>tile-data</key><dict><key>file-label</key><string>Safari</string></dict></dict>'
```

**Commands-only output** (with `ONLY_CMDS=true`):
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
./watch-preferences.sh ALL 0 "" "" "" true false "my.custom.domain*,another.domain"
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

- Report bugs via [GitHub Issues](https://github.com/YOUR_USERNAME/Watch-preferences/issues)
- For questions, use [GitHub Discussions](https://github.com/YOUR_USERNAME/Watch-preferences/discussions)

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
