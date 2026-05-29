# Changelog

## 1.3.0 — unreleased

### Feature
- Sharing-panel capture (ALL/root): `sharing_exec_watch` (eslogger exec → the exact `kickstart`/`systemsetup`/`sharing`/`networksetup`/`launchctl` invocation), `launchd_state_watch` (polls `disabled*.plist` → `launchctl enable/disable` for XPC-only toggles: SSH, Screen Sharing, ARD), `cups_sharing_watch` (cupsd.conf `Browsing` → `cupsctl --[no-]share-printers`).

### Fix
- Responsiveness: widened the default hot domains (added `com.apple.dock`, `controlcenter`, `WindowManager`, `systemsettings`) so common panels surface in ~1-2s instead of ~10s — non-hot domains stay cold because cfprefsd buffers writes; use `--hot-domains` for others.
- ByHost flush: flush hints now issue `defaults -currentHost read` so ByHost prefs (trackpad, Bluetooth, screensaver) sync promptly instead of staying buffered.
- Guard two `set -e -o pipefail` pipeline assignments (`dscl` home, version header) with `|| true` — a non-zero exit aborted the script before the fallback ran (the `dscl` one could kill init under Jamf/root).
- `com.apple.inputAnalytics*` and `com.apple.appstored` exclusions were trapped inside comment lines and never applied.

### Refactor
- Deduplicated `show_plist_diff`/`show_domain_diff` into shared helpers (`_build_defaults_write_cmd`, `_build_defaults_delete_cmd`, `_emit_cmd`/`_log_kind`, `_process_py_meta`, `_process_diff_lines`, `_run_py_diff_workers`). No output change.
- MAIN: `EXIT` trap + startup sweep of orphan tmpdirs + lock-orphan reclaim; xtrace disable collapsed to one `unsetopt`.

### Noise
- Excluded domains: `com.apple.facetime.bag`, `com.apple.gridDataServices`, `com.adobe.AdobeGenuineService`, `com.apple.weather*`, `com.apple.backgroundtaskmanagement*` (lowercase variant).
- Key filters: `CKPerBootTasks`, `DDMPersisted*`, `*-analytics-stamp` (all global — the last covers dock/screencapture/systemuiserver); Bartender `TerminationReasons`; AudioMIDISetup `audioDevice.selected`; iStat menubar `Updates`/`Status`; cloud.quota `_ICQ*`; AssetCache cache-size keys; ARDAgent `ARDAdmin_AppStoreURL`; RemoteDesktop `RSAKeySize`/`DOCAllowRemoteConnections`.
- `sharing_exec_watch`: drop read-only `networksetup`/`systemsetup` queries; dedupe identical commands within 1s.
- `launchd_state_watch`: skip third-party VM/container helpers (`codes.rambo.*`, `com.parallels.*`, `com.vmware.*`, `org.virtualbox.*`, `com.docker.*`) and `com.apple.ManagedClient*`.


## 1.2.1 — 2026-05-14

### Feature
- Pre-flight confirmation now shown only when Python3/CLT is missing. `prompt_yn` adds an `osascript` GUI fallback via `launchctl asuser` for Jamf Self Service / launchd sessions (5-min timeout → auto-continue so policies never hang).

### Fix
- `poll_watch` could freeze when `cfprefsd` hung on a domain (parallel flush → unbounded `wait`). Added a 3s watchdog that SIGTERM/SIGKILLs stragglers so the loop always advances.

### Note
- Reworded the "new top-level key" NOTE: parent dict must exist before `Set`, so `Add` commands must run in order.

### Noise
- Add `*TimeStamp*` to global timestamp noise — zsh glob case sensitivity made `*Timestamp*` miss camelCase like `SuspendHelperActivityTimeStamp`.
- `com.apple.CharacterPicker`: filter `State` (per-app emoji picker UI keyed by bundle ID).
- `com.apple.quicklook.ThumbnailsAgent`: filter `QLMTCacheSize*LastCheck*` (periodic cache-size check).
- `com.bjango.istatmenus.menubar.*`: filter `License` (periodic license re-validation).
- `com.apple.wifi.WiFiAgent`: filter `UserDismissedLimitedNetworkFirstJoins` (per-SSID "don't show again" bookkeeping).
- Exclude `com.apple.CloudSubscriptionFeatures*` (iCloud+ geo cache with UUID-keyed binary entries — caused multi-second pauses in `show_plist_diff` on each cache refresh).

