# Changelog

## 1.3.3 — unreleased

### Feature
- Local user account add/remove emits a `# NOTE:` — the account lives in OpenDirectory, not a plist, so it isn't reproducible via `defaults`.
- A pure Dock reorder emits a `# NOTE:` — the order would need a full `persistent-apps` rewrite, so it previously produced no output at all.
- `NSToolbar Configuration` (any app) carries a `# NOTE:` — the first window open dumps the whole toolbar layout; only later changes are real customizations. Kept visible, not filtered.
- A UUID in the *key* path now carries a `# NOTE:` — it names a machine-local object (a display, an account, …), never the Mac, so `--mdm` cannot templatize it and the command must be resolved against the target before it will deploy. The common case is ColorSync's `Device.mntr.<UUID>`: the display's EDID-derived CoreGraphics UUID — unique per panel where it reports a serial, shared across a production batch where it does not, and readable only via `CGDisplayCreateUUIDFromDisplayID`.

### Fix
- `--mdm` emitted a ByHost path carrying the capture machine's literal hardware UUID: it templatized the home but not the UUID, so on any target the path was wrong — and PlistBuddy creates what it cannot find, seeding a stray ByHost plist named after a machine that is not there. Now rewritten to `.$UUID.plist` with an `ioreg` resolver NOTE; normal mode warns rather than rewriting.

### Noise
- Drop the `com.apple.preferences.accounts` `deletedUsers` churn — replaying it created a phantom deleted-user record; the account NOTE reports the real removal instead.
- Filter geometry/telemetry churn: `screencapture` `last-selection*`, OmniGroup `OSURunTimeStatistics`/`OSULastRun*`, SketchUp `WebDialog.*` window positions.
- Extend the `com.apple.SoftwareUpdate` daemon-result filter to `AvailableUpdatesNotification*` — the policy toggles stay.

## 1.3.2 — 2026-07-06

### Feature
- Contextual NOTEs for Finder view settings (first "Use as Defaults" writes the full structure) and menu-bar extras (run `killall SystemUIServer` to apply).

### Fix
- ByHost `defaults write` commands now place `-currentHost` before the verb — they were malformed and did nothing, affecting every ByHost pref (Control Center menu-bar modules, trackpad/mouse, screensaver, ColorSync).
- System-level pref changes (`/Library/Preferences`, seen when running as root) now emit commands targeting the system file by full path plus a root NOTE — a bare domain replayed into the console user's `~/Library` copy instead.
- Emitted commands reproduce values faithfully: escape `$`/backticks/`$VAR` in `-string` values, single quotes in all `PlistBuddy` commands, and leading/trailing whitespace in PlistBuddy values.
- Array deletions: emitted highest-index-first so a batch runs safely in order, a nested-list element now emits its items, and the deletion WARNING is no longer dropped from `ONLY_CMDS`/Jamf output.
- `NSTableViewDefaultSizeMode` (sidebar icon size) is no longer dropped as noise.
- `show_domain_diff` no longer emits a spurious full-domain storm when `defaults export` transiently returns empty.
- `launchd_state_watch` no longer leaks plutil errors into the log (Sonoma).
- `sharing_exec_watch` drops read-only `networksetup`/`systemsetup` queries invoked without the leading dash.
- Jamf `$7` (ONLY_CMDS) is no longer overridden by a stray environment variable.
- `poll_watch` flush watchdog: `set -e` no longer aborts the kill escalation on an already-reaped pid, so the straggler freeze-cap holds.
- Contextual NOTEs and the array-deletion WARNING dedup per burst — shown once for a rapid run of changes and re-shown after a quiet gap (`_NOTE_BURST_GAP`, default 15s), instead of once per session or on every single change.

### Noise
- Excluded daemon / non-reproducible domains: `MobileMeAccounts`, `com.apple.ShazamKit`, `com.apple.mobiletimerd`, `com.apple.parsecd`.
- Filtered internal keys: `VisibleNetworkSRLocaleIdentifiers` (speech), `version` (Spotlight), `hudNotifiedConstrast` (universalaccess).

## 1.3.1 — 2026-06-18

