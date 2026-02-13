# Changelog

## 1.0.1 — 2026-02-13
- **NOISE**: Exclude `com.apple.wifi.known-networks` (WiFi timestamp updates)
- **NOISE**: Exclude `com.apple.TimeMachine` (backup state internals)
- **NOISE**: Exclude `com.apple.powerlogd` (energy daemon)

## 1.0.0 — 2026-02-12
- **RELEASE**: First official release as **PrefWatch**
  - Renamed project from Watch Preferences to PrefWatch
  - Updated all references: script, README, LICENSE, CI, GitHub templates
  - GitHub repo renamed to `Gill0o/PrefWatch`
- **FEATURE**: Contextual `# NOTE:` comments in output for keyboard layouts (logout/login required) and Dock changes (`killall Dock`)
- **FEATURE**: Energy/Battery monitoring via `pmset_watch()` — polls `pmset -g custom`, emits `pmset -b`/`-c` commands (ALL mode only, beta)
- **UX**: Snapshot progress — spinner + counter in terminal, clear messages in Console.app
- **UX**: Python3 preflight — ALL mode prompts user if Xcode CLT/Python3 is missing
  - Warns about limited detection, offers to continue or abort with install instructions
  - No Xcode CLT popup on fresh macOS (checks `xcode-select -p` before running `/usr/bin/python3`)
- **FIX**: PlistBuddy paths with spaces (e.g. `KeyboardLayout Name`) now escaped via `pb_escape()`
- **FIX**: PlistBuddy string values no longer wrapped in single quotes (conflicted with shell `-c` quoting)
- **FIX**: PBCMD `Add` commands no longer filtered by `is_noisy_key`
- **NOISE**: 40+ domain exclusions and global key patterns to surface only real changes
- **NOISE**: PlistBuddy filters: `FXRecentFolders`, `NSWindowTabbingShoudShowTabBarKey`, `ViewSettings`, `NSToolbar Configuration`, `NSWindow Frame`, and more
- **NOTE**: CUPS printer monitoring and print preset filtering are **experimental (beta)**

## 0.x — 2025-09 to 2026-02
- Internal beta development (formerly Watch Preferences v0.1.0 through v0.3.2-beta)
- Full history available in git log