### CI
- `validate.yml`: drop `bash -n prefwatch.sh` — script is `#!/bin/zsh` and uses zsh-only constructs (`*(N)` glob qualifier failed under bash). zsh check on `prefwatch.sh` + bash check on `release.sh` are kept.

## 1.2.0 — 2026-04-17

### Feature
- New `--hot-domains <list>` CLI flag / Jamf `$10` parameter: comma-separated list of domains kept permanently "active" so their first change is detected without waiting for the fs_usage→poll round-trip. Defaults: `com.apple.finder`, `.GlobalPreferences`. Pass `NONE` to disable.
- Contextual `# NOTE:` for Finder `PreviewPaneSettings` — first-open writes the full attribute list; only subsequent toggles reflect actual user modifications.
- README: new **Security** section flagging that `/var/log/prefwatch-v*.log` may contain user-specific data.

### Fix
- `start_watch` single-domain mode missed any change that happened within the same second as its initial baseline: `stat -f %m` has 1-second granularity, so the `current_mtime != last_mtime` check never fired for same-second writes and the change remained invisible until a later-second write occurred. Now forces a full `show_domain_diff` every 4 poll iterations (~2s) regardless of mtime; `defaults export` reads `cfprefsd` directly and catches same-second writes the mtime check missed.
- Detect Finder column view settings (`StandardViewOptions:ColumnViewOptions`) — previously filtered out.
- Finder NOTE clarified: View Options (Cmd+J) require 'Use as Defaults' for detection (icon/list view); column view writes directly.

### Performance
- Preemptive `cfprefsd` flush in `fs_watch`: spawn `defaults read $dom` in the background before invoking `show_plist_diff`, giving the retry loop a better chance of seeing up-to-date data.
- New active-domains registry: `fs_watch` and `poll_watch` mark each touched domain in `$PREFWATCH_TMPDIR/active-domains/`; every poll iteration pre-flushes `cfprefsd` for those domains in parallel via `defaults read`. Non-destructive alternative to `killall cfprefsd`.
- HOT_DOMAINS are seeded into the active-domains registry at startup and auto-refreshed each poll cycle so they never expire — first change detected near-instantly.
- Tighter `show_plist_diff` retry schedule `0.1 0.2 0.3 0.5 0.7` (total 1.8s) replacing the previous `0.5 + 1.5` (2s). More frequent flush hints catch `cfprefsd` sync faster in the fs_usage path.
- `show_plist_diff` retry loop skips `dump_plist` when file mtime is unchanged (up to 5× per event saved). A final unconditional dump on the last retry ensures same-second writes are still caught, since `stat -f %m` has 1-second granularity.
- Skip `dump_plist_json` during retries in `show_plist_diff` — JSON is only needed after a change is confirmed.
- Reduce `poll_watch` cadence from 1s to 0.5s — halves the worst-case latency when the fs_usage path misses a flush.
- Debounce `fs_usage` events per-plist at 300ms using `$EPOCHREALTIME` (fork-free via `zsh/datetime`). `cfprefsd` emits multiple fs_usage events per logical write (observable via `fs_usage`); collapsing them avoids redundant `show_plist_diff` passes.
- Force line-buffered I/O in the fs_watch pipeline (`sed -l` + `awk fflush()`) — prevents block buffering between `sed`/`awk`/`while read` from holding back events on quiet pipelines.
- Run the 3 Python diff invocations (`emit_array_additions`, `emit_array_deletions` via new `_py_deletions_raw` helper, `emit_nested_dict_changes`) in parallel in both `show_plist_diff` and `show_domain_diff`.
- Reduce forks in `_log` (called for every output line): use `zsh/datetime` `strftime` instead of `/bin/date` in `get_timestamp`; replace two `printf | sed` pipelines with zsh `[[ =~ ]]` + `${match[1]}` capture on `defaults write` messages.

