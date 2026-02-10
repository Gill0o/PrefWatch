# Changelog

## 1.0.0 — 2026-02-11
- **RELEASE**: First official release as **PrefWatch**
  - Renamed project from Watch Preferences to PrefWatch
  - Updated all references: script, README, LICENSE, CI, GitHub templates
  - GitHub repo renamed to `Gill0o/PrefWatch`
- **NOTE**: CUPS printer monitoring and print preset filtering are **experimental (beta)**
  - `cups_watch()` and `com.apple.print.custompresets*` filtering may change in future versions

## 0.3.2-beta — 2026-02-10
- **FIX**: `$dom` variable undefined in `show_plist_diff` noise filter — used `$_dom` (correct scope)
- **FIX**: PlistBuddy paths wrong in ALL mode (root) — use actual file path instead of `get_plist_path`
- **CLEANUP**: Removed dead Python code (`shell_escape_single`, `format_value`) from `emit_array_additions`
- **CLEANUP**: Removed empty TextEdit case block (covered by global patterns)
- **PERF**: `dump_plist` now calls `plutil -p` once instead of twice (test + output)

## 0.3.1-beta — 2026-02-10
- **FIX**: Duplicate PlistBuddy commands — `skip_arrays` parameter was broken (passed `"skip_arrays"` instead of `"true"`)
- **FIX**: False Delete commands for transient cfprefsd writes — re-read live plist before emitting scalar Delete
- **FIX**: Domain mode now monitors excluded domains when explicitly requested (warn instead of exit)
- **FIX**: Scalar array elements (string/int/float/bool) now detected in `emit_array_additions`
- **FIX**: False Delete for value changes — pre-collect `_added_keys` from diff `+` lines
- **NOISE**: Added `NSStatusItem*` to global noisy key patterns
- **NOISE**: Added `com.apple.launchservices*` (lowercase) for case-sensitive zsh matching
- **NOISE**: Added domain exclusions: `com.apple.configurationprofiles*`, `com.apple.sharingd`,
  `com.apple.controlcenter.displayablemenuextras*`
- **DOCS**: Added Spotlight "Help Apple improve Search" to Known Limitations in README

## 0.3.0-beta — 2026-02-10
- **FEATURE**: CUPS printer monitoring — detect printer add/remove in ALL mode
  - New `cups_watch()` polls `lpstat` every 2s, emits `lpadmin -p`/`lpadmin -x` commands
  - Runs as third background process alongside `fs_watch` and `poll_watch`
- **FEATURE**: Print preset filtering for `com.apple.print.custompresets*` domains
  - Whitelist useful keys (Duplex, PageSize, ColorMode, Resolution, etc.)
  - Filter ~140 Fiery driver defaults and PPD metadata per preset
  - Suppress redundant flat key Delete commands when array deletion covers them
- **FIX**: Duplicate commands in ALL mode (fs_watch + poll_watch race condition)
  - Added `mkdir`-based file lock in `show_plist_diff` to serialize parallel access
  - Added `cmp` dedup to skip unchanged files
  - Pass `skip_arrays` to `show_domain_diff` in ALL mode call sites
- **FIX**: Added `*WindowBounds*|*WindowState*` to `is_noisy_key` and `is_noisy_command`
- **NOISE**: Added domain exclusions: `com.apple.dataaccess*`, `com.apple.assistant*`,
  `com.apple.tipsd`, `com.apple.proactive.PersonalizationPortrait*`, `com.apple.chronod`,
  `com.apple.studentd`, `com.openai.chat`, `ChatGPTHelper`, `com.segment.storage.*`,
  `com.microsoft.shared`

## 0.2.0-beta — 2026-02-08
- **RELEASE**: Code cleanup, documentation overhaul, repo reorganization
  - Removed dead code: `array_add_command()` and `extract_domain_from_defaults_cmd()` (64 lines)
  - README streamlined for clarity (removed verbose sections, lead with simplest use case)
  - CHANGELOG fully translated to English
  - Repo cleaned: removed internal dev files from tracking (versions/, pre-commit, release.sh)
  - All features from 0.1.x preserved, no functional changes

## 0.1.x — 2025-09 to 2026-02
- Internal beta development (formerly Watch Preferences v0.1.0 through v2.9.28-beta)
- Full history available in git log