### Feature
- `ard_privs_watch`: capture per-user Remote Management (ARD) privileges (the `naprivs` bitmask, set via XPC outside any plist) — emits the `dscl -create/-delete` + `kickstart -restart -agent` to apply.

### Fix
- `sharing_exec_watch`: capture `kickstart` (a Perl script, so its exec reports `perl` — now resolved from args for interpreters, not launchers like `sudo`).
- `launchd_state_watch`: pair `enable`/`disable` with `bootstrap`/`bootout` so socket-activated sharing toggles (SMB/SSH/Screen Sharing) replay; plist resolved by label (`com.openssh.sshd`→`ssh.plist`).

### Noise
- Global key filter `BIT*Time` (HockeyApp / App Center session timestamps).
- `sharing_exec_watch`: whitelist `launchctl` to Apple sharing labels (smbd/screensharing/sshd/ARD) — drops third-party LaunchAgent churn (Zoom/MS/Adobe/VM updaters).

## 1.3.0 — 2026-06-05

### Feature
- Sharing-panel capture (ALL/root): captures toggles stored outside plists and emits the matching command — Remote Login / Screen Sharing / Remote Management (`launchctl`/`kickstart`/`systemsetup`/`sharing`/`networksetup`) and Printer Sharing (`cupsctl`), via `eslogger`, launchd `disabled.plist`, and `cupsd.conf`.
- Faster detection: a default "hot" set of the common System Settings panels is flushed every 0.5s so changes surface in ~1-2s instead of ~10s. Override via `--hot-domains` (Jamf `$10`); `NONE` disables.

### Fix
- `com.apple.loginwindow` un-excluded to surface admin policies (`GuestEnabled`, `LoginwindowText`, `autoLoginUser`, …); per-session churn filtered key-by-key instead.
- Guard `set -e` pipeline assignments (`dscl` home, version header) with `|| true` so a non-zero exit can't abort startup under Jamf/root.
- Guaranteed tmpdir cleanup on exit + reclaim of orphan tmpdirs/locks from crashed prior runs.

### Noise
- Newly excluded domains: `com.apple.facetime.bag`, `com.apple.gridDataServices`, `com.adobe.AdobeGenuineService`, `com.apple.weather*`, `com.apple.inputAnalytics*`, `com.apple.appstored`, `com.apple.security.cloudkeychainproxy3*`.
- New global key filters: `CKPerBootTasks`, `DDMPersisted*`, `*-analytics-stamp`, `*FlushThumbnailCache`, `*_frame`/`SidebarWidth` (window geometry), `*last*Date` (timestamps), `recentlyPlayed*`/`NSOSPLastRootDirectory`.
- New per-domain filters: SoftwareUpdate daemon results, smb.server `NetBIOSName`, HIToolbox `AppleInputSourceHistory`, Bartender `TerminationReasons`, AudioMIDISetup `audioDevice.selected`, iStat menubar `Updates`/`Status`, cloud.quota `_ICQ*`, AssetCache cache-size, ARDAgent/RemoteDesktop daemon-init values.
- Sharing watchers: drop read-only `networksetup`/`systemsetup` queries, VM/container launchd helpers, and auto-flapping `bootpd`/`dhcp6d`.

## 1.2.1 — 2026-05-14

### Feature
- Pre-flight confirmation now shown only when Python3/CLT is missing. `prompt_yn` gains an `osascript` GUI fallback via `launchctl asuser` for Jamf Self Service / launchd sessions (5-min timeout → auto-continue so policies never hang).

### Fix
- `poll_watch` could freeze when `cfprefsd` hung on a domain (unbounded `wait` on the parallel flush); added a 3s watchdog that SIGTERM/SIGKILLs stragglers so the loop always advances.

### Noise
- Global: add `*TimeStamp*` (zsh glob case-sensitivity missed camelCase like `SuspendHelperActivityTimeStamp`).
- Per-domain: CharacterPicker `State`, quicklook.ThumbnailsAgent `QLMTCacheSize*LastCheck*`, istatmenus.menubar `License`, wifi.WiFiAgent `UserDismissedLimitedNetworkFirstJoins`.
- Exclude `com.apple.CloudSubscriptionFeatures*` (UUID-keyed binary cache causing multi-second `show_plist_diff` pauses).