### Noise
- Exclude `com.apple.metrickitd` (MetricKit daemon — `MXClient*` keys are per-app diagnostic bookkeeping touched whenever Outlook, Teams, Edge, etc. query MetricKit, not user preferences)
- Exclude `com.apple.imessage.bag` (Apple service config bag: `CacheTime` TTL + `Date` refresh timestamp, server-controlled)
- Filter `LastIMDNotificationPostedDate` for `com.apple.iChat` (Instant Messaging Daemon notification timestamp)
- Filter `*lastAppUpdateCheck*|*LastAppUpdateCheck*` globally (auto-update check timestamps, e.g. Raycast `raycast-updates-lastAppUpdateCheckDate`)
- Filter `*lastProcessed*|*LastProcessed*` (processing timestamps like `lastProcessedDate`)
- Filter `*LastBackup*|*lastBackup*` (TimeMachine daemon state like `LastBackupActivity`)
- Filter `CloudKitAccountInfoCache|*CloudKitAccountInfo*` globally (hash-keyed CloudKit account cache)
- Filter TimeMachine `Destinations:N:` daemon sub-keys (`BytesAvailable`, `BytesUsed`, `NumberOfSnapshots`, `SnapshotDates`, `ConsistencyScanDate`, `FilesystemTypeName`, `LastKnownEncryptionState`, `LastKnownVolumeName`, `ReferenceLocalSnapshotDate`, `attemptDate`, `backupOfVolumeUUIDs`) — keeps user config (`ID`, `Kind`, `QuotaGB`, `Name`)
- Filter `PreviewOptionsWindow.Location` for Finder (Cmd+J panel window position)

### Prevent masking real user preferences
Narrowed overly-broad global patterns in `is_noisy_key()` that could hide real prefs:
- `*History*` → `*HistoryItems*|*HistoryMetadata*|*HistoryList*|NSRecentDocumentsHistory|*HistoryDatabase*` (keeps `HistoryAgeInDaysLimit`, `EnableHistory`)
- `*Cache*` → `*CacheData*|*CachedBy*|*CacheVersion*|*CacheKey*|*CacheEntry*` (keeps `CacheSize`, `EnableCache`, `DiskCacheSize`)
- `*Temp*` → removed (kept `*-temp|*-tmp|*TempFile*|*TempPath*`) — avoid catching `Template*`, `ColorTemperature`
- `*ViewOptions*` → `*ViewOptionsFrame*|*ViewOptionsWindow*` (suffix-specific window state)
- `FK_SidebarWidth*` → removed (real user preference)
- `*Analytics*|*Telemetry*` → `*AnalyticsQueue/Session/Event*|*TelemetryQueue/Session/Event*` (keeps `AnalyticsEnabled`, `SendAnalytics`)
- `SUSendProfileInfo` → removed (Sparkle opt-in toggle)
- `flags` exact → removed (too generic)
- `uses` / `*donate*` → removed/narrowed to `launchCount`, `*donateDialogShown*`, `*lastDonateDate*`
- `state|status|State|Status` exact → removed
- `*ConnectionState*` → removed
- `*Date|Date` exact suffix → removed (specific date noise already covered)
- `last-selection` → removed from global
- ALL_CAPS regex → removed (could catch real prefs like `SHOW_HIDDEN_FILES`)

Narrowed `DEFAULT_EXCLUSIONS` that hid entire domains with real user preferences:
- `com.apple.SoftwareUpdate` → removed (`AutomaticDownload`, `AutomaticallyInstallMacOSUpdates`, `AutomaticCheckEnabled`)
- `com.apple.TimeMachine` → narrowed to `.helper`/`.agent` (keeps `AutoBackup`, `ExcludedPaths`)
- `com.apple.security*` → narrowed to known daemon sub-domains

## 1.1.6 — 2026-04-11

### Fixed
- Stop filtering Finder view settings (`FK_StandardViewSettings`) — `showIconPreview`, `iconSize`, `gridSpacing`, column/list view settings are real user preferences
  - Removed overly broad `*"ViewSettings"*` sub-key filter in PlistBuddy commands
  - Removed global `*IconViewSettings*` key filter

### Noise
- Fix `*ScrollPosition` pattern to also match `scrollPositionX/Y` (add trailing wildcard + lowercase variant)
- Filter `scrollPosition` sub-keys in PlistBuddy commands (nested scroll state in view settings)
- Filter Finder column `:width` sub-keys in PlistBuddy commands (column resize noise)
- Update Finder contextual NOTE: View Options (Cmd+J) require 'Use as Defaults' for detection; column view has no global default (always .DS_Store)

