# Changelog

## 1.1.1 — unreleased

### Noise
- Exclude `com.apple.protectedcloudstorage*` (CloudKit keychain sync)
- Exclude `com.apple.DataDeliveryServices` (metadata sync timestamps)
- Exclude `com.apple.ReportCrash` (crash reporter TrialCache timestamps)
- Exclude `com.apple.homeenergyd` (HomeKit CloudKit sync cache)
- Filter `WebKitUseSystemAppearance` (Settings panel WebKit artifact)

### Fix
- Detect sub-key additions and deletions in nested dicts (e.g. Finder toolbar customization `NSToolbar Configuration`)
- Replace entire array on change within nested dicts (Delete + Add from scratch) — MDM-deployable, no index dependency
- Deduplicate contextual `# NOTE:` across handlers (was emitted twice in ALL mode)

### UX
- Add post-snapshot notice about cfprefsd cache stabilization delay
## 1.1.0 — 2026-02-17

### Performance
- Eliminate double-scan: pre-initialize poll markers after snapshot — prevents `poll_watch` from rescanning all plists on first iteration
- Parallel initial snapshot: up to 16 concurrent plist snapshots (text + JSON) instead of sequential processing
- Parallel `dump_plist` + `dump_plist_json` on change detection — both plutil calls run concurrently
- Cache `hash_path()` results in associative array — avoids repeated `/sbin/md5` forks for the same path
- Reduce polling interval from 2s to 1s — halves worst-case change detection latency
- Immediate first poll cycle after snapshot — no initial sleep delay

### Fix
- Dock icon add/remove: `bundle-identifier`, `_CFURLString`, `file-label` no longer filtered in PlistBuddy commands — app name and path now visible in output
- Print presets: detect new top-level dict settings and emit full PlistBuddy `Add` tree — reproduces complete preset via terminal
- Print presets: emit `Add :array_name array` when array is new (e.g. `customPresetsInfo`)
- PlistBuddy `pb_type_value()`: use `true/false` for bools (was `YES/NO` — invalid for PlistBuddy)
- Parallel snapshot: fix invalid `shift _snap_pids` zsh syntax — use array slice instead
- Poll watch: remove dead `_poll_first` flag and stale `$now` variable reference

### Feature
- Contextual `# NOTE:` for print preset changes (logout/login required to apply)
- Contextual `# NOTE:` for keyboard shortcut changes (`com.apple.symbolichotkeys`)
- Dock icon add/remove: emit `# Dock: AppName (bundle-id)` comment for readability
- Dock icon remove: emit `# Dock: removed AppName` comment
- Keyboard shortcuts (`AppleSymbolicHotKeys`) now detected in ALL mode via `emit_nested_dict_changes`

### Noise
- Exclude `com.apple.homed` (HomeKit generation counters)
- Exclude `com.apple.classroom`, `com.apple.mediaanalysisd`, `com.apple.financed`, `com.apple.biomesyncd`, `com.apple.madrid`
- Dock: filter `recent-apps` in both `is_noisy_key` and PBCMD handler
- Print presets: filter Fiery/PPD driver defaults (`*EF*` keys, `vendorDefaultSettings`, `PaperInfo` subtree) — keep only useful settings (PageSize, Duplex, ColorMode, etc.)
- PBCMD handler: filter Dock tile internals (`GUID`, `dock-extra`, `is-beta`, `file-type`, `tile-type`, `*-mod-date`)
- PBCMD handler: fix `<data:` filter (remove stale single-quote prefix)
- PBCMD handler: sync both handlers (show_plist_diff + show_domain_diff)
- Print preset `# NOTE:` emitted once before commands (was duplicated for array + dict)

## 1.0.4 — 2026-02-16

### Fix
- Suppress false `defaults write` for nested dict keys (e.g. ColorSync ICC profiles) — only top-level keys produce valid commands
- PlistBuddy string values no longer wrapped in single quotes — fixes broken commands when values contain spaces (e.g. ICC profile paths)

### Noise
- Exclude domains: `com.apple.SafariCloudHistoryPushAgent`, `NetworkInterfaces`,
  `com.apple.dhcp6d`, `com.teamviewer*`, `com.apple.QuickLookDaemon`,
  `com.microsoft.OneDriveUpdater`, `com.apple.itunescloudd`,
  `com.apple.commcenter*`, `com.apple.AdPlatforms`
- Key filters: `*HeartbeatDate*` (WindowManager, controlcenter telemetry),
  Finder `FXConnectToBounds`, `SearchRecentsSavedViewStyle`

### Feature
- Contextual `# NOTE:` for ColorSync ICC profile changes (logout/login required)
- Contextual `# NOTE:` for simple key changes (Dock, etc.)

## 1.0.3 — 2026-02-15

### Fix
- Print preset deletion now detected (`customPresetsInfo` array was incorrectly filtered as noisy)
- CUPS printer monitoring — debounce 5s to filter DNS-SD/Bonjour false positives

### Noise
- Exclude domains: `com.apple.networkd`, `com.apple.AutoWake`,
  `com.apple.siri.DialogEngine`, `com.apple.siri.sirisuggestions`, `com.apple.siriknowledged`,
  `com.bjango.istatmenus.status`, `app.monitorcontrol.MonitorControl`,
  `com.apple.settings.Storage`, `com.apple.iCal`,
  `com.apple.icloud.searchpartyuseragent`, `com.apple.rapport`,
  `com.apple.IMCoreSpotlight`, `com.apple.identityservicesd`, `com.apple.imagent`