### CI
- `validate.yml`: drop `bash -n prefwatch.sh` (script is zsh, uses zsh-only constructs); keep zsh check on `prefwatch.sh` + bash check on `release.sh`.

## 1.2.0 — 2026-04-17

### Feature
- New `--hot-domains <list>` CLI flag / Jamf `$10`: domains kept permanently "active" so their first change is detected without the fs_usage→poll round-trip. Defaults: `com.apple.finder`, `.GlobalPreferences`; `NONE` disables.
- Contextual `# NOTE:` for Finder `PreviewPaneSettings` (first-open writes the full attribute list; only later toggles are real changes).
- README: new **Security** section flagging that `/var/log/prefwatch-v*.log` may contain user-specific data.

### Fix
- `start_watch` single-domain mode missed same-second changes (`stat -f %m` is 1s-granular); now forces a full `show_domain_diff` every ~2s via `defaults export`, which reads `cfprefsd` directly.
- Detect Finder column view settings (`StandardViewOptions:ColumnViewOptions`), previously filtered out.

### Performance
- Active-domains registry: `fs_watch`/`poll_watch` pre-flush `cfprefsd` for recently-touched domains in parallel (non-destructive alternative to `killall cfprefsd`); HOT_DOMAINS seeded at startup and auto-refreshed so first change is near-instant.
- Tighter retry/poll cadence (poll 1s→0.5s), per-plist 300ms `fs_usage` debounce, line-buffered fs_watch pipeline, parallel plist dumps + parallel Python diff workers, fork reduction in `_log`/`get_timestamp` (`zsh/datetime`).

### Noise
- Exclude `com.apple.metrickitd`, `com.apple.imessage.bag`.
- Global: `*lastAppUpdateCheck*`, `*lastProcessed*`, `*LastBackup*`, `CloudKitAccountInfoCache`/`*CloudKitAccountInfo*`.
- Per-domain: iChat `LastIMDNotificationPostedDate`, Finder `PreviewOptionsWindow.Location`, TimeMachine `Destinations:N:` daemon sub-keys (keeps `ID`/`Kind`/`QuotaGB`/`Name`).

### Prevent masking real preferences
- Narrowed overly-broad `is_noisy_key()` patterns that could hide real prefs: `*History*`, `*Cache*`, `*Temp*`, `*ViewOptions*`, `*Analytics*`/`*Telemetry*`, `SUSendProfileInfo`, `flags`, `state|status`, `*ConnectionState*`, `*Date` suffix, `last-selection`, ALL_CAPS regex.
- Un-excluded domains holding real prefs: `com.apple.SoftwareUpdate` (`AutomaticDownload`, …), `com.apple.TimeMachine` → `.helper`/`.agent` (keeps `AutoBackup`, `ExcludedPaths`), `com.apple.security*` → known daemon sub-domains.

## 1.1.6 — 2026-04-11

### Fix
- Stop filtering Finder view settings (`FK_StandardViewSettings`) — `showIconPreview`, `iconSize`, `gridSpacing`, column/list settings are real preferences.

### Noise
- Fix `*ScrollPosition` to also match `scrollPositionX/Y`; filter `scrollPosition` and Finder column `:width` sub-keys in PlistBuddy commands.

## 1.1.5 — 2026-03-30

### Noise
- Exclude domains: `TokenBucketRateLimiter`, `com.apple.bird*`, `com.apple.EmojiCache`, `Avatar Cache*`, `com.apple.diagnosticd*`, `com.apple.textunderstanding*`.
- Per-domain: GameController `tombstones`/`*:modifiedDate`, MobileSMS `Scrutiny`/`CKBackgroundSettingsLastReportHour`, HIToolbox `CharacterPaletteIM`, loopbackd `lastFireDate`, native-instruments `uret-init`, PersonalAudio `shouldUpdateAccessory`, zoom `ZMJoinMeetingFlowAnchor`, finder `FXConnectToLastURL`, Spotlight `mailShortcuts`/`reloadShortcuts`.
- Filter `WindowBounds`/`WindowState` sub-keys in PlistBuddy commands.