## 1.1.5 — 2026-03-30

### Noise
- Exclude `TokenBucketRateLimiter` (ML embedding rate limiter counters/timestamps)
- Widen `com.apple.bird` exclusion to `com.apple.bird*` to also catch `com.apple.bird.containers.notifications`
- Filter `controllers:tombstones`, `*:modifiedDate` for `com.apple.GameController` (internal sync metadata, not user preferences)
- Exclude `com.apple.EmojiCache` (auto-generated emoji locale cache)
- Filter `Scrutiny`, `CKBackgroundSettingsLastReportHour` for `com.apple.MobileSMS` (iMessage analytics/telemetry)
- Filter `CharacterPaletteIM` sub-key for `com.apple.HIToolbox` (transient emoji viewer open/close)
- Filter `lastFireDate` sub-key for `com.rogueamoeba.loopbackd` (scheduler timestamp)
- Filter `uret-init` for `com.native-instruments.*` (telemetry init flag)
- Filter `shouldUpdateAccessory` for `com.apple.PersonalAudio` (AirPods firmware state toggle)
- Filter `ZMJoinMeetingFlowAnchor` for `us.zoom.xos` (window position)
- Exclude `Avatar Cache*` (avatar cache index, hash keys with timestamps)
- Exclude `com.apple.diagnosticd*` (system logging subsystem filter config)
- Filter `FXConnectToLastURL` for `com.apple.finder` (last connected server history)
- Filter `mailShortcuts`, `reloadShortcuts` for `com.apple.Spotlight` (auto-learned shortcuts, reload trigger)
- Exclude `com.apple.textunderstanding*` (NLP runtime model version counters)
- Filter `WindowBounds`, `WindowState` sub-keys in PlistBuddy commands (window position/size in nested dicts)

## 1.1.4 — 2026-03-12

### Noise
- Filter `CRDialogShown_*`, `lastCrash_*`, `SuppressCrash_*` for `com.adobe.crashreporter` (crash dialog state and crash metadata, not user preferences)
- Filter `NSDisabledCharacterPaletteMenuItem`, `NSFullScreenMenuItemEverywhere` globally (app-controlled macOS menu item overrides, not user preferences)
- Filter `butler.*`, `VMMemoryUsagePercent*`, `paletteEnhancedFontTypeKey*` for `com.adobe.Photoshop` (internal app state, not user preferences)
- Filter `DNSA*`, `StartupScriptsLoadedSuccessfully`, `FeatureMapExpiryTime` for `com.adobe.bridge*` (dialog suppression state, startup load result, feature flag expiry)
- Filter `SessionDuration` globally (session duration telemetry counter, seen in Adobe After Effects, Premiere Pro, etc.)
- Filter `FirstLaunch*`, `firstLaunch*` globally (version-stamped first-launch flags, internal app state)
- Filter `RecoveryOpenProjectInfos` for `com.Adobe.Premiere Pro*` (crash recovery project list, session state)
- Exclude `com.apple.universalaccessAuthWarning` (accessibility authorization state, not user preferences)
- Filter `RecentMoveAndCopyDestinations` for `com.apple.finder` (recent copy/move destination history)
- Filter `preferredLocalizations` globally (system-managed localization, not user preferences)
- Filter `SystemInfoDynamic.*` globally (internal system state, not user preferences)
- Exclude `com.apple.remindd*` (Reminders daemon CloudKit sync state)

### Fix
- Python3 warning now written to log file — visible when checking `/var/log/prefwatch-*.log` directly
- Python3 prompt unified for CLI and Jamf: same interactive prompt in both modes, auto-continues ("y") when no TTY (Jamf)
- Python3 warning visible in Jamf output even in ONLY_CMDS mode (prefixed with `Cmd: #`)

### Note
- Add inline NOTE for `com.apple.prodisplaylibrary`: `defaults write` alone does not apply display presets — alternative third-party tools exist

## 1.1.3 — 2026-02-26