- PlistBuddy filter: `com.apple.finder.SyncExtensions` (Finder Sync/Time Machine dirMap)
- Key filters: UUID-formatted key names, `feature.*` flags,
  `closeViewZoom*FocusFollowMode*`, Terminal `TTAppPreferences Selected Tab`

### UX
- All temp files consolidated under `/tmp/prefwatch.PID/` with cleanup on exit

## 1.0.2 — 2026-02-14

### Fix
- Suppress `plutil -convert json` error messages visible on Sonoma during snapshot — plutil with `-o` flag writes errors to stdout (not stderr), now both suppressed (`>/dev/null 2>&1`)
- PlistBuddy `Add`/`Set` commands now escape spaces in key names (e.g. `KeyboardLayout\ Name`) — fixes "Unrecognized Type" errors for keys like `KeyboardLayout Name`
- Dock reorder no longer produces false `defaults write` for tile metadata (`bundle-identifier`, `_CFURLString`, `file-label`, etc.)

### Noise
- Exclude domains: `com.apple.MobileSMSPreview`, `com.apple.ncprefs`,
  `com.apple.accounts.exists`, `com.apple.icloud.fmfd`, `com.apple.TelephonyUtilities`,
  `com.apple.TV`, `com.apple.Music`, `com.apple.itunescloud`, `com.apple.findmy*`,
  `com.apple.bookdatastored`
- Key filters: `*WindowFrame*`, `*DidMigrate*`

## 1.0.1 — 2026-02-13

### Fix
- Suppress redundant PlistBuddy `Delete` when a `defaults write` follows for the same key — now checks the current snapshot file directly instead of relying on `defaults read` (which fails under sudo)
- Unfilter `NSToolbar Configuration` — show/hide toolbar is a real user preference
- `*PreferencesWindow*` added to noisy key patterns (window position/state)
- `FXRecentFolders` array deletions now filtered via `is_noisy_key` in `emit_array_deletions`
- Suppress false-positive array additions/deletions on reorder (e.g. Dock `persistent-apps` on app launch) — Python-level length check

### UX
- Warning when running ALL mode without sudo (fs_usage unavailable, polling only)
- Skip `fs_watch` launch when not root (avoids silent failure)

### Noise
- Exclude domains: `com.apple.wifi.known-networks`, `com.apple.TimeMachine`,
  `com.apple.timemachine*`, `com.apple.powerlogd`, `com.apple.calculateframework`,
  `com.apple.SoftwareUpdate`, `com.apple.apsd`, `com.apple.biometrickitd`,
  `com.apple.appleaccountd`, `com.apple.CacheDelete`, `com.apple.inputAnalytics*`,
  `com.apple.vmnet`, `com.apple.audio.SystemSettings`,
  `com.apple.coreservices.useractivityd*`, `com.apple.AccessibilityHearingNearby`,
  `com.apple.AppStore`, `com.apple.gamed`, `com.apple.gamecenter`,
  `com.apple.appleintelligencereporting`, `com.apple.GenerativeFunctions*`,
  `com.apple.SpeakSelection`, `com.microsoft.office`,
  `com.apple.ServicesMenu.Services`, `com.apple.AddressBook`
- PlistBuddy filters: `FXRecentFolders`, `NSWindowTabbingShoudShowTabBarKey`,
  `ViewSettings`, `FXSync*`, `MRSActivityScheduler`
- Key filters: `FK_SidebarWidth*`, `trash-full` (Dock), `*Analytics*`, `*Telemetry*`, `*lastBootstrap*`,
  `*LastLoadedOn*`, `NSLinguisticDataAssets*`, `*.column.*.width`, Sparkle updater keys (`SU*`),
  `uses`, `launchCount`, `*reminder.date`, `*donate*`

### Doc
- README scope section — Safari and other Apple apps may not use plist-based preferences

## 1.0.0 — 2026-02-12

### Release
- First official release as **PrefWatch**
  - Renamed project from Watch Preferences to PrefWatch
  - Updated all references: script, README, LICENSE, CI, GitHub templates
  - GitHub repo renamed to `Gill0o/PrefWatch`

### Feature
- Contextual `# NOTE:` comments in output for keyboard layouts (logout/login required) and Dock changes (`killall Dock`)
- Energy/Battery monitoring via `pmset_watch()` — polls `pmset -g custom`, emits `pmset -b`/`-c` commands (ALL mode only, beta)

### UX
- Snapshot progress — spinner + counter in terminal, clear messages in Console.app
- Python3 preflight — ALL mode prompts user if Xcode CLT/Python3 is missing
  - Warns about limited detection, offers to continue or abort with install instructions
  - No Xcode CLT popup on fresh macOS (checks `xcode-select -p` before running `/usr/bin/python3`)

### Fix
- PlistBuddy paths with spaces (e.g. `KeyboardLayout Name`) now escaped via `pb_escape()`
- PlistBuddy string values no longer wrapped in single quotes (conflicted with shell `-c` quoting)
- PBCMD `Add` commands no longer filtered by `is_noisy_key`

### Noise
- 40+ domain exclusions and global key patterns to surface only real changes
- PlistBuddy filters: `FXRecentFolders`, `NSWindowTabbingShoudShowTabBarKey`, `ViewSettings`, `NSToolbar Configuration`, `NSWindow Frame`, and more

### Note
- CUPS printer monitoring and print preset filtering are **experimental (beta)**

## 0.x — 2025-09 to 2026-02
- Internal development under the name **Watch Preferences** (v0.1.0 through v3.2-beta), renamed to PrefWatch in v1.0.0
- No git history prior to v2.5.0 (local development without GitHub) — Claude AI assisted since v2.0.0