## 1.1.4 — 2026-03-12

### Noise
- Exclude domains: `com.apple.universalaccessAuthWarning`, `com.apple.remindd*`.
- Global: `NSDisabledCharacterPaletteMenuItem`/`NSFullScreenMenuItemEverywhere` (app-controlled menu overrides), `SessionDuration`, `FirstLaunch*`, `preferredLocalizations`, `SystemInfoDynamic.*`.
- Per-domain: crashreporter `CRDialogShown_*`/`lastCrash_*`/`SuppressCrash_*`, Photoshop `butler.*`/`VMMemoryUsagePercent*`/`paletteEnhancedFontTypeKey*`, bridge `DNSA*`/`StartupScriptsLoadedSuccessfully`/`FeatureMapExpiryTime`, Premiere `RecoveryOpenProjectInfos`, finder `RecentMoveAndCopyDestinations`.

### Fix
- Python3 warning now written to the log file and visible in Jamf ONLY_CMDS mode; prompt unified for CLI and Jamf (auto-continues when no TTY).

### Note
- `com.apple.prodisplaylibrary`: `defaults write` alone does not apply display presets — third-party tools required.

## 1.1.3 — 2026-02-26

### Noise
- Exclude domains: `com.apple.AudioAccessory`, `com.apple.systemsettings.extensions*`, `com.apple.networkserviceproxy`, `journal`.
- Global: `SCRC*`/`SCRDisplay*` (VoiceOver Braille), `SessionId`/`SessionVersion`/`SessionLongBuildNumber`/`CampaignManagerVersionKey`, `SUUpdateRelaunchingMarker`.
- Per-domain: zoom `kIM_LastOpenedSession`, screencapture `last-selection`, ComfortSounds `timerEndInterval`/`comfortSoundsEnabled_UpdateInfo`, PersonalAudio `currentEnrollmentProgress`, speech-recognition `DictationIMTargetApplications`/`CACPersistentSleepState`, AssistiveControl.virtualKeyboard `PanelFrame`/`SCLaunchedAsSlave`.

### Fix
- Stop filtering `feature.*` in `com.apple.universalaccess` and `closeViewZoomFocusFollowModeKey` — real accessibility settings; filter `displaysLastCursorLocation` instead.

## 1.1.2 — 2026-02-24

### Fix
- Apply `--mdm` path substitution to PlistBuddy `Delete` commands.

### Noise
- Global: `*SKPurchaseIntent*`. Exclude `com.apple.appleaccount`, `com.apple.shazamd`, `com.apple.wallpaper.aerial`, `com.apple.osprey`.

## 1.1.1 — 2026-02-24

### Feature
- New `--mdm` CLI option (Jamf `$9 = MDM_OUTPUT`): replace user home path with `$loggedInUser` in PlistBuddy commands for MDM deployment scripts.

### Fix
- Detect sub-key add/delete in nested dicts (Finder `NSToolbar Configuration`) and value changes in top-level arrays (Spotlight `orderedItems`); prevent false `Set` on array shift (Dock reorder); retry plist read on `cfprefsd` async writes; dedup commands for new top-level arrays; un-filter `NSWindowTabbingShoudShowTabBarKey` (real preference).

### Refactor
- New `is_noisy_pbcmd()` unifies PBCMD filtering with `is_noisy_key()` — key filters now apply to both `defaults` and PlistBuddy output; strip volatile plist metadata (`*-mod-date`, `GUID`, `book`, …) before array matching to prevent phantom add/delete on reorder.

### Noise
- Exclude domains: `com.apple.protectedcloudstorage*`, `com.apple.DataDeliveryServices`, `com.apple.ReportCrash`, `com.apple.homeenergyd`, `com.apple.seserviced`, `codes.rambo.VirtualBuddy`, `com.apple.spotlightknowledged.pipeline`, `com.apple.amp.mediasharingd`, `com.apple.remindd.babysitter`.
- Filter: `WebKitUseSystemAppearance`, `*WindowOriginFrame*`, `*DataSequenceKey*`, universalaccess `History`/`com.apple.custommenu.apps`, `.GlobalPreferences` `KB_SpellingLanguage*`, iPod `Connected`/`Use Count`, zoom `*@xmpp.zoom.us*`.