### Noise
- Exclude `com.apple.AudioAccessory` (Bluetooth accessory battery state and timestamps)
- Exclude `com.apple.systemsettings.extensions*` (Settings panel extension internal state)
- Exclude `com.apple.networkserviceproxy` (network geolocation hashes)
- Filter `kIM_LastOpenedSession` for `us.zoom.xos` (Zoom last opened chat session)
- Exclude `journal` domain (VoiceOver internal Braille timestamps)
- Filter `SCRC*` and `SCRDisplay*` keys (VoiceOver internal Braille/display state)
- Filter `SessionId`, `SessionVersion`, `SessionLongBuildNumber`, `CampaignManagerVersionKey` (app session/version metadata)
- Filter `SUUpdateRelaunchingMarker` (Sparkle update framework marker)
- Filter `last-selection` for `com.apple.screencapture` (screenshot selection area coordinates)
- Filter `timerEndInterval`, `comfortSoundsEnabled_UpdateInfo` for `com.apple.ComfortSounds` (timer timestamp, setting change audit log)
- Filter `currentEnrollmentProgress` for `com.apple.PersonalAudio` (audio enrollment transient state)
- Filter `DictationIMTargetApplications`, `CACPersistentSleepState` for `com.apple.speech.recognition.AppleSpeechRecognition.prefs` (auto-generated app inventory, Voice Control sleep state)
- Filter `PanelFrame`, `SCLaunchedAsSlave` for `com.apple.AssistiveControl.virtualKeyboard` (window position, internal launch state)

### Fix
- Stop filtering `feature.*` keys in `com.apple.universalaccess` — VoiceOver, Zoom, StickyKeys etc. are real accessibility settings, not internal feature flags
- Stop filtering `closeViewZoomFocusFollowModeKey` — zoom focus follow mode is a real user preference (detach zoom from pointer), not transient state
- Filter `displaysLastCursorLocation` for `com.apple.universalaccess` (transient cursor position)

## 1.1.2 — 2026-02-24

### Fix
- Apply `--mdm` path substitution to PlistBuddy `Delete` commands

### Noise
- Filter `*SKPurchaseIntent*` (StoreKit license check timestamps)
- Exclude `com.apple.appleaccount` (boot session IDs)
- Exclude `com.apple.shazamd` (Shazam daemon CloudKit per-boot tasks)
- Exclude `com.apple.wallpaper.aerial` (Aerial wallpaper remote asset URLs)
- Exclude `com.apple.osprey` (device attestation expiration timestamps)

## 1.1.1 — 2026-02-24

### Feature
- New `--mdm` CLI option (Jamf `$9 = MDM_OUTPUT`): replace user home path with `$loggedInUser` variable in PlistBuddy commands for MDM deployment scripts

### Noise
- Exclude `com.apple.protectedcloudstorage*` (CloudKit keychain sync)
- Exclude `com.apple.DataDeliveryServices` (metadata sync timestamps)
- Exclude `com.apple.ReportCrash` (crash reporter TrialCache timestamps)
- Exclude `com.apple.homeenergyd` (HomeKit CloudKit sync cache)
- Exclude `com.apple.seserviced` (Secure Element session counters)
- Exclude `codes.rambo.VirtualBuddy` (VM app window state, UI settings)
- Exclude `com.apple.spotlightknowledged.pipeline` (Spotlight knowledge daemon sync)
- Exclude `com.apple.amp.mediasharingd` (media sharing daemon internal state)
- Filter `WebKitUseSystemAppearance` (Settings panel WebKit artifact)
- Filter `*WindowOriginFrame*` (Zoom window position state)
- Filter `*DataSequenceKey*` (Siri/Shortcuts sync counters)
- Filter `History` for `com.apple.universalaccess` (internal change history log)
- Filter `KB_SpellingLanguage*` in `.GlobalPreferences` (Keyboard panel first-open artifact)
- Filter `com.apple.custommenu.apps` for `com.apple.universalaccess` (Keyboard Shortcuts panel artifact)
- Exclude `com.apple.remindd.babysitter` (Reminders CloudKit sync daemon)
- Filter `Connected` and `Use Count` for `com.apple.iPod` (sync timestamps and counters)
- Filter `*@xmpp.zoom.us*` for `us.zoom.xos` (Zoom per-user session state)

