# Changelog

## 1.0.1 — 2026-02-13
- **FIX**: Suppress redundant PlistBuddy `Delete` when a `defaults write` follows for the same key — now checks the current snapshot file directly instead of relying on `defaults read` (which fails under sudo)
- **FIX**: Unfilter `NSToolbar Configuration` — show/hide toolbar is a real user preference
- **FIX**: `*PreferencesWindow*` added to noisy key patterns (window position/state)
- **FIX**: `FXRecentFolders` array deletions now filtered via `is_noisy_key` in `emit_array_deletions`
- **UX**: Warning when running ALL mode without sudo (fs_usage unavailable, polling only)
- **UX**: Skip `fs_watch` launch when not root (avoids silent failure)
- **FIX**: Suppress false-positive array additions/deletions on reorder (e.g. Dock `persistent-apps` on app launch) — Python-level length check
- **NOISE**: Exclude domains: `com.apple.wifi.known-networks`, `com.apple.TimeMachine`,
  `com.apple.timemachine*`, `com.apple.powerlogd`, `com.apple.calculateframework`,
  `com.apple.SoftwareUpdate`, `com.apple.apsd`, `com.apple.biometrickitd`,
  `com.apple.appleaccountd`, `com.apple.CacheDelete`, `com.apple.inputAnalytics*`,
  `com.apple.vmnet`, `com.apple.audio.SystemSettings`,
  `com.apple.coreservices.useractivityd*`, `com.apple.AccessibilityHearingNearby`,
  `com.apple.AppStore`, `com.apple.gamed`, `com.apple.gamecenter`,
  `com.apple.appleintelligencereporting`, `com.apple.GenerativeFunctions*`,
  `com.apple.SpeakSelection`, `com.microsoft.office`,
  `com.apple.ServicesMenu.Services`, `com.apple.AddressBook`
- **NOISE**: PlistBuddy filters: `FXRecentFolders`, `NSWindowTabbingShoudShowTabBarKey`,
  `ViewSettings`, `FXSync*`, `MRSActivityScheduler`
- **NOISE**: Key filters: `FK_SidebarWidth*`, `trash-full` (Dock), `*Analytics*`, `*Telemetry*`, `*lastBootstrap*`,
  `*LastLoadedOn*`, `NSLinguisticDataAssets*`, `*.column.*.width`, Sparkle updater keys (`SU*`),
  `uses`, `launchCount`, `*reminder.date`, `*donate*`
- **DOC**: README scope section — Safari and other Apple apps may not use plist-based preferences

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