### UX
- Contextual notes: Finder (`killall Finder`, `.DS_Store` overrides), symbolic-hotkeys parameter rewrite, WindowManager/universalaccess first-open writes all defaults, generic first-create note.

## 1.1.0 — 2026-02-17

### Feature
- Detect keyboard shortcuts (`AppleSymbolicHotKeys`) in ALL mode via `emit_nested_dict_changes`; contextual `# NOTE:` for print presets and shortcuts; Dock add/remove emits `# Dock: AppName (bundle-id)` for readability.

### Performance
- Parallel initial snapshot (up to 16 concurrent text+JSON dumps), parallel `dump_plist`/`dump_plist_json` on change, cached `hash_path()` results, polling 2s→1s, pre-initialized poll markers (no double-scan after snapshot).

### Fix
- Dock icon add/remove: `bundle-identifier`/`_CFURLString`/`file-label` now visible in PlistBuddy output; print presets emit full `Add` tree for new dict/array; PlistBuddy bools emit `true/false`.

### Noise
- Exclude `com.apple.homed`, `com.apple.classroom`, `com.apple.mediaanalysisd`, `com.apple.financed`, `com.apple.biomesyncd`, `com.apple.madrid`.
- Dock: filter `recent-apps` + tile internals (`GUID`, `dock-extra`, `is-beta`, `file-type`, `tile-type`, `*-mod-date`); print presets: filter Fiery/PPD driver defaults (keep PageSize, Duplex, ColorMode, etc.).

## 1.0.4 — 2026-02-16

### Fix
- Suppress false `defaults write` for nested dict keys (ColorSync ICC profiles) — only top-level keys produce valid commands; PlistBuddy string values no longer single-quoted (fixes values with spaces).

### Feature
- Contextual `# NOTE:` for ColorSync ICC profile changes (logout/login required) and simple key changes.

### Noise
- Exclude domains: `com.apple.SafariCloudHistoryPushAgent`, `NetworkInterfaces`, `com.apple.dhcp6d`, `com.teamviewer*`, `com.apple.QuickLookDaemon`, `com.microsoft.OneDriveUpdater`, `com.apple.itunescloudd`, `com.apple.commcenter*`, `com.apple.AdPlatforms`.
- Key filters: `*HeartbeatDate*`, Finder `FXConnectToBounds`/`SearchRecentsSavedViewStyle`.

## 1.0.3 — 2026-02-15

### Fix
- Detect print preset deletion (`customPresetsInfo` array); CUPS printer monitoring with 5s debounce (filters DNS-SD/Bonjour false positives).

### Noise
- Exclude domains: `com.apple.networkd`, `com.apple.AutoWake`, `com.apple.siri.DialogEngine`/`com.apple.siri.sirisuggestions`/`com.apple.siriknowledged`, `com.bjango.istatmenus.status`, `app.monitorcontrol.MonitorControl`, `com.apple.settings.Storage`, `com.apple.iCal`, `com.apple.icloud.searchpartyuseragent`, `com.apple.rapport`, `com.apple.IMCoreSpotlight`, `com.apple.identityservicesd`, `com.apple.imagent`.
- Filter: `com.apple.finder.SyncExtensions` (PlistBuddy), UUID-formatted key names, `feature.*` flags, `closeViewZoom*FocusFollowMode*`, Terminal `TTAppPreferences Selected Tab`.

### UX
- All temp files consolidated under `/tmp/prefwatch.PID/` with cleanup on exit.

## 1.0.2 — 2026-02-14

### Fix
- Suppress `plutil -convert json` errors visible on Sonoma during snapshot; escape spaces in PlistBuddy key names (e.g. `KeyboardLayout\ Name`); Dock reorder no longer emits false tile-metadata writes.