### Refactor
- Unify PBCMD filtering: new `is_noisy_pbcmd()` function extracts top-level key and delegates to `is_noisy_key()`, eliminating duplicated 27-pattern case statement — all key-level filters now automatically apply to both `defaults` and PlistBuddy output
- Strip volatile plist metadata (`parent-mod-date`, `file-mod-date`, `file-type`, `GUID`, etc.) before array element matching — prevents phantom add/delete when macOS rewrites metadata on save
- Remove dead code in `is_noisy_command()` (patterns redundant with `is_noisy_key()`)
- Consolidate script sections: merge Plist & PlistBuddy, add Domain Diff banner, relocate caches next to consumers
- Soften Finder domain note: not all changes require `killall Finder`
- Drop redundant `# Complex type` comment for dict/array keys — PlistBuddy commands already show the full structure
- Add `book` (macOS bookmark data) to volatile keys for array fingerprinting — prevents phantom add/delete on Dock reorder
- Defer all contextual output (domain notes, PBCMD comments, labels) until a real command passes noise filtering — prevents orphaned notes

### Fix
- Detect sub-key additions and deletions in nested dicts (e.g. Finder toolbar customization `NSToolbar Configuration`)
- Detect value changes within existing top-level arrays (e.g. Spotlight `orderedItems` enable/disable)
- Prevent false `Set` commands when array elements shift after insertion/deletion (e.g. Dock reorder)
- Retry plist read with increasing delays (0.5s + 1.5s) when file appears unchanged — fixes missed Dock actions caused by cfprefsd async disk writes
- Fix orphan contextual note when all PBCMD commands are filtered (lazy emit after filter)
- Fix duplicate commands for new top-level arrays (dedup between `emit_array_additions` and `emit_nested_dict_changes`)
- Fix `NSWindowTabbingShoudShowTabBarKey` incorrectly filtered (is a real user preference: show/hide tab bar)
- Fix log path documentation in header to match actual `prefwatch-v<version>.log`

### UX
- Add contextual note `killall Finder` + `.DS_Store` per-window overrides for Finder domain
- Add generic first-create note when any top-level dict/array is created for the first time
- Add contextual note for symbolic hotkeys parameter rewrite on toggle
- Add post-snapshot polling delay notice
- Add contextual note for `com.apple.WindowManager` (Desktop & Dock first-open writes all defaults)
- Add contextual note for `com.apple.universalaccess` (Accessibility first-open writes all defaults)

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
- PlistBuddy `pb_type_value()`: emit `true/false` for bools (required by PlistBuddy)
- Parallel snapshot: fix invalid `shift _snap_pids` zsh syntax — use array slice instead
- Poll watch: remove dead `_poll_first` flag and stale `$now` variable reference

### Feature
- Contextual `# NOTE:` for print preset changes (logout/login required to apply)
- Contextual `# NOTE:` for keyboard shortcut changes (`com.apple.symbolichotkeys`)
- Dock icon add/remove: emit `# Dock: AppName (bundle-id)` comment for readability
- Dock icon remove: emit `# Dock: removed AppName` comment
- Detect keyboard shortcuts (`AppleSymbolicHotKeys`) in ALL mode via `emit_nested_dict_changes`

### Noise
- Exclude `com.apple.homed` (HomeKit generation counters)
- Exclude `com.apple.classroom`, `com.apple.mediaanalysisd`, `com.apple.financed`, `com.apple.biomesyncd`, `com.apple.madrid`
- Dock: filter `recent-apps` in both `is_noisy_key` and PBCMD handler
- Print presets: filter Fiery/PPD driver defaults (`*EF*` keys, `vendorDefaultSettings`, `PaperInfo` subtree) — keep only useful settings (PageSize, Duplex, ColorMode, etc.)
- PBCMD handler: filter Dock tile internals (`GUID`, `dock-extra`, `is-beta`, `file-type`, `tile-type`, `*-mod-date`)
- PBCMD handler: fix `<data:` filter (remove stale single-quote prefix)
- PBCMD handler: sync both handlers (show_plist_diff + show_domain_diff)
- Print preset `# NOTE:` emitted once before commands

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
- Detect print preset deletion (`customPresetsInfo` array)
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