### Noise
- Exclude domains: `com.apple.MobileSMSPreview`, `com.apple.ncprefs`, `com.apple.accounts.exists`, `com.apple.icloud.fmfd`, `com.apple.TelephonyUtilities`, `com.apple.TV`, `com.apple.Music`, `com.apple.itunescloud`, `com.apple.findmy*`, `com.apple.bookdatastored`.
- Key filters: `*WindowFrame*`, `*DidMigrate*`.

## 1.0.1 — 2026-02-13

### Fix
- Suppress redundant PlistBuddy `Delete` when a `defaults write` follows for the same key (checks the snapshot file directly, works under sudo); un-filter `NSToolbar Configuration` (real preference); add `*PreferencesWindow*` to noise; filter `FXRecentFolders` array deletions; suppress reorder false-positives (Dock `persistent-apps` on launch).

### UX
- Warn when ALL mode runs without sudo (fs_usage unavailable, polling only); skip `fs_watch` when not root.

### Noise
- Exclude domains: `com.apple.wifi.known-networks`, `com.apple.TimeMachine`/`com.apple.timemachine*`, `com.apple.powerlogd`, `com.apple.calculateframework`, `com.apple.SoftwareUpdate`, `com.apple.apsd`, `com.apple.biometrickitd`, `com.apple.appleaccountd`, `com.apple.CacheDelete`, `com.apple.inputAnalytics*`, `com.apple.vmnet`, `com.apple.audio.SystemSettings`, `com.apple.coreservices.useractivityd*`, `com.apple.AccessibilityHearingNearby`, `com.apple.AppStore`, `com.apple.gamed`, `com.apple.gamecenter`, `com.apple.appleintelligencereporting`, `com.apple.GenerativeFunctions*`, `com.apple.SpeakSelection`, `com.microsoft.office`, `com.apple.ServicesMenu.Services`, `com.apple.AddressBook`.
- PlistBuddy filters: `FXRecentFolders`, `NSWindowTabbingShoudShowTabBarKey`, `ViewSettings`, `FXSync*`, `MRSActivityScheduler`.
- Key filters: `FK_SidebarWidth*`, `trash-full` (Dock), `*Analytics*`/`*Telemetry*`, `*lastBootstrap*`, `*LastLoadedOn*`, `NSLinguisticDataAssets*`, `*.column.*.width`, Sparkle `SU*`, `uses`, `launchCount`, `*reminder.date`, `*donate*`.

### Doc
- README scope: Safari and other Apple apps may not use plist-based preferences.

## 1.0.0 — 2026-02-12

### Release
- First official release as **PrefWatch** (renamed from Watch Preferences; script, README, LICENSE, CI, GitHub templates and repo `Gill0o/PrefWatch` all updated).

### Feature
- Contextual `# NOTE:` comments for keyboard layouts (logout/login) and Dock changes (`killall Dock`).
- Energy/battery monitoring via `pmset_watch()` — polls `pmset -g custom`, emits `pmset -b`/`-c` commands (ALL mode, beta).

### UX
- Snapshot progress (spinner + counter in terminal, clear Console.app messages).
- Python3 preflight in ALL mode: warns about limited detection if Xcode CLT/Python3 is missing, offers continue/abort, no CLT popup on fresh macOS (`xcode-select -p` checked first).

### Fix
- PlistBuddy paths with spaces escaped via `pb_escape()`; string values no longer single-quoted; PBCMD `Add` commands no longer filtered by `is_noisy_key`.

### Noise
- 40+ domain exclusions and global key patterns; PlistBuddy filters (`FXRecentFolders`, `NSWindowTabbingShoudShowTabBarKey`, `ViewSettings`, `NSToolbar Configuration`, `NSWindow Frame`, …).

### Note
- CUPS printer monitoring and print-preset filtering are **experimental (beta)**.

## 0.x — 2025-09 to 2026-02
- Internal development under the name **Watch Preferences** (v0.1.0 through v3.2-beta), renamed to PrefWatch in v1.0.0.
- No git history prior to v2.5.0 (local development without GitHub); Claude AI assisted since v2.0.0.
