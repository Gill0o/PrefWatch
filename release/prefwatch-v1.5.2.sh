#!/bin/zsh
# ============================================================================
# Script: prefwatch.sh
# Version: 1.5.2
# Author: Gilles Bonpain
# Powered by Claude AI
# Description: Monitor and log changes to macOS preference domains
# ============================================================================
# Usage:
#
# CLI Mode (direct execution):
#   ./prefwatch.sh [domain] [OPTIONS]        [domain] defaults to ALL
#
#   Options and examples: `./prefwatch.sh --help` (show_help() below is the
#   single source for the CLI surface).
#
# Jamf Pro Mode (automatic detection):
#   When run via Jamf Pro, parameters are automatically shifted.
#   $1-$3 are Jamf reserved (mount_point, computer_name, username)
#
#   Jamf Parameters:
#     $4 = Domain (e.g., NSGlobalDomain, ALL or *)
#     $5 = Log path (optional). Default:
#          - ALL: /var/log/prefwatch-v<version>.log
#          - Domain: /var/log/prefwatch-v<version>-<domain>.log
#     $6 = INCLUDE_SYSTEM (true/false). Include system preferences (default: true)
#     $7 = ONLY_CMDS (true/false). Show only commands without debug (default: true)
#     $8 = EXCLUDE_DOMAINS. Comma-separated glob patterns to exclude
#          Example: ContextStoreAgent*,com.jamf*,com.adobe.*
#     $9 = MDM_OUTPUT (true/false). MDM deployment: wrap user-domain commands in
#          a runAsUser helper (root Jamf policy applies them as the logged-in
#          user) + templatize PlistBuddy paths ($loggedInUser, $UUID) (default: false)
#     $10 = HOT_DOMAINS. Comma-separated domains whose cfprefsd buffer is
#          flushed every poll cycle, so a first change surfaces in 1-2s instead
#          of ~10s. Default: the common System Settings panels (see the
#          HOT_DOMAINS array). Pass "NONE" to disable.
#     $11 = DEBUG (true/false). Log '# FILTERED: <dom> <key> (reason)' when a
#          detected change is suppressed (noise key / excluded domain). Equivalent
#          of the CLI --debug flag. Default: false.
#     $12 = FS_USAGE (true/false). DEPRECATED, removed in the next release:
#          also run the fs_usage real-time detector next to polling (measured
#          to add nothing polling does not; it takes the single ktrace slot).
#          CLI: --fs-usage. Default: false.
# ============================================================================

# Layout (grep the title to jump there):
#   CONFIGURATION            flags, Jamf parameters, hot domains, exclusions
#   FUNCTIONS
#     Preflight & Environment  get_console_user, _python3_validate
#     Utilities                get_timestamp, get_plist_path, domain_from_plist_path, …
#     Filtering                is_excluded_domain, is_noisy_key, is_noisy_command, …
#     Logging                  _log, log_line, log_user, …
#     Plist & PlistBuddy       dump_plist, dump_plist_json, extract_type_value_with_plutil, …
#     Command Emission         _escape_pb_path, _escape_dq, _build_defaults_write_cmd, …
#     Diff Engine              parse_array_index_key, emit_array_additions, _py_deletions_raw, …
#     Contextual NOTEs         _note_should_show, _note_dockutil_alt, _emit_contextual_note, …
#     Diff Drivers             show_plist_diff, show_domain_diff
#     Console & Process Tree   is_console_running, launch_console, _emit_mdm_resolver_header, …
#     Watcher Framework        _watcher_parse, _guard_nonempty, _snapshot_watch
#     Single-domain Mode       start_watch
#     ALL Mode (core)          start_watch_all
#     WATCHERS                 one function per out-of-plist setting (20)
#   MAIN                     pre-flight, log file, launch, teardown traps

# ============================================================================
# CONFIGURATION
# ============================================================================

# Execution security (zsh)
set -e
set -u
set -o pipefail

# On a `set -e` abort, log WHERE before the shell dies (ONLY_CMDS captures
# neither the abort nor stderr). Nothing logged and still dead = a SIGKILL.
TRAPZERR() {
  local _loc="${funcfiletrace[1]:-?}" _fn="${funcstack[2]:-main}"
  print -u2 "prefwatch: set -e ABORT at ${_loc} (in ${_fn})" 2>/dev/null || true
  printf '# ABORT: set -e at %s (in %s)\n' "$_loc" "$_fn" >> "${LOGFILE:-/tmp/prefwatch-abort.log}" 2>/dev/null || true
}

show_help() {
  cat << 'EOF'
Usage: prefwatch.sh [domain] [OPTIONS]

Monitor and log changes to macOS preference domains in real-time.

Arguments:
  [domain]              Preference domain to monitor (default: "ALL")
                        Examples: NSGlobalDomain, com.apple.finder, ALL

Options:
  -l, --log <path>      Custom log file path (default: auto-generated)
  -s, --include-system  Include system preferences in ALL mode (default: enabled)
  --no-system           Exclude system preferences in ALL mode
  -v, --verbose         Show detailed debug output with timestamps
  -q, --only-cmds       Show only executable commands (default)
  --debug               Log '# FILTERED: <dom> <key> (reason)' when a detected
                        change is suppressed (noise key / excluded domain).
                        answers "why didn't my change appear?"
  -e, --exclude <glob>  Comma-separated glob patterns to exclude
  --hot-domains <list>  Comma-separated list of domains kept permanently active
                        for instant first-change detection. Default: the common
                        System Settings panels (Finder, Dock, Control Center,
                        keyboard/trackpad/mouse, Accessibility, Spotlight, …).
                        Pass "NONE" to disable.
  -h, --help            Show this help message
  --mdm                 MDM deployment mode: wrap user-domain commands in a
                        runAsUser helper (a root Jamf policy applies them as the
                        logged-in user) and templatize PlistBuddy paths
                        ($loggedInUser home, $UUID for ByHost files)
  --no-console          Don't open Console.app and don't stop when it closes;
                        run until Ctrl+C / SIGTERM (interactive / VM testing)
  --fs-usage            DEPRECATED, removed in the next release. ALL mode as
                        root: also run the fs_usage real-time detector next to
                        polling. Measured, it added nothing polling did not, and
                        it takes the machine's single ktrace slot

Examples:
  # Monitor all domains (default behavior)
  ./prefwatch.sh
  ./prefwatch.sh -v
  ./prefwatch.sh --log /tmp/all-prefs.log

  # Monitor a specific domain
  ./prefwatch.sh NSGlobalDomain
  ./prefwatch.sh com.apple.finder -v

  # Monitor with exclusions
  ./prefwatch.sh -v --exclude "com.apple.Safari*,ContextStoreAgent*"

  # Monitor without system preferences
  ./prefwatch.sh --no-system

Jamf Pro Mode:
  Parameters are read from $4 onward ($1-$3 are Jamf-reserved):
    $4 domain · $5 log path · $6 include-system · $7 only-cmds · $8 exclusions
    $9 MDM output · $10 hot domains · $11 debug · $12 fs_usage
  Each is documented in full in the "Jamf Parameters" block at the top of this
  script. That header is the single source for them.

EOF
  exit 0
}

parse_cli_args() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_help
  fi

  DOMAIN="ALL"  # Default to ALL if no domain specified
  LOG_FILE_PARAM=""
  INCLUDE_SYSTEM_RAW="true"
  ONLY_CMDS_RAW="true"
  EXCLUDE_DOMAINS=""
  MDM_OUTPUT_RAW="false"
  DEBUG_FILTER_RAW="false"
  NO_CONSOLE_RAW="false"

  if [[ -n "${1:-}" && "${1}" != -* ]]; then
    DOMAIN="${1}"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      -l|--log)
        if [[ -z "${2:-}" ]]; then
          echo "Error: --log requires a path argument" >&2
          exit 1
        fi
        LOG_FILE_PARAM="${2}"
        shift 2
        ;;
      -s|--include-system)
        INCLUDE_SYSTEM_RAW="true"
        shift
        ;;
      --no-system)
        INCLUDE_SYSTEM_RAW="false"
        shift
        ;;
      -v|--verbose)
        ONLY_CMDS_RAW="false"
        shift
        ;;
      -q|--only-cmds)
        ONLY_CMDS_RAW="true"
        shift
        ;;
      --debug)
        # Log `# FILTERED: <dom> <key> (reason)` for each suppressed change.
        DEBUG_FILTER_RAW="true"
        shift
        ;;
      -e|--exclude)
        if [[ -z "${2:-}" ]]; then
          echo "Error: --exclude requires a pattern argument" >&2
          exit 1
        fi
        EXCLUDE_DOMAINS="${2}"
        shift 2
        ;;
      --hot-domains)
        if [[ -z "${2:-}" ]]; then
          echo "Error: --hot-domains requires a comma-separated list argument" >&2
          exit 1
        fi
        HOT_DOMAINS_RAW="${2}"
        shift 2
        ;;
      --mdm)
        MDM_OUTPUT_RAW="true"
        shift
        ;;
      --no-console)
        # No Console.app, no lifecycle tie to it: run until Ctrl+C / SIGTERM.
        NO_CONSOLE_RAW="true"
        shift
        ;;
      --fs-usage)
        # Deprecated in 1.5.1 (adds nothing polling does not, holds the ktrace
        # slot, reached 8 GB under load). Removed next release.
        FS_USAGE_RAW="true"
        shift
        ;;
      -h|--help)
        show_help
        ;;
      *)
        echo "Error: Unknown option: ${1}" >&2
        echo "Use --help for usage information" >&2
        exit 1
        ;;
    esac
  done
}

# Jamf passes mount_point, computer_name, username as $1-$3, user params at $4+.
JAMF_MODE="false"
if [[ -n "${1:-}" && "${1}" == /* ]] && [[ -n "${2:-}" ]] && [[ -n "${3:-}" ]]; then
  JAMF_MODE="true"
fi

if [ "$JAMF_MODE" = "true" ]; then
  DOMAIN="${4:-ALL}"
  LOG_FILE_PARAM="${5:-}"
  INCLUDE_SYSTEM_RAW="${6:-true}"
  ONLY_CMDS_RAW="${7:-true}"
  EXCLUDE_DOMAINS="${8:-}"
  MDM_OUTPUT_RAW="${9:-false}"
  # Only when $10 is non-empty, so the default HOT_DOMAINS array survives.
  [ -n "${10:-}" ] && HOT_DOMAINS_RAW="${10}"
  DEBUG_FILTER_RAW="${11:-false}"
  FS_USAGE_RAW="${12:-false}"
else
  parse_cli_args "$@"
fi

to_bool() {
  case "$(printf "%s" "${1:-}" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on|enable|enabled|oui|vrai) echo "true";;
    *) echo "false";;
  esac
}
ONLY_CMDS=$(to_bool "$ONLY_CMDS_RAW")
INCLUDE_SYSTEM=$(to_bool "$INCLUDE_SYSTEM_RAW")
MDM_OUTPUT=$(to_bool "$MDM_OUTPUT_RAW")
DEBUG_FILTER=$(to_bool "${DEBUG_FILTER_RAW:-false}")
NO_CONSOLE=$(to_bool "${NO_CONSOLE_RAW:-false}")
FS_USAGE=$(to_bool "${FS_USAGE_RAW:-false}")

# MDM mode: home becomes /Users/$loggedInUser and a ByHost filename
# <domain>.$UUID.plist. `defaults -currentHost` needs none of this.
mdm_plist_path() {
  local _p="$1"
  if [ "$MDM_OUTPUT" = "true" ]; then
    [[ "$_p" == "$TARGET_HOME"* ]] && _p="/Users/\$loggedInUser${_p#$TARGET_HOME}"
    if [[ "$_p" == */ByHost/* ]]; then
      _p=$(printf '%s' "$_p" | /usr/bin/sed -E 's/\.[0-9A-Fa-f-]{8,}\.plist$/.$UUID.plist/') || _p="$1"
    fi
  fi
  printf '%s' "$_p"
}

# Same home rewrite for paths inside emitted VALUES (dock _CFURLString, …).
typeset -g _MDM_HOME_REPL='/Users/$loggedInUser'
# Inside a single-quoted PlistBuddy `-c '…'`, $loggedInUser must break out of
# the quotes: _MDM_LIU_QB is that quote-broken form.
typeset -g _MDM_LIU='$loggedInUser'
typeset -g _MDM_LIU_QB="'${_MDM_LIU}'"

unsetopt xtrace verbose 2>/dev/null || true

# ---------------------------------------
# CONFIGURATION. Real-time detector ceiling
# ---------------------------------------

# fs_usage buffers every unwritten event (8 GB five minutes into a Spotlight
# reindex, measured). Past this RSS fs_watch kills it; polling carries on.
typeset -gi FS_USAGE_RSS_LIMIT_MB="${PREFWATCH_FS_USAGE_RSS_LIMIT_MB:-1024}"

# ---------------------------------------
# CONFIGURATION. Hot domains
# ---------------------------------------

# Hot domains get a cfprefsd flush every poll: a first change shows in 1-2s
# instead of ~10s. Override via --hot-domains / Jamf $10 ("NONE" disables).
typeset -a HOT_DOMAINS=(
  # Shell / appearance
  com.apple.finder
  .GlobalPreferences
  com.apple.dock
  com.apple.controlcenter
  com.apple.WindowManager
  com.apple.systemuiserver                             # legacy menu-bar extras
  com.apple.menuextra.clock                            # menu-bar clock format (ShowAMPM/Date/DayOfWeek)
  # Input. Keyboard / shortcuts / trackpad / mouse (all standard plists here, not ByHost)
  com.apple.HIToolbox
  com.apple.symbolichotkeys                            # keyboard shortcuts
  com.apple.AppleMultitouchTrackpad
  com.apple.driver.AppleBluetoothMultitouch.trackpad
  com.apple.AppleMultitouchMouse
  com.apple.driver.AppleBluetoothMultitouch.mouse
  # Accessibility / search / screenshots
  com.apple.universalaccess
  com.apple.Accessibility                              # newer accessibility domain (VoiceOver, zoom, …)
  com.apple.mediaaccessibility                         # captions / subtitles appearance
  com.apple.Spotlight
  com.apple.screencapture                              # screenshot location / format
  # Lock screen / software update
  com.apple.screensaver                                # idle timing lives in ByHost (caught by fs_watch)
  com.apple.SoftwareUpdate
  # NOT hot: empty, outside Preferences, daemon-churned, or has its own watcher.
)
if [ -n "${HOT_DOMAINS_RAW:-}" ]; then
  if [ "$HOT_DOMAINS_RAW" = "NONE" ] || [ "$HOT_DOMAINS_RAW" = "none" ]; then
    HOT_DOMAINS=()
  else
    HOT_DOMAINS=("${(@s:,:)HOT_DOMAINS_RAW}")
  fi
fi

# ---------------------------------------
# CONFIGURATION. Exclusions
# ---------------------------------------

# Noisy domains. Override with --exclude or Jamf $8.
typeset -a DEFAULT_EXCLUSIONS=(
  # Background daemons & agents
  "com.apple.cfprefsd*"
  "com.apple.notificationcenterui*"
  "com.apple.ncplugin*"
  "com.apple.knowledge-agent"
  "com.apple.DuetExpertCenter*"
  "com.apple.xpc.activity2"
  "com.apple.powerlogd"
  "ContextStoreAgent*"

  # Clock/Timer daemon: live timer instances (fresh UUIDs, countdowns), no prefs.
  "com.apple.mobiletimerd"

  # Cloud sync internals
  "com.apple.CloudKit*"
  "com.apple.bird*"
  "com.apple.cloudd"
  "com.apple.CallHistorySyncHelper"
  "com.apple.appleaccountd"
  "com.apple.appleaccount"
  "com.apple.shazamd"
  "com.apple.wallpaper.aerial"
  "com.apple.osprey"
  "com.apple.imessage.bag"
  "com.apple.facetime.bag"
  "com.apple.gridDataServices"
  "com.apple.CloudSubscriptionFeatures*"
  "com.apple.AudioAccessory"
  "com.apple.systemsettings.extensions*"
  "com.apple.networkserviceproxy"
  "journal"
  "com.apple.remindd*"

  # System maintenance & cache
  "com.apple.CacheDelete"

  # Security & crash reporting
  "com.apple.CrashReporter"
  # Only the known noisy com.apple.security sub-domains, not .authorization.
  "com.apple.security.cloudkeychainproxy3*"  # glob: also covers .keysToRegister sidecar (sync queue)
  "com.apple.security.sosaccount"            # iCloud Keychain sync-circle state (SOSEnabled/ghostbustdate). Securityd-managed, not a defaults-settable pref
  "com.apple.filevault"                      # FileVault ByHost state ONLY (lastAnalyticsEvent dict, recoveryKeyCreatorUID/Invalid, lastEnabledProductVersion). Daemon-written after enabling; no reproducible pref. Real control is fdesetup → security_watch emits the FileVault NOTE
  "com.apple.security.smartcard"
  "com.apple.securityagent"
  "com.apple.securityd"
  "com.apple.biometrickitd"

  # Accessibility internals (auth warnings, hearing device state)
  "com.apple.universalaccessAuthWarning"
  "com.apple.AccessibilityHearingNearby"
  "com.apple.SpeakSelection"

  # Network internals
  "com.apple.networkextension*"
  "com.apple.wifi.known-networks"
  "com.apple.vmnet"
  "com.apple.LaunchServices*"  # zsh globs are case-sensitive, need both
  "com.apple.launchservices*"
  "com.apple.apsd"

  # Backup internals. com.apple.TimeMachine itself holds real prefs.
  "com.apple.timemachine.helper"
  "com.apple.timemachine.agent"

  # Graphics internals (updates on every window change)
  "com.apple.CoreGraphics"

  # App store internals
  "com.apple.appstored"
  "com.apple.AppStore"
  "com.apple.AppleMediaServices*"

  # Game Center internals (daemon state)
  "com.apple.gamed"
  "com.apple.gamecenter"

  # Input analytics / telemetry
  "com.apple.inputAnalytics*"
  "com.apple.commerce.knownclients"           # App Store known-client blobs, one per client and pid
  "com.apple.anvil.*"                         # ChatGPT integration daemon: per-uid rate-limit flags
  "com.apple.appleintelligencereporting"
  # Apple's analytics agent. Sync timestamps / usage counters only (AppUsageSyncTime)
  "com.apple.analyticsagent"
  "com.apple.GenerativeFunctions*"

  # MetricKit bookkeeping, rewritten on every MetricKit query of any app.
  "com.apple.metrickitd"

  # ML rate limiter (token bucket counters/timestamps for embedding processing)
  "TokenBucketRateLimiter"

  # Emoji search cache (auto-generated locale emoji lists)
  "com.apple.EmojiCache"

  # Calculator currency cache (auto-updated exchange rates)
  "com.apple.calculateframework"

  # com.apple.SoftwareUpdate is NOT excluded: real prefs, noise filtered per key.

  # Power management internals (constant battery updates)
  "com.apple.PowerManagement*"
  "com.apple.BackgroundTaskManagement*"  # zsh globs are case-sensitive
  "com.apple.backgroundtaskmanagement*"

  # Audio internals (device routing state)
  "com.apple.audio.SystemSettings"

  # User activity tracking (Handoff/Continuity state)
  "com.apple.coreservices.useractivityd*"

  # System internals. loginwindow is NOT excluded: real policies, churn filtered per key.
  "com.apple.spaces"
  "com.apple.BezelServices"
  "com.apple.jetpackassetd"
  "com.apple.windowserver*"
  "com.apple.settings.Storage"
  "diagnostics_agent"
  "com.apple.diagnosticd*"
  "Avatar Cache*"

  # Services menu localization cache (auto-regenerated)
  "com.apple.ServicesMenu.Services"


  # Directory Utility UI state; real AD/LDAP bindings live in OpenDirectory.
  "com.apple.DirectoryUtility"

  # Calendar internals (account UUIDs, UI state)
  "com.apple.iCal"

  # Messages preview rendering internals (screen scale, dimensions)
  "com.apple.MobileSMSPreview"

  # Notification Center internal state (app path tracking, binary blobs)
  "com.apple.ncprefs"

  # Account existence tracking
  "com.apple.accounts.exists"

  # iCloud services: a positional array whose indices shift between releases.
  "MobileMeAccounts"

  # Find My device daemon (APS tokens, internal state)
  "com.apple.icloud.fmfd"

  # Telephony framework internals (camera/call state)
  "com.apple.TelephonyUtilities"

  "com.apple.itunescloud"
  "com.apple.itunescloudd"
  # Media library daemon: flags and IDs, no prefs (the com.apple.amp* glob is case-sensitive).
  "com.apple.AMPLibraryAgent"

  # ShazamKit: CloudKit cache and tokens only.
  "com.apple.ShazamKit"

  # Find My app & framework (UI state, window geometry, precision flags)
  "com.apple.findmy*"
  "com.apple.icloud.searchpartyuseragent"

  # Weather framework (daemon-managed; user prefs live in internal DB since Sonoma)
  "com.apple.weather*"

  # AirPlay/Handoff proximity daemon (pruning timestamps, internal state)
  "com.apple.rapport"

  # iMessage internals (Spotlight indexing, identity services, agent state, sync errors)
  "com.apple.IMCoreSpotlight"
  "com.apple.identityservicesd"
  "com.apple.imagent"
  "com.apple.madrid"
  "com.apple.SafariCloudHistoryPushAgent"
  "com.apple.powerlogHelperd"               # power-log helper: boot session UUID and an hour-bucket offset, rewritten per boot (system domain, checked on 27.0)
  "com.apple.gms.availability"              # Apple Intelligence availability cache: boot UUIDs, ever-installed apps, indexing state, reasons blob. No toggle here (checked on 27.0)
  "com.apple.voicetrigger.notbackedup"      # Siri voice-profile enrollment id + its date, power-logging asset version and language. State only; the toggles live in com.apple.voicetrigger (checked on 27.0)
  "com.apple.SafariBookmarksSyncAgent"      # sync tokens, account hash, migration blobs, last-launched versions. Daemon state only, no key a user sets (checked on 27.0)

  # Books data store (migration state, cache tasks)
  "com.apple.bookdatastored"

  # Network internals (daemon state, interface registry)
  "com.apple.networkd"
  "NetworkInterfaces"

  # Auto-wake scheduler (PIDs, alarm names, internal state)
  "com.apple.AutoWake"

  # HomeKit daemon (generation counters, internal state)
  "com.apple.homed"

  # Siri internals (autocomplete counters, suggestions tracking)
  "com.apple.siri.DialogEngine"
  "com.apple.siri.sirisuggestions"
  "com.apple.siriknowledged"
  # Siri/Spotlight suggestions backend: server-driven URL cache, no prefs.
  "com.apple.parsecd"

  # Downloaded TTS/dictation voices: an action, not a pref.
  "com.apple.voiceservices"

  # iStat Menus status data (satellite TLE, sensor readings)
  "com.bjango.istatmenus.status"

  # MonitorControl brightness/contrast values (constant adjustments)
  "app.monitorcontrol.MonitorControl"

  # Legacy (obsolete, replaced by systemsettings)
  "com.apple.systempreferences"

  # MDM & Jamf internals (if using Jamf Pro)
  "com.jamf*"
  "com.jamfsoftware*"
  "com.apple.classroom"

  # Media analysis daemon (photo library paths, internal state)
  "com.apple.mediaanalysisd"

  # Apple Finance daemon (CloudKit account cache)
  "com.apple.financed"

  # Biome sync daemon (behavioral telemetry, CloudKit cache)
  "com.apple.biomesyncd"

  # Protected CloudKit keychain sync (CloudKit account cache)
  "com.apple.protectedcloudstorage*"

  # Data Delivery Services (metadata sync timestamps)
  "com.apple.DataDeliveryServices"

  # Crash Reporter (TrialCache timestamps)
  "com.apple.ReportCrash"

  # Home energy daemon (CloudKit sync cache)
  "com.apple.homeenergyd"

  # Secure Element daemon (Apple Pay/NFC session counters)
  "com.apple.seserviced"

  # VirtualBuddy (VM app window state, UI settings)
  "codes.rambo.VirtualBuddy"

  # Adobe Genuine Service (licensing/consent daemon).
  "com.adobe.AdobeGenuineService"

  # Spotlight knowledge daemon (internal sync counters, timestamps)
  "com.apple.spotlightknowledged.pipeline"

  # TeamViewer internals (AI nudge, license, version, UI phases)
  "com.teamviewer*"

  # IPv6 DHCP daemon (interface changes on device connect)
  "com.apple.dhcp6d"

  # QuickLook daemon (plugin modification timestamps)
  "com.apple.QuickLookDaemon"

  # Squirrel (Electron) updaters: SQRL* keys written and deleted around each update.
  "*.ShipIt"

  # Third-party updaters & telemetry
  "com.microsoft.autoupdate*"
  "com.microsoft.shared"
  "com.microsoft.office"
  "com.microsoft.OneDriveUpdater"
  "*.zoom.updater*"
  "com.openai.chat"
  "ChatGPTHelper"
  "com.segment.storage.*"

  # Background observers (constant telemetry)
  "com.apple.suggestions.*Observer*"
  "com.apple.personalizationportrait.*Observer*"

  # Cellular/comm internals (boot counters, modem state)
  "com.apple.commcenter*"

  # Ad platform internals (correlation IDs, tracking counters)
  "com.apple.AdPlatforms"

  # Background event counters & sync telemetry
  "com.apple.cseventlistener"
  "com.apple.spotlightknowledge"
  "com.apple.SpotlightKnowledge"   # zsh globs are case-sensitive. The real domain is CamelCase (hdbCutover.*.evaluationCount counters)
  "com.apple.amsengagementd"
  "com.apple.StatusKitAgent"
  "com.apple.Accessibility.Assets"
  "com.apple.AOSKit*"

  # Data sync daemons (CalDAV/CardDAV/Exchange account refresh states)
  "com.apple.dataaccess*"

  # Siri daemon churn. com.apple.assistant.support (real Siri prefs) is NOT excluded.
  "com.apple.assistant"
  "com.apple.assistant.backedup"
  "com.apple.assistantd"

  # Tips, personalization & time sync (notification counters, ML internals, clock daemon)
  "com.apple.tipsd"
  "com.apple.proactive.PersonalizationPortrait*"
  "com.apple.chronod"
  "com.apple.studentd"
  "com.apple.configurationprofiles*"
  "com.apple.controlcenter.displayablemenuextras*"
  "com.apple.NewDeviceOutreach"
  "com.apple.settings.storage*"
  "com.apple.StorageManagement*"
  "com.apple.MIDI*"
  "com.apple.corespotlightui"
  "com.apple.textunderstanding*"
  # The xctest scratch domain: every `swift test` writes and deletes here.
  "com.apple.dt.xctest.tool"

  # dock, finder, Safari, systemsettings, Mail, Messages, Music, TV, sharingd, …
  # are filtered per KEY in is_noisy_key, not excluded.
)

if [ -n "${EXCLUDE_DOMAINS:-}" ]; then
  EXCLUDE_DOMAINS_RAW="$EXCLUDE_DOMAINS"
else
  EXCLUDE_DOMAINS_RAW="${(j:,:)DEFAULT_EXCLUSIONS}"
fi

typeset -a EXCLUDE_PATTERNS _raw_excl
IFS=',' read -rA _raw_excl <<< "$EXCLUDE_DOMAINS_RAW"
EXCLUDE_PATTERNS=()
for p in "${_raw_excl[@]}"; do
  # Trim in zsh: a `printf | sed` capture dies under pipefail on invalid UTF-8.
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  [ -n "$p" ] && EXCLUDE_PATTERNS+=("$p")
done

ALL_MODE="false"
case "${DOMAIN}" in
  ALL|all|'*') ALL_MODE="true" ;;
esac

# ============================================================================
# FUNCTIONS
# ============================================================================

# ---------------------------------------
# Preflight & Environment
# ---------------------------------------

get_console_user() {
  /usr/bin/stat -f %Su /dev/console 2>/dev/null || /usr/bin/id -un
}

CONSOLE_USER="${CONSOLE_USER:-$(get_console_user)}"

RUN_AS_USER=()
if [ "$(id -u)" -eq 0 ] && [ "$CONSOLE_USER" != "root" ]; then
  RUN_AS_USER=(/usr/bin/sudo -u "$CONSOLE_USER" -H)
fi

# Root (Jamf): $HOME is /var/root, user prefs live in the console user home.
TARGET_HOME="$HOME"
if [ "$(id -u)" -eq 0 ] && [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
  _resolved_home=$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}') || true
  if [ -n "$_resolved_home" ]; then
    TARGET_HOME="$_resolved_home"
  elif [ -d "/Users/$CONSOLE_USER" ]; then
    TARGET_HOME="/Users/$CONSOLE_USER"
  fi
fi

HAVE_BIN_DATE="false"
[ -x /bin/date ] && HAVE_BIN_DATE="true"

# /usr/bin/python3 is a stub that pops the CLT install dialog: check CLT first.
PYTHON3_BIN=""
_python3_validate() {
  local candidate="$1"
  if "$candidate" -c 'import json; print("ok")' >/dev/null 2>&1; then
    PYTHON3_BIN="$candidate"
    return 0
  fi
  return 1
}

_clt_installed=false
if /usr/bin/xcode-select -p >/dev/null 2>&1; then
  _clt_installed=true
fi

if [ "$_clt_installed" = "true" ] && [ -x /usr/bin/python3 ] && _python3_validate /usr/bin/python3; then
  : # validated via CLT python3
elif command -v python3 >/dev/null 2>&1; then
  # Non-system python3 (Homebrew, pyenv): safe without CLT.
  _candidate="$(command -v python3)"
  if [ "$_candidate" != "/usr/bin/python3" ] && _python3_validate "$_candidate"; then
    : # validated via alternative python3
  fi
fi

# Temp directory + EXIT trap for every MAIN exit path.
PREFWATCH_TMPDIR=$(/usr/bin/mktemp -d "/tmp/prefwatch.${$}.XXXXXX") || PREFWATCH_TMPDIR="/tmp/prefwatch.${$}"
/bin/mkdir -p "$PREFWATCH_TMPDIR" 2>/dev/null || true
trap '/bin/rm -rf "$PREFWATCH_TMPDIR" 2>/dev/null || true' EXIT

# Reclaim tmpdirs of crashed runs.
for _stale in /tmp/prefwatch.[0-9]*(N/); do
  _stale_pid="${${_stale:t}#prefwatch.}"
  _stale_pid="${_stale_pid%%.*}"
  [ "$_stale_pid" = "$$" ] && continue
  /bin/kill -0 "$_stale_pid" 2>/dev/null && continue
  /bin/rm -rf "$_stale" 2>/dev/null || true
done
unset _stale _stale_pid

typeset -A _EXCLUSION_CACHE  # Cache for domain exclusion checks
CACHE_DIR=""                  # Cache directory for plist diffs (WATCH_ALL mode)

DOMAIN_TAG="$DOMAIN"
[ "$ALL_MODE" = "true" ] && DOMAIN_TAG="all"

SCRIPT_VERSION=$(head -20 "$0" 2>/dev/null | /usr/bin/grep "^# Version:" | /usr/bin/sed -E 's/^# Version: //' | head -1) || true
[ -z "$SCRIPT_VERSION" ] && SCRIPT_VERSION="unknown"

if [ -n "$LOG_FILE_PARAM" ]; then
  LOGFILE="$LOG_FILE_PARAM"
else
  if [ "$ALL_MODE" = "true" ]; then
    LOGFILE="/var/log/prefwatch-v${SCRIPT_VERSION}.log"
  else
    LOGFILE="/var/log/prefwatch-v${SCRIPT_VERSION}-${DOMAIN}.log"
  fi
fi

# ---------------------------------------
# Utilities
# ---------------------------------------

zmodload zsh/datetime 2>/dev/null && HAVE_ZSH_STRFTIME=true || HAVE_ZSH_STRFTIME=false
zmodload zsh/stat 2>/dev/null && HAVE_ZSH_STAT=true || HAVE_ZSH_STAT=false
zmodload zsh/system 2>/dev/null && HAVE_ZSH_SYSTEM=true || HAVE_ZSH_SYSTEM=false

get_timestamp() {
  if [ "$HAVE_ZSH_STRFTIME" = "true" ]; then
    local _ts
    strftime -s _ts '%Y-%m-%d %H:%M:%S' "$EPOCHSECONDS"
    printf '%s' "$_ts"
  elif [ "$HAVE_BIN_DATE" = "true" ]; then
    /bin/date '+%Y-%m-%d %H:%M:%S'
  else
    date '+%Y-%m-%d %H:%M:%S'
  fi
}

get_plist_path() {
  local domain="$1"
  if [[ "$domain" =~ ^/ ]]; then
    printf '%s' "$domain"
  elif [ "${_EMIT_SYS:-false}" = "true" ]; then
    # System pref: the real /Library/Preferences path when one was recorded.
    printf '%s' "${_EMIT_SYS_DOM:+${_EMIT_SYS_DOM}.plist}"
    [ -n "${_EMIT_SYS_DOM:-}" ] || printf '%s' "/Library/Preferences/${domain}.plist"
  else
    printf '%s' "$TARGET_HOME/Library/Preferences/${domain}.plist"
  fi
}

# Domain from a .plist path, fork-free (runs on every event); strips the ByHost UUID.
domain_from_plist_path() {
  local p="$1" base dom
  base="${p:t}"
  dom="${base%.plist}"
  [[ "$dom" =~ '\.[0-9A-Fa-f-]{8,}$' ]] && dom="${dom%.*}"
  printf '%s\n' "$dom"
}

get_plist_path_for_domain() {
  local domain="$1"
  local plist_path=""

  if [ "$domain" = "NSGlobalDomain" ] || [ "$domain" = ".GlobalPreferences" ]; then
    plist_path="$TARGET_HOME/Library/Preferences/.GlobalPreferences.plist"
    [ -f "$plist_path" ] && echo "$plist_path" && return 0
  fi

  plist_path="$TARGET_HOME/Library/Containers/${domain}/Data/Library/Preferences/${domain}.plist"
  [ -f "$plist_path" ] && echo "$plist_path" && return 0

  plist_path="$TARGET_HOME/Library/Preferences/${domain}.plist"
  [ -f "$plist_path" ] && echo "$plist_path" && return 0

  plist_path="$TARGET_HOME/Library/Preferences/ByHost/${domain}."*".plist"
  # No ByHost file: `ls` fails, and pipefail + set -e would abort.
  plist_path=$(/bin/ls $plist_path 2>/dev/null | head -1) || plist_path=""
  [ -n "$plist_path" ] && [ -f "$plist_path" ] && echo "$plist_path" && return 0

  return 1
}

typeset -gA _HASH_CACHE=()
hash_path() {
  local p="$1"
  if [ -n "${_HASH_CACHE[$p]+isset}" ]; then
    printf '%s\n' "${_HASH_CACHE[$p]}"
    return
  fi
  local h
  if command -v /sbin/md5 >/dev/null 2>&1; then
    h=$(/sbin/md5 -qs "$p" 2>/dev/null) || h=$(printf '%s' "$p" | /usr/bin/cksum | /usr/bin/awk '{print $1}')
  else
    h=$(printf '%s' "$p" | /usr/bin/cksum | /usr/bin/awk '{print $1}')
  fi
  _HASH_CACHE[$p]="$h"
  printf '%s\n' "$h"
}

init_cache() {
  if [ -z "$CACHE_DIR" ]; then
    CACHE_DIR="$PREFWATCH_TMPDIR/cache"
    /bin/mkdir -p "$CACHE_DIR" 2>/dev/null || true
  fi
}

prepare_logfile() {
  local path="$1"
  /bin/mkdir -p "$(/usr/bin/dirname "$path")" 2>/dev/null || true
  if ! ( : > "$path" ) 2>/dev/null; then
    local fname
    fname="$(/usr/bin/basename "$path")"
    path="/tmp/${fname}"
    # /tmp fallback: a predictable name another user can pre-create as a symlink.
    # Accept only a plain file we own; test -L first (`-e` follows the link).
    if [ -L "$path" ] || { [ -e "$path" ] && { [ ! -f "$path" ] || [ ! -O "$path" ]; }; }; then
      path="${path%.log}.$$.log"
    fi
    : > "$path" 2>/dev/null || true
  fi
  # The log holds TCC, network, shares and account names: owner-only.
  /bin/chmod 600 "$path" 2>/dev/null || true
  # Under sudo hand the file to the console user so Console.app can read it.
  # /usr/bin/id, not `id`: `local path` here shadows PATH.
  if [ "$(/usr/bin/id -u)" -eq 0 ] && [ -n "${CONSOLE_USER:-}" ] && [ "$CONSOLE_USER" != "root" ]; then
    /usr/sbin/chown "$CONSOLE_USER" "$path" 2>/dev/null || true
  fi
  echo "$path"
}

# y/n prompt. 0 yes, 1 no, 2 no channel or timeout. stdin, then /dev/tty,
# then an osascript dialog as the console user (5-min timeout).
prompt_yn() {
  local prompt="$1" answer=""

  if [ -t 0 ]; then
    printf "%s (y/n) " "$prompt"
    read -r answer || return 2
    case "$answer" in [Yy]*) return 0 ;; *) return 1 ;; esac
  fi

  if [ -c /dev/tty ] && : </dev/tty 2>/dev/null; then
    printf "%s (y/n) " "$prompt" >/dev/tty 2>/dev/null || true
    if read -r answer </dev/tty 2>/dev/null; then
      case "$answer" in [Yy]*) return 0 ;; *) return 1 ;; esac
    fi
  fi

  # GUI fallback; `on run argv` passes the prompt with no escaping.
  if [ -n "${CONSOLE_USER:-}" ] && [ "$CONSOLE_USER" != "root" ] \
     && [ -x /usr/bin/osascript ]; then
    local uid result rc=1
    uid=$(id -u "$CONSOLE_USER" 2>/dev/null) || uid=""
    if [ -n "$uid" ]; then
      local osa='on run argv
display dialog (item 1 of argv) buttons {"No", "Yes"} default button "Yes" with icon caution with title "PrefWatch" giving up after 300
end run'
      if [ "$(id -u)" -eq 0 ]; then
        result=$(/bin/launchctl asuser "$uid" /usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/osascript -e "$osa" "$prompt" 2>/dev/null)
        rc=$?
      else
        result=$(/usr/bin/osascript -e "$osa" "$prompt" 2>/dev/null)
        rc=$?
      fi
      if [ $rc -eq 0 ]; then
        if [[ "$result" == *"gave up:true"* ]]; then
          return 2
        elif [[ "$result" == *"Yes"* ]]; then
          return 0
        else
          return 1
        fi
      fi
    fi
  fi

  return 2
}

# ---------------------------------------
# Filtering
#
# To exclude a noisy domain:  add its name to DEFAULT_EXCLUSIONS (glob patterns supported)
# To filter a noisy key:      add a pattern to is_noisy_key(). Automatically applies
#                              to both 'defaults' and PlistBuddy output
# ---------------------------------------

is_excluded_domain() {
  local d="$1"

  if [ -n "${_EXCLUSION_CACHE[$d]+isset}" ]; then
    return ${_EXCLUSION_CACHE[$d]}
  fi

  local p result=1
  for p in "${EXCLUDE_PATTERNS[@]}"; do
    [[ -z "$p" ]] && continue
    if [[ "$d" == ${~p} ]]; then
      result=0
      break
    fi
  done

  _EXCLUSION_CACHE[$d]=$result
  return $result
}

# Filter noisy keys while keeping real preferences.
is_noisy_key() {
  local domain="$1" keyname="$2"

  # ========================================================================
  # GLOBAL NOISY PATTERNS (apply to all domains)
  # ========================================================================

  case "$keyname" in
    # Sidebar icon size, a real pref. Must precede the NSTableView* glob.
    NSTableViewDefaultSizeMode) return 1 ;;
    # Window and UI state. NSStatusItem* is global (menu-bar apps), deliberately.
    NSWindow\ Frame*|NSNavPanel*|NSSplitView*|NSTableView*|NSStatusItem*|*ItemPreferredPositions*|*WindowBounds*|*WindowState*|*WindowFrame*|*WindowOriginFrame*|*WindowLocation|WindowLeft|WindowTop|*PreferencesWindow*|*.column.*.width|*.column.*.width.*|*_frame|NSOSPLastRootDirectory|NSNavLastRootDirectory|recentlyPlayed*|*SidebarWidth*)
      return 0 ;;

    # App-controlled macOS menu item overrides (set by app, not user)
    NSDisabledCharacterPaletteMenuItem|NSFullScreenMenuItemEverywhere)
      return 0 ;;

    # Apple Intelligence availability mirrored into the ByHost global domain.
    com.apple.gms.*)
      return 0 ;;

    # AVKit duration/remaining toggle, written into every host app.
    AVDesktopPlaybackControlsController*)
      return 0 ;;

    # NSToolbar Configuration <UUID>: per-instance layout, not portable.
    # Named configs (…Configuration Browser) are kept.
    NSToolbar\ Configuration\ [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f]*)
      return 0 ;;

    # Sparkle updater state. SUSendProfileInfo (an opt-in) is kept.
    SUUpdateGroupIdentifier|SULastCheckTime|SUHasLaunchedBefore|SUSkippedVersion|SUUpdateRelaunchingMarker)
      return 0 ;;

    # Timestamps, universal.
    *timestamp*|*Timestamp*|*TimeStamp*|*-timestamp|*LastUpdate*|*LastSeen*|*-last-seen|*-last-update|*-last-modified|*LastRetry*|*LastSync*|*lastRetry*|*lastSync*|*StartupTime*|*StartTime*|*CheckTime|lastCheckTime|*LastSuccess*|*lastSuccess*|*LastKnown*|*lastKnown*|*LastLoadedOn*|*lastProcessed*|*LastProcessed*|*LastBackup*|*lastBackup*|*lastAppUpdateCheck*|*LastAppUpdateCheck*|*last*Date|*Last*Date|*.lastUpdated)
      return 0 ;;

    # Bare *Date would mask ExpirationDate; "last…Date" is always a timestamp.

    # HockeyApp / App Center session timestamps.
    BIT*Time)
      return 0 ;;

    # Error states & sync errors (transient)
    *Error|*Errors|*error|*errors|*ErrorCode*|*ErrorDomain*|*ErrorUserInfo*|IMCloudKitSyncErrors|IMSerializedError*)
      return 0 ;;

    # Rollout configs & A/B testing (system telemetry)
    rollouts|rolloutId|deploymentId|*RolloutId|*DeploymentId)
      return 0 ;;

    # Analytics counters and stamps. Opt-in toggles (AnalyticsEnabled…) are kept.
    *AnalyticsQueue*|*AnalyticsSession*|*AnalyticsEvent*|*TelemetryEvent*|*TelemetrySession*|*TelemetryQueue*|*BootstrapTime*|*lastBootstrap*|*HeartbeatDate*|*SKPurchaseIntent*|*-analytics-stamp)
      return 0 ;;

    # Device/Library/Session IDs (change per device)
    *-library-id|*-persistent-id|*-session-id|*-device-id|shared-library-id|devices-persistent-id|SessionId|SessionVersion|SessionLongBuildNumber|CampaignManagerVersionKey)
      return 0 ;;

    # System-managed localization (auto-generated from language settings)
    preferredLocalizations)
      return 0 ;;

    # UUIDs (transient identifiers).
    uuid|UUID|*UUID|*uuid)
      return 0 ;;

    # VoiceOver internal state (Braille defaults, display text timestamps)
    SCRC*|SCRDisplay*)
      return 0 ;;

    # Feature flags, except com.apple.universalaccess feature.* (real settings).
    feature.*)
      [ "$domain" = "com.apple.universalaccess" ] || return 0 ;;



    # Dynamic system info (internal state)
    SystemInfoDynamic.*)
      return 0 ;;

    # Metadata/sync counters (change constantly)
    *ChangeCount*|*MetaDataChange*|*ChangeToken*|*DataSequenceKey*)
      return 0 ;;

    # File metadata (changes on every file operation)
    parent-mod-date|file-mod-date|mod-count|file-type)
      return 0 ;;


    # Recent items and history. HistoryAgeInDaysLimit, EnableHistory are kept.
    *RecentFolders|*RecentDocuments|*RecentSearches|*HistoryItems*|*HistoryMetadata*|*HistoryList*|NSRecentDocumentsHistory|*HistoryDatabase*|*RecentlyUsed*|*recency*|*Recency*)
      return 0 ;;

    # Finder sync state (iCloud Drive extension toolbar)
    FXSync*)
      return 0 ;;

    # Linguistic data assets (spell checker internal state)
    NSLinguisticDataAssets*)
      return 0 ;;

    # Third-party update schedulers (background check timestamps)
    MRSActivityScheduler)
      return 0 ;;

    # Launch counters and donation reminders.
    launchCount|*reminder.date|*donateDialogShown*|*lastDonateDate*)
      return 0 ;;

    # Migration flags (one-time internal state)
    *DidMigrate*|*didMigrate*)
      return 0 ;;

    # First-launch flags (version-stamped one-time state)
    FirstLaunch*|firstLaunch*)
      return 0 ;;

    # Session duration counters
    SessionDuration)
      return 0 ;;

    # CloudKit account cache (hash-keyed entries, daemon-managed)
    CloudKitAccountInfoCache|*CloudKitAccountInfo*|CKPerBootTasks)
      return 0 ;;

    # Declarative Device Management state, daemon-managed.
    DDMPersisted*)
      return 0 ;;

    # WebKit internal state (set when opening Settings panels that use WebKit views)
    WebKitUseSystemAppearance)
      return 0 ;;

    # Caches. CacheSize, EnableCache, Template* are kept.
    *-cache|*CacheData*|*CachedBy*|*CacheVersion*|*CacheKey*|*CacheEntry*|*FlushThumbnailCache|*-temp|*-tmp|*TempFile*|*TempPath*)
      return 0 ;;

    # View state. Finder StandardViewOptions is kept.
    *ScrollPosition*|*scrollPosition*|*SelectedItem*|*ViewOptionsFrame*|*ViewOptionsWindow*)
      return 0 ;;

    # Playback and connection state.
    *PlaybackStatus*|*Playback*Status*|*lastNowPlayedTime*|*LastConnected*)
      return 0 ;;

  esac

  # Hash keys: 32+ hex characters.
  if [[ "$keyname" =~ ^[0-9a-fA-F]{32,}$ ]]; then
    return 0
  fi

  # UUID-shaped keys.
  if [[ "$keyname" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    return 0
  fi

  # No ALL_CAPS rule: SHOW_HIDDEN_FILES is a real pref. Filter per domain.

  # ========================================================================
  # DOMAIN-SPECIFIC NOISY KEYS
  # ========================================================================

  case "$domain" in
    # Accessibility Keyboard: Filter window position
    com.apple.AssistiveControl.virtualKeyboard)
      case "$keyname" in
        PanelFrame|SCLaunchedAsSlave) return 0 ;;
      esac
      ;;

    # Dock preferences: Filter workspace state & tile internals
    com.apple.dock)
      case "$keyname" in
        # Noisy: workspace IDs, counts, expose gestures, trash state, recent apps
        workspace-*|showAppExposeGestureEnabled|last-messagetrace-stamp|lastShowIndicatorTime|trash-full|recent-apps)
          return 0 ;;
        # Noisy: internal tile metadata (reorder noise)
        GUID|dock-extra|tile-type|is-beta|file-type|file-mod-date|parent-mod-date|book|file-data|tile-data)
          return 0 ;;
        # Keep: orientation, autohide, tilesize, magnification, persistent-apps.
      esac
      ;;

    # Finder preferences: Filter recent folders
    com.apple.finder|com.apple.Finder)
      case "$keyname" in
        # Noisy: recent folders, trash state, search history, window name
        FXRecentFolders|RecentMoveAndCopyDestinations|FXConnectToBounds|FXConnectToLastURL|SearchRecentsSavedViewStyle|SearchRecentsViewSettings|GoToField*|LastTrashState|FXDesktopVolumePositions|name)
          return 0 ;;
        # Noisy: View Options panel window position (Cmd+J panel)
        PreviewOptionsWindow.Location)
          return 0 ;;
        # Preview-pane width, written as a side effect of showing the pane.
        PreviewPane*Width)
          return 0 ;;
        # Keep: ShowPathbar, AppleShowAllFiles, FXPreferredViewStyle, etc.
      esac
      ;;

    # System Settings stamps, including the lastIndexed_<pane> stamps of systemsettingsagent.
    com.apple.systemsettings*)
      case "$keyname" in
        *NavigationState*|*update-state-indexing*|*.extension|lastIndexed_*)
          return 0 ;;
      esac
      ;;

    # Screenshot: last-selection rectangle + display (rewritten on every region capture)
    com.apple.screencapture)
      case "$keyname" in
        last-selection*) return 0 ;;
      esac
      ;;

    # Passwords: Private Relay availability and refresh stamps are observed state.
    com.apple.Passwords)
      case "$keyname" in
        WBSPrivacyProxyAvailability*|WBS*LastUpdate*|WebsiteNameProviderLastUpdateTime|DidReportHistorySettings)
          return 0 ;;
      esac
      ;;

    # OmniGroup apps: OmniSoftwareUpdate run statistics / timestamps (telemetry, not prefs)
    com.omnigroup.*)
      case "$keyname" in
        OSURunTimeStatistics|OSULastRun*) return 0 ;;
      esac
      ;;

    # SketchUp / LayOut: web-dialog window geometry (X/Y/Width/Height)
    com.sketchup.*)
      case "$keyname" in
        WebDialog.*.X|WebDialog.*.Y|WebDialog.*.Width|WebDialog.*.Height) return 0 ;;
      esac
      ;;

    # HIToolbox: Filter transient input source state
    com.apple.HIToolbox)
      case "$keyname" in
        # Noisy: current active keyboard (changes on every language switch)
        AppleSavedCurrentInputSource|InputSourceKind|KeyboardLayout\ ID|KeyboardLayout\ Name)
          return 0 ;;
        # Noisy: MRU history of recently-used input sources (rewrites on every switch)
        AppleInputSourceHistory)
          return 0 ;;
        # Keep: AppleEnabledInputSources / AppleSelectedInputSources (real layout changes)
      esac
      ;;

    # loginwindow: session churn out, admin policies in.
    com.apple.loginwindow)
      case "$keyname" in
        # Noisy: who logged in last / recently, first-login bookkeeping, build stamp
        lastUser|lastUserName|RecentUsers|AccountInfo|OptimizerPreviousBuild|UseVoiceOverLegacyMigrated)
          return 0 ;;
        # Noisy: session-restore (TAL* = apps-to-relaunch / logout state) + onboarding churn
        TAL*|MiniBuddy*|oneTimeSSMigrationComplete)
          return 0 ;;
        # Keep: GuestEnabled, LoginwindowText, autoLoginUser*, Disable*, Clock*.
      esac
      ;;

    # SoftwareUpdate: drop daemon-written check results, keep the policy toggles
    com.apple.SoftwareUpdate)
      case "$keyname" in
        LastResultCode|LastAttempt*|LastRecommendedUpdatesAvailable|LastUpdatesAvailable|RecommendedUpdates|LastSessionSuccessful|FirstOfferDateDictionary|AvailableUpdatesNotification*)
          return 0 ;;
        # Beta seed catalog: _note_seed_enrollment speaks for it.
        CatalogURL|LastCatalogChangeDate) return 0 ;;
        # Keep: AutomaticCheckEnabled, AutomaticDownload, AutomaticallyInstall*, etc.
      esac
      ;;

    # SMB server: NetBIOSName and DOSCodePage are derived, not set.
    com.apple.smb.server)
      case "$keyname" in
        NetBIOSName|DOSCodePage) return 0 ;;
      esac
      ;;

    # Universal Access: Filter internal change history
    com.apple.universalaccess)
      case "$keyname" in
        # hudNotifiedConstrast (sic): contrast-HUD state, type varies by machine.
        History|com.apple.custommenu.apps|displaysLastCursorLocation|hudNotifiedConstrast) return 0 ;;
      esac
      ;;

    # Activity Monitor: column widths and last tab. ShowCategory, UpdatePeriod kept.
    com.apple.ActivityMonitor)
      case "$keyname" in
        Column\ Width|SelectedTab) return 0 ;;
      esac
      ;;

    # Game controllers: paired-hardware inventory and pane state. Remaps kept.
    com.apple.GameController)
      case "$keyname" in
        controllers|devices|settingsVersion|showGCPrefsPane) return 0 ;;
      esac
      ;;

    # Menu bar agent (27): telemetry counters. Reject list: new settings still surface.
    com.apple.MenuBarAgent)
      case "$keyname" in
        MenuBarAnalytics.*) return 0 ;;
      esac
      ;;

    # Shortcuts indexer/sync markers. Reject list.
    com.apple.siri.shortcuts)
      case "$keyname" in
        WFSpotlightIndexed*|SpotlightDomainVersion|SpotlightSchemaVersionHash|WFLastSyncedFlagsHash) return 0 ;;
      esac
      ;;

    # Messages nickname sync counters. MeCardSharing* (Share Name and Photo) kept.
    com.apple.messages.nicknames)
      case "$keyname" in
        *Version|IMDNickname*|Nickname*|MeCardSharingImageForkedFromMeCard) return 0 ;;
      esac
      ;;

    # Bonjour generation counter; the domain holds nothing else.
    com.apple.network.ServiceDiscovery)
      case "$keyname" in
        genCount) return 0 ;;
      esac
      ;;

    # GlobalPreferences: Filter Keyboard panel first-open artifacts
    .GlobalPreferences)
      case "$keyname" in
        KB_SpellingLanguage|KB_SpellingLanguageIsAutomatic) return 0 ;;
        # Beta program flag; the NOTE comes from the SoftwareUpdate side.
        NSShowFeedbackMenu) return 0 ;;
        # Time-zone picker breadcrumbs; timezone_watch emits the real command.
        com.apple.TimeZonePref.*|com.apple.preferences.timezone.*|com.apple.AppleModemSettingTool.LastCountryCode) return 0 ;;
        # Keep: KB_DoubleQuoteOption, KB_SingleQuoteOption, NSUserQuotesArray (quote style)
      esac
      ;;

    # Siri: stashed menu-bar icon state. StatusMenuVisible is the real pref.
    com.apple.Siri)
      case "$keyname" in
        SiriPrefStashedStatusMenuVisible) return 0 ;;
      esac
      ;;

    # Siri setup wizard (27) pane history; the opt-ins live in assistant.support.
    com.apple.siri.setup)
      case "$keyname" in
        lastShownCoordinatorVersion*) return 0 ;;
      esac
      ;;

    # Offline dictation model-download state: writing it installs nothing.
    com.apple.assistant.support)
      case "$keyname" in
        Offline\ Dictation\ Status) return 0 ;;
      esac
      ;;

    # Hey Siri: keep 'VoiceTrigger Enabled' and the phrase type, drop routing state.
    com.apple.voicetrigger)
      case "$keyname" in
        Remote\ Darwin\ VoiceTrigger\ Enabled|Accessory\ *\ Playback\ Status) return 0 ;;
      esac
      ;;

    # com.apple.campo (27) carries the same Spotlight usage counters.
    com.apple.Spotlight|com.apple.campo)
      case "$keyname" in
        # Noisy: usage counters, window state, timestamps, binary data
        engagementCount*|engagementDate*|useCount|startTime|showedFTE|FTEReset*)
          return 0 ;;
        lastWindowPosition|lastVisibleScreenRect|userHasMovedWindow|windowHeight)
          return 0 ;;
        queryViewOptions|PasteboardHistoryVersion|PreferencesVersion|version)
          return 0 ;;
        __NSEnable*|SSAction*|FTEReset*)
          return 0 ;;
        # Noisy: auto-learned shortcuts, reload trigger
        mailShortcuts|reloadShortcuts)
          return 0 ;;
        # Keep: DisabledUTTypes, EnabledPreferenceRules, orderedItems, etc.
      esac
      ;;

    # Zoom: Filter per-user session state (tab selection, XMPP identifiers)
    us.zoom.xos)
      case "$keyname" in
        *@xmpp.zoom.us*|kIM_LastOpenedSession|ZMJoinMeetingFlowAnchor) return 0 ;;
      esac
      ;;

    # Campo: per-target engagement counters.
    com.apple.campo)
      case "$keyname" in
        engagementCount*|engagementDate*) return 0 ;;
      esac
      ;;

    # iPod/iPhone sync: Filter connection timestamps and counters
    com.apple.iPod)
      case "$keyname" in
        Connected|Use\ Count) return 0 ;;
      esac
      ;;

    # Terminal: Filter preferences UI state
    com.apple.Terminal)
      case "$keyname" in
        TTAppPreferences\ Selected\ Tab) return 0 ;;
      esac
      ;;

    # Safari: Filter safe browsing updates
    com.apple.Safari)
      case "$keyname" in
        # Noisy: safe browsing cache, history
        SafeBrowsing*|History*|LastSession*)
          return 0 ;;
        # Keep: HomePage, SearchEngine, AutoFillPasswords, etc.
      esac
      ;;

    # ComfortSounds (Focus/Timer): Filter timer timestamps
    com.apple.ComfortSounds)
      case "$keyname" in
        timerEndInterval|comfortSoundsEnabled_UpdateInfo) return 0 ;;
      esac
      ;;

    # PersonalAudio: Filter enrollment progress state
    com.apple.PersonalAudio)
      case "$keyname" in
        currentEnrollmentProgress|shouldUpdateAccessory) return 0 ;;
      esac
      ;;

    # Speech Recognition: Filter auto-generated app inventory on Voice Control activation
    com.apple.speech.recognition.AppleSpeechRecognition.prefs)
      case "$keyname" in
        # Dictation-locale visibility, rewritten when a keyboard is added.
        DictationIMTargetApplications|CACPersistentSleepState|VisibleNetworkSRLocaleIdentifiers) return 0 ;;
        # Keep: DictationIMUseOnlyOfflineDictation, CACUserHintsFeatures, etc.
      esac
      ;;

    # CUPS: LastUsedPrinters is print history (queue + network IP). UseLastPrinter is kept.
    org.cups.PrintingPrefs)
      case "$keyname" in
        LastUsedPrinters|Network|PrinterID) return 0 ;;
      esac
      ;;

    # Print presets: driver internals and last-job traces (see _PRINT_PRESET_NOISE).
    com.apple.print.custompresets*)
      local _ppn
      for _ppn in "${_PRINT_PRESET_NOISE[@]}"; do
        [[ "$keyname" == ${~_ppn} ]] && return 0
      done
      ;;

    # Adobe Crash Reporter: Filter crash state
    com.adobe.crashreporter)
      case "$keyname" in
        # Noisy: crash dialog state and crash metadata (version-stamped keys)
        CRDialogShown_*|lastCrash_*|SuppressCrash_*)
          return 0 ;;
      esac
      ;;

    # Adobe Photoshop: Filter internal app state
    com.adobe.Photoshop)
      case "$keyname" in
        # Noisy: Adobe Butler service first-launch flag (version-stamped)
        butler.*)
          return 0 ;;
        # Noisy: internal memory config and font palette state (year/version-stamped)
        VMMemoryUsagePercent*|paletteEnhancedFontTypeKey*)
          return 0 ;;
      esac
      ;;

    # Adobe Bridge: Filter internal app state
    com.adobe.bridge*)
      case "$keyname" in
        # Noisy: "Do Not Show Again" dialog suppression flags
        DNSA*)
          return 0 ;;
        # Noisy: startup script load result (internal state)
        StartupScriptsLoadedSuccessfully)
          return 0 ;;
        # Noisy: feature flag expiry timestamp (version-stamped)
        FeatureMapExpiryTime)
          return 0 ;;
        # Noisy: current browsed folder (session state, changes constantly)
        target)
          return 0 ;;
        # Keep: LastKeyboardPreset, StartupScriptsShouldLoad, QuickActionsPanelCategory.
      esac
      ;;

    # Adobe Premiere Pro: Filter session/recovery state
    "com.Adobe.Premiere Pro"*)
      case "$keyname" in
        # Noisy: crash recovery project list (session state)
        RecoveryOpenProjectInfos)
          return 0 ;;
      esac
      ;;

    # WiFi Agent: Filter per-SSID "limited network" dismissal bookkeeping
    com.apple.wifi.WiFiAgent)
      case "$keyname" in
        # Noisy: grows with every new network joined; not a user preference
        UserDismissedLimitedNetworkFirstJoins) return 0 ;;
      esac
      ;;

    # Character Picker (emoji/special chars panel): Filter per-app UI state
    com.apple.CharacterPicker)
      case "$keyname" in
        # Noisy: per-app picker state (selectedIndex, scrollPos, date) keyed by bundle ID
        State) return 0 ;;
      esac
      ;;

    # QuickLook Thumbnails Agent: Filter periodic cache-size check timestamp
    com.apple.quicklook.ThumbnailsAgent)
      case "$keyname" in
        QLMTCacheSize*LastCheck*) return 0 ;;
      esac
      ;;

    # iStat Menus menubar variants: Filter periodic license re-validation + update/build tracking
    com.bjango.istatmenus.menubar.*)
      case "$keyname" in
        # Noisy: License:Validation:{signature,time} refreshed on schedule by iStat
        License) return 0 ;;
        # Noisy: per-build attempt counters and last-seen build/version.
        Updates|Status) return 0 ;;
      esac
      ;;

    # Messages (iMessage): Filter analytics/telemetry
    com.apple.MobileSMS)
      case "$keyname" in
        # Noisy: analytics and the iMessage app-browser "seen" dictionary.
        Scrutiny|CKBackgroundSettingsLastReportHour|kCKBrowserSelectionControllerSeenDictionaryKey)
          return 0 ;;
      esac
      ;;
    com.apple.iChat)
      case "$keyname" in
        # Internal IMD state (last notification timestamp, not a user preference)
        LastIMDNotificationPostedDate)
          return 0 ;;
      esac
      ;;

    # Native Instruments: Filter telemetry init flags
    com.native-instruments.*)
      case "$keyname" in
        uret-init) return 0 ;;
      esac
      ;;

    # Bartender: Filter termination reason log (grows each launch)
    com.surteesstudios.Bartender)
      case "$keyname" in
        TerminationReasons) return 0 ;;
      esac
      ;;

    # Audio MIDI Setup: Filter machine-specific device selection
    com.apple.audio.AudioMIDISetup)
      case "$keyname" in
        # Hardware UUID / USB engine path / virtual-device name. Won't transplant
        audioDevice.selected) return 0 ;;
      esac
      ;;

    # iCloud Quota: Filter internal offer cache (server-driven, refreshed on schedule)
    com.apple.cloud.quota)
      case "$keyname" in
        _ICQ*) return 0 ;;
      esac
      ;;

    # Content Caching: runtime counters out, Activated (the toggle) kept.
    com.apple.AssetCache)
      case "$keyname" in
        SavedCacheDetails|SavedCacheSize|SavedCacheUsedSize) return 0 ;;
      esac
      ;;

    # ARD Agent: Filter hardcoded App Store URL (daemon-rewritten on activation)
    com.apple.ARDAgent)
      case "$keyname" in
        ARDAdmin_AppStoreURL) return 0 ;;
      esac
      ;;

    # Remote Desktop: values the daemon rewrites on every activation.
    com.apple.RemoteDesktop)
      case "$keyname" in
        RSAKeySize|DOCAllowRemoteConnections) return 0 ;;
      esac
      ;;

    com.trendmicro.ztnasase)
      # Trend Micro ZTNA agent: device state and signed-in e-mail out, reproducible
      # prefs (requireAuth*, LoginURL, SwgServer, pacUrl, CompanyId, *IsEnable) kept.
      case "$keyname" in
        *Version|DeviceId|connectorInfoList|systemExtensionExistFlag|swgIsInvalid|ztnaIsInvalid|UserName|swgConnectStatus)
          return 0 ;;
      esac
      ;;

    # Extensis: snake_case last_sent_* telemetry stamps. Per KEY: real prefs remain.
    com.extensis.*)
      case "$keyname" in
        last_sent_*) return 0 ;;
      esac
      ;;

    # Setapp: short-lived job markers written then deleted (a trailing UUID the
    # whole-key rule misses). Per KEY: ~89 real settings remain.
    com.setapp.*)
      case "$keyname" in
        *ActiveRefreshSession*|UpdatingSearchIndexItem-*|ManagedObjectContext_*) return 0 ;;
      esac
      ;;

    # Office: UAE* crash bookkeeping; SharePoint (27) crash SDK and session state.
    com.microsoft.*)
      case "$keyname" in
        UAE*|kAppBootTimeForUAE|AppExitGraceful|UseMERPCrashReportingSdk|MSAppCenter*|\
        SessionId|SessionVersion|SessionLongBuildNumber|OSVersion|OSLocale) return 0 ;;
      esac
      ;;

    # Monotype agent: live PID and install path. Named, not an MFEP* glob.
    com.monotype.fonts)
      case "$keyname" in
        MFEPProcessId|MFEPExecutablePath) return 0 ;;
      esac
      ;;

    # Charge limit: `…prior.limit` is UI state; _note_charge_limit explains.
    com.apple.batteryui.charging.mac)
      case "$keyname" in
        *prior.limit) return 0 ;;
      esac
      ;;

    # AirDrop discoverability is the one real setting. Drop list: new ones surface.
    com.apple.sharingd)
      case "$keyname" in
        AirDropRandomHashUUIDKey*|AutoUnlock*|HashManager-*|SDAirDrop*|\
        SFCollaborationUserDefaults*|AUIconTransferStore|\
        AfterFirstUseExpirationDate|OneTimeAirDropReset*) return 0 ;;
        # Per-session ByHost tokens and an Apple ID blob.
        AirDropID|StreamID|AppleIDAgentMetaInfo) return 0 ;;
      esac
      ;;

    # Media Sharing: every key filtered, domain still watched. The keys mirror
    # state mediasharingd never reads (measured 26.6.2); _note_mediasharing says so.
    com.apple.amp.mediasharingd)
      return 0
      ;;

    # Music, TV, Contacts: per KEY, never excluded whole (real crossfade, EQ, text size).
    com.apple.Music|com.apple.TV)
      case "$keyname" in
        # Window and sidebar geometry, per-library view and player state.
        "NSSplitView"*|"NSWindow Frame"*|"NSNavPanel"*|NSApplicationCrashOnExceptions|\
        PPr4:*|PLGD:*|RDoc:*|rprf:*|gnot:*|\
        sidebar-hidden|sidebar-shown|sidebarItemInfo|bwui|videoWindow*|playbackIsFullscreen) return 0 ;;
        # Store/account caches, bookmarks and one-shot UI milestones.
        *-bookmark|*-url|*Bookmark|*CacheKey|store*|Store*|doesStoreSupport*|\
        debugAssert*|checkedHLSKeysTime|refreshedHLSKeysTime|_MPC*|IRTokenAudio|tokenData|\
        JetEngine*|*WelcomeScreenState|whatsNewLevel|updateLevel|jsVersion|\
        Kettle*|hasSeen*|hasRegisterd*|kAOSUI*|ImageProxy*|RetryOn*|VUIAssetCacheKey|\
        last*|*SessionIdentifier|controllableInterfaceGUID|haveRadioState|notifications-warming*|\
        eqPrefsVersion|com.apple.amp.*|didSetLyricsByDefaultOnNowPlaying|firstLaunch*) return 0 ;;
      esac
      ;;
    # MediaPlayer behind Music: now-playing cache and a capability flag.
    com.apple.mobileipod)
      case "$keyname" in
        musicPlayerStateRestorationCache*|EnhancedAudioAvailable) return 0 ;;
      esac
      ;;
    # ChatGPT extension: selectedLLMId is the choice, the rest is metadata.
    com.apple.generativepartnerservicesettings)
      case "$keyname" in
        AllLLMUISettings|externalProviders*|externalVipProviderMetadata|gatMigrationComplete*|siriExtensionProvidersMetricsSnapshot) return 0 ;;
      esac
      ;;
    # Game Mode agent: per-app metadata cache and installed-games blob.
    com.apple.GamePolicyAgent)
      case "$keyname" in
        gameMetadataHintsCache|installedGames) return 0 ;;
      esac
      ;;
    com.apple.AddressBook)
      case "$keyname" in
        "NSSplitView"*|"NSWindow Frame"*|ABCleanWindowController*|ABDatumColumnWidth|\
        ABMetaDataChangeCount|ABMetadataLastOilChange|ABVersion|ABLastImportShown) return 0 ;;
      esac
      ;;

    # Time Machine: backupd owns it; _note_timemachine emits tmutil for AutoBackup
    # and SkipPaths, the rest has no tmutil verb.
    com.apple.TimeMachine)
      case "$keyname" in
        AutoBackup|SkipPaths) return 0 ;;
      esac
      ;;

    # A location change also reaches the scalar path as CurrentSet; scselect replaces it.
    preferences)
      case "$keyname" in
        CurrentSet) return 0 ;;
      esac
      ;;

    # Wi-Fi power: airportd owns the file; _note_wifi_power emits networksetup.
    com.apple.airport.preferences)
      case "$keyname" in
        PowerEnabled) return 0 ;;
      esac
      ;;

    # The desktoppr record of its last image; _note_desktoppr emits the real command.
    com.scriptingosx.desktoppr)
      case "$keyname" in
        lastPath) return 0 ;;
      esac
      ;;

  esac

  return 1
}

# Safety net for commands that bypass key filters (plutil artifacts, float positions).
is_noisy_command() {
  local cmd="$1"

  if [[ "$cmd" == *'<type> <value>'* ]]; then
    return 0
  fi

  case "$cmd" in
    *"-float"*NSWindow*|*"-float"*Scroll*|*"-float"*Position*)
      return 0
      ;;
  esac

  # ARD Text1-4 initialised EMPTY when Remote Management is enabled; kept with a value.
  case "$cmd" in
    *com.apple.RemoteDesktop*'"Text'[1-4]'" -string ""')
      return 0
      ;;
  esac

  return 1
}

# Element noise (_ELEMENT_NOISE_MARKERS): an array element whose dict holds a
# marker is skipped whole, judged by the Python workers. domain|array|marker,
# scoped to ONE array: CharacterPaletteIM is churn in AppleSelectedInputSources
# and a real setting in AppleEnabledInputSources.
# _PRINT_PRESET_NOISE: the one reject list for print presets, as globs in zsh
# `case` and Python fnmatchcase alike.
typeset -ga _PRINT_PRESET_NOISE=(
  'EPIJ*'                                  # Epson driver internals: opaque codes ('116', '35')
  'EPSON.PrintModule.Setting.*'            # machine identity. HostName, PrinterName
  'com.apple.print.ticket.*'               # ticket structure (APIVersion, type)
  'com.apple.print.DialogDismissedBy'      # which BUTTON was clicked. And localised
  'com.apple.print.PDEsUsed'               # which pane was open. Localised
  'com.apple.print.pageRange'              # range of the last job. Localised ("Toutes les pages (2)")
  'com.apple.print.totalPages'             # last job
  'com.apple.print.lastPresetUsedPrefType' # state
  'PaperInfoIsSuggested'                   # state
)

typeset -ga _ELEMENT_NOISE_MARKERS=('com.apple.HIToolbox|AppleSelectedInputSources|CharacterPaletteIM')

# Filter PlistBuddy key paths: top key through is_noisy_key, then sub-key patterns.
is_noisy_pbcmd() {
  local domain="$1" pb_cmd="$2"

  [[ "$pb_cmd" == *"<data:"* ]] && return 0

  # "Add :Top:Sub type value" / "Set :Top value" / "Delete :Top"; spaces are '\ '.
  local _raw="${pb_cmd#* :}"                    # strip verb + ":"
  local _safe="${_raw//\\ /__PBSP__}"           # protect escaped spaces
  local _top="${_safe%%:*}"                      # first segment (before next ":")
  _top="${_top%% *}"                             # strip trailing type/value if no sub-key
  local _t
  for _t in dict array string integer real bool; do
    [[ "$_top" == *"__PBSP__${_t}" ]] && _top="${_top%__PBSP__${_t}}"
  done
  _top="${_top//__PBSP__/ }"                    # restore spaces

  [ -n "$_top" ] && is_noisy_key "$domain" "$_top" && return 0

  case "$pb_cmd" in
    *":dock-extra "*|*":is-beta "*|*":tile-type "*|*":recent-apps:"*|\
    *":parent-mod-date "*|*":file-mod-date "*|*":file-type "*|\
    *":vendorDefaultSettings:"*|*"TB\\ Default\\ Item"*|\
    *":GUID "*|*":window-file:"*|\
    *":com.apple.finder.SyncExtensions"*|\
    *":WindowBounds "*|*":WindowState:"*|\
    *":scrollPosition"*)
      return 0 ;;
  esac

  # VPN clients re-add __NEVPN* keychain markers on wake. Not user VPN config.
  case "$pb_cmd" in
    *":__NEVPN"*) return 0 ;;
  esac

  case "$domain" in
    com.apple.finder|com.apple.Finder)
      case "$pb_cmd" in
        # Column widths (resize noise).
        *":columns:"*":width "*)
          return 0 ;;
        # axTextSize is derived from FontSizeCategory, whose command covers it.
        *":axTextSize "*)
          return 0 ;;
      esac
      ;;
  esac

  case "$domain" in
    com.apple.GameController)
      # Noisy: modification dates (sync metadata), tombstone tracking
      case "$pb_cmd" in
        *":modifiedDate "*|*":tombstones "*)
          return 0 ;;
      esac
      ;;
    com.apple.preferences.accounts)
      # deletedUsers is bookkeeping: replaying it deletes nobody. useracct_watch reports.
      case "$pb_cmd" in
        *":deletedUsers"*) return 0 ;;
      esac
      ;;
    preferences)
      # The configd file, keyed by service UUIDs minted on THIS Mac. hostname_watch,
      # _note_network_service and _note_network_location emit the real commands.
      case "$pb_cmd" in
        *":System:Network:HostNames:"*|*":System:System:ComputerName"*|\
        *":NetworkServices:"*|*":Sets:"*":Network:"*|*":CurrentSet"*) return 0 ;;
      esac
      ;;
    com.apple.TimeMachine)
      # Noisy: disk metrics and snapshot counters. ID, Kind, QuotaGB, Name kept.
      case "$pb_cmd" in
        *":BytesAvailable "*|*":BytesUsed "*|*":NumberOfSnapshots "*|\
        *":SnapshotDates "*|*":SnapshotDates:"*|\
        *":ConsistencyScanDate "*|*":FilesystemTypeName "*|\
        *":LastKnownEncryptionState "*|*":LastKnownVolumeName "*|\
        *":ReferenceLocalSnapshotDate "*|*":StableLocalSnapshotDate "*|*":attemptDate "*|\
        *":RESULT "*|*":backupOfVolumeUUIDs"*)
          return 0 ;;
      esac
      ;;
    com.rogueamoeba.loopbackd)
      # Noisy: periodic scheduler fire timestamps
      case "$pb_cmd" in
        *":lastFireDate "*)
          return 0 ;;
      esac
      ;;
    com.apple.HIToolbox)
      # Character Palette churn only in AppleSelectedInputSources, not Enabled.
      case "$pb_cmd" in
        *":AppleSelectedInputSources:"*"CharacterPaletteIM"*)
          return 0 ;;
      esac
      ;;
    com.apple.MobileSMS)
      # Noisy: Scrutiny analytics and app-browser "seen" entries.
      case "$pb_cmd" in
        *":Scrutiny:"*|*":Scrutiny "*|*":kCKBrowserSelectionControllerSeenDictionaryKey:"*)
          return 0 ;;
      esac
      ;;
    com.apple.iPod)
      # Per-device sync bookkeeping under Devices:<id>:.
      case "$pb_cmd" in
        *":Connected "*|*":Use\\ Count "*)
          return 0 ;;
      esac
      ;;
  esac

  return 1
}

# ---------------------------------------
# Logging
# ---------------------------------------

# Core log function; log_* wrappers delegate here. Usage: _log <tag> <message>
_log() {
  local tag="$1" msg="$2"
  local ts
  ts="$(get_timestamp)"

  if [ "${ONLY_CMDS:-false}" = "true" ]; then
    local out
    case "$msg" in
      Cmd:\ *) out="${msg#Cmd: }" ;;
      CMD:\ *) out="${msg#CMD: }" ;;
      *) return 0 ;;
    esac

    if [[ "$out" == *"NSWindow Frame main"* ]]; then
      return 0
    fi

    if [[ "$out" =~ 'defaults([[:space:]]+-[^[:space:]]+)*[[:space:]]+write[[:space:]]+([^[:space:]]+)' ]]; then
      local _cmd_dom="${match[2]}"
      # Only ALL mode may drop an excluded domain; a named domain is always watched.
      if [ "${ALL_MODE:-false}" = "true" ] && [ -n "$_cmd_dom" ] && is_excluded_domain "$_cmd_dom"; then
        return 0
      fi
    fi

    printf "%s\n" "$out"
    printf "%s\n" "$out" >> "$LOGFILE" 2>/dev/null || true
    /usr/bin/logger -t "prefwatch[$tag]" -- "$out"
    return 0
  fi

  local line="[$ts] $msg"
  if [[ "$msg" =~ 'defaults([[:space:]]+-[^[:space:]]+)*[[:space:]]+write[[:space:]]+([^[:space:]]+)' ]]; then
    local _cmd_dom="${match[2]}"
    # Same guard as the ONLY_CMDS branch above.
    if [ "${ALL_MODE:-false}" = "true" ] && [ -n "$_cmd_dom" ] && is_excluded_domain "$_cmd_dom"; then
      return 0
    fi
  fi

  printf "%s\n" "$line"
  printf "%s\n" "$line" >> "$LOGFILE" 2>/dev/null || true
  /usr/bin/logger -t "prefwatch[$tag]" -- "$msg"
}

log_line()   { _log "$DOMAIN_TAG" "$1"; }

log_user()   { _log "user" "$1"; }

log_system() { _log "system" "$1"; }

snapshot_notice() {
  local msg="$1" verbose_only="${2:-false}"
  local ts
  ts="$(get_timestamp)"
  local line="[$ts] [snapshot] $msg"
  if [ "$verbose_only" = "true" ] && [ "${ONLY_CMDS:-false}" = "true" ]; then
    return 0
  else
    printf "%s\n" "$line"
    printf "%s\n" "$line" >> "$LOGFILE" 2>/dev/null || true
  fi
  /usr/bin/logger -t "prefwatch[snapshot]" -- "$msg"
}

# ---------------------------------------
# Plist & PlistBuddy
# ---------------------------------------

dump_plist() {
  local src="$1" out="$2"
  if ! /usr/bin/plutil -p "$src" > "$out" 2>/dev/null; then
    /bin/cat "$src" > "$out" 2>/dev/null || :
  fi
}

dump_plist_json() {
  local src="$1" out="$2"
  if [ ! -f "$src" ]; then
    : > "$out" 2>/dev/null || true
    return
  fi
  # plistlib first: plutil writes an integral float as `2`, read back as an int.
  # plutil fails on <data>/<date> anyway. Paid only when a plist changes.
  if [ -n "$PYTHON3_BIN" ]; then
    "$PYTHON3_BIN" - "$src" "$out" <<'PYJSON' 2>/dev/null && return
import plistlib, json, sys, datetime
src, out = sys.argv[1], sys.argv[2]
with open(src, 'rb') as f:
    data = plistlib.load(f)
def sanitize(obj):
    if isinstance(obj, bytes):
        return "<data:" + str(len(obj)) + ">"
    if isinstance(obj, (datetime.datetime, datetime.date)):
        return obj.isoformat()
    if hasattr(plistlib, 'UID') and isinstance(obj, plistlib.UID):
        return int(obj)
    if isinstance(obj, dict):
        return {k: sanitize(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [sanitize(v) for v in obj]
    return obj
with open(out, 'w') as f:
    json.dump(sanitize(data), f)
PYJSON
  fi
  # Fallback: plutil, lossy on integral floats, better than no JSON.
  if /usr/bin/plutil -convert json -o "$out" "$src" >/dev/null 2>&1; then
    [ -s "$out" ] && return
  fi
  : > "$out" 2>/dev/null || true
}

extract_type_value_with_plutil() {
  local plist="$1" key="$2"
  local type value

  local json_value
  json_value=$(/usr/bin/plutil -extract "$key" json -o - "$plist" 2>/dev/null) || return 1

  if [[ "$json_value" == "true" ]] || [[ "$json_value" == "false" ]]; then
    type="bool"
    value=$(printf '%s' "$json_value" | /usr/bin/tr '[:lower:]' '[:upper:]')
  elif [[ "$json_value" =~ ^-?[0-9]+$ ]]; then
    type="int"
    value="$json_value"
  elif [[ "$json_value" =~ ^-?[0-9]*\.[0-9]+$ ]]; then
    type="float"
    value="$json_value"
  elif [[ "$json_value" =~ ^\".* ]]; then
    type="string"
    value=$(printf '%s' "$json_value" | /usr/bin/sed 's/^"//; s/"$//' | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g')
  elif [[ "$json_value" =~ ^\[.* ]]; then
    type="array"
    value="$json_value"
  elif [[ "$json_value" =~ ^\{.* ]]; then
    type="dict"
    value="$json_value"
  else
    return 1
  fi

  printf '%s|%s\n' "$type" "$value"
  return 0
}

# `defaults … delete` → PlistBuddy. $2 = real plist path (the ByHost file,
# since -currentHost does not survive the conversion).
convert_delete_to_plistbuddy() {
  # $3 = domain from the caller; the regex below is only a fallback.
  local cmd="$1" path_override="${2:-}" domain_override="${3:-}"

  local domain target
  if [ -n "$domain_override" ]; then
    domain="$domain_override"
  else
    domain=$(printf '%s' "$cmd" | /usr/bin/sed -nE 's/.*defaults([[:space:]]+-[^[:space:]]+)*[[:space:]]+delete[[:space:]]+"?([^"[:space:]]+)"?.*/\2/p')
  fi
  # Target = LAST quoted field: survives a domain containing a space.
  target=$(printf '%s' "$cmd" | /usr/bin/sed -nE 's/.*"([^"]*)"[[:space:]]*$/\1/p')
  [ -z "$target" ] && target=$(printf '%s' "$cmd" | /usr/bin/sed -nE 's/.*[[:space:]]([^"[:space:]]+)[[:space:]]*$/\1/p')

  [ -n "$domain" ] || return 1
  [ -n "$target" ] || return 1

  local plist_path
  if [ -n "$path_override" ]; then
    plist_path="$path_override"
  else
    plist_path="$(get_plist_path "$domain")"
  fi

  local is_array_deletion=false
  if [[ "$target" =~ ':[^:]+:[0-9]+$' ]]; then
    is_array_deletion=true
  fi

  if [ "$is_array_deletion" = "true" ]; then
    # "# WARNING: array deletes" is a DEDUP KEY matched in _emit_cmd and
    # emit_array_deletions: change the wording in all three places.
    printf '# WARNING: array deletes shift indexes. Run these in the order shown\n'
  fi
  local _mdm_path=$(mdm_plist_path "$plist_path")
  # Escape ' for the single-quoted -c expression.
  local _target_esc
  _target_esc=$(printf '%s' "$target" | /usr/bin/sed "s/'/'\\\\''/g")
  # Escape the path AFTER templatizing, so $loggedInUser / $UUID still expand.
  printf '/usr/libexec/PlistBuddy -c '\''Delete %s'\'' "%s"\n' "$_target_esc" "$(_escape_pb_path "$_mdm_path")"
  return 0
}

# ---------------------------------------
# Command Emission
#
# Builds the `defaults`/PlistBuddy commands and routes them through the
# filters/logging. The bridge between the diff engine and the log output.
# ---------------------------------------

# ' and its escaped form, built char by char: inline in ${//} it goes wrong.
typeset -g _SQ="'"
typeset -g _SQ_ESC="${_SQ}\\${_SQ}${_SQ}"

# Escape a path for double quotes, keeping the $loggedInUser/$UUID tokens of mdm_plist_path.
_escape_pb_path() {
  local _p _liu_esc _uid_esc _uid_tok
  _p=$(_escape_dq "$1")
  # Escaped tokens via the same escaper: a literal `\$loggedInUser` would expand here under set -u.
  _uid_tok='$UUID'
  _liu_esc=$(_escape_dq "$_MDM_LIU")
  _uid_esc=$(_escape_dq "$_uid_tok")
  _p="${_p//"$_liu_esc"/"$_MDM_LIU"}"
  _p="${_p//"$_uid_esc"/"$_uid_tok"}"
  printf '%s' "$_p"
}

_escape_dq() { printf '%s' "$1" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g; s/`/\\`/g'; }

# `defaults write …` via the type cascade; empty for array/dict.
# Args: dom keyname trimmed hostflag plist_path
_build_defaults_write_cmd() {
  local dom="$1" keyname="$2" trimmed="$3" hostflag="$4" plist_path="$5"
  local actual_type="" type_val noquotes str cmd=""
  local plutil_result plutil_type plutil_value

  # Escape the KEY like a value; the type probe keeps the raw key.
  local _kn; _kn=$(_escape_dq "$keyname")

  # System pref: by full path, or it replays into the console user copy.
  [ "${_EMIT_SYS:-false}" = "true" ] && [[ "$dom" != /* ]] && dom="${_EMIT_SYS_DOM:-/Library/Preferences/${dom}}"

  # The domain is a filename: quote it (spaces exist) and escape it (a
  # com.x$(…).plist would run in the admin root shell).
  local _dm; _dm=$(_escape_dq "$dom")

  # Probe the type as the CONSOLE USER (root reads its own domain and got -bool
  # for -int 0). The space stays outside ${hostflag:+…}, or zsh makes one word.
  if [ "${_EMIT_SYS:-false}" = "true" ]; then
    actual_type=$(/usr/bin/defaults ${hostflag:+$hostflag} read-type "$dom" "$keyname" 2>/dev/null | /usr/bin/awk '{print $NF}') || actual_type=""
  else
    actual_type=$("${RUN_AS_USER[@]}" /usr/bin/defaults ${hostflag:+$hostflag} read-type "$dom" "$keyname" 2>/dev/null | /usr/bin/awk '{print $NF}') || actual_type=""
  fi

  if [ "$actual_type" = "float" ]; then
    cmd="defaults ${hostflag:+$hostflag }write \"${_dm}\" \"${_kn}\" -float ${trimmed}"
  elif [ "$actual_type" = "integer" ]; then
    cmd="defaults ${hostflag:+$hostflag }write \"${_dm}\" \"${_kn}\" -int ${trimmed}"
  elif [ "$actual_type" = "boolean" ]; then
    type_val=$( [ "$trimmed" = "1" ] || [ "$trimmed" = "true" ] && echo TRUE || echo FALSE )
    cmd="defaults ${hostflag:+$hostflag }write \"${_dm}\" \"${_kn}\" -bool ${type_val}"
  elif [[ "$trimmed" =~ ^\".*\"$ ]]; then
    noquotes="${trimmed#\"}"; noquotes="${noquotes%\"}"
    str=$(_escape_dq "$noquotes")
    cmd="defaults ${hostflag:+$hostflag }write \"${_dm}\" \"${_kn}\" -string \"${str}\""
  elif [[ "$trimmed" == "true" ]] || [[ "$trimmed" == "false" ]]; then
    type_val=$(printf '%s' "$trimmed" | /usr/bin/tr '[:lower:]' '[:upper:]')
    cmd="defaults ${hostflag:+$hostflag }write \"${_dm}\" \"${_kn}\" -bool ${type_val}"
  elif [[ "$trimmed" == "0" ]] || [[ "$trimmed" == "1" ]]; then
    type_val=$( [ "$trimmed" = "1" ] && echo TRUE || echo FALSE )
    cmd="defaults ${hostflag:+$hostflag }write \"${_dm}\" \"${_kn}\" -bool ${type_val}"
  elif [[ "$trimmed" =~ ^-?[0-9]+$ ]]; then
    cmd="defaults ${hostflag:+$hostflag }write \"${_dm}\" \"${_kn}\" -int ${trimmed}"
  elif [[ "$trimmed" =~ ^-?[0-9]*\.[0-9]+$ ]]; then
    cmd="defaults ${hostflag:+$hostflag }write \"${_dm}\" \"${_kn}\" -float ${trimmed}"
  else
    if [ -f "$plist_path" ] && plutil_result=$(extract_type_value_with_plutil "$plist_path" "$keyname" 2>/dev/null); then
      plutil_type="${plutil_result%%|*}"
      plutil_value="${plutil_result#*|}"
      case "$plutil_type" in
        string) cmd="defaults ${hostflag:+$hostflag }write \"${_dm}\" \"${_kn}\" -string \"$(_escape_dq "$plutil_value")\"" ;;
        bool)   cmd="defaults ${hostflag:+$hostflag }write \"${_dm}\" \"${_kn}\" -bool ${plutil_value}" ;;
        int)    cmd="defaults ${hostflag:+$hostflag }write \"${_dm}\" \"${_kn}\" -int ${plutil_value}" ;;
        float)  cmd="defaults ${hostflag:+$hostflag }write \"${_dm}\" \"${_kn}\" -float ${plutil_value}" ;;
        array|dict) cmd="" ;;
        *) cmd="defaults ${hostflag:+$hostflag }write \"${_dm}\" \"${_kn}\" <type> <value>" ;;
      esac
    else
      cmd="defaults ${hostflag:+$hostflag }write \"${_dm}\" \"${_kn}\" <type> <value>"
    fi
  fi

  printf '%s' "$cmd"
}

# `defaults [hostflag] delete dom "target"`; target :array:idx or keyname.
_build_defaults_delete_cmd() {
  local dom="$1" keyname="$2" array_name="$3" array_idx="$4" hostflag="$5"
  local target
  if [ -n "$array_name" ]; then
    target=":${array_name}:${array_idx}"
  else
    target="$keyname"
  fi
  # Same escaping as the write builder.
  target=$(_escape_dq "$target")
  # System pref: the file by full path, as the write builder does.
  [ "${_EMIT_SYS:-false}" = "true" ] && [[ "$dom" != /* ]] && dom="${_EMIT_SYS_DOM:-/Library/Preferences/${dom}}"
  local _dm; _dm=$(_escape_dq "$dom")
  if [ -n "$hostflag" ]; then
    printf 'defaults %s delete "%s" "%s"' "$hostflag" "$_dm" "$target"
  else
    printf 'defaults delete "%s" "%s"' "$_dm" "$target"
  fi
}

# NOTE for Console: "# NOTE: " then "#       ", one sentence per line
# (Console wraps with no "#", which reads as a command). $1 kind, $2 text.
_log_note_wrapped() {
  local _kind="$1" _t="$2" _first=true _l _s _m=$'\x1e'
  local -a _parts
  # Mark sentence ends, then split there. \x1e never occurs in a note.
  _t="${_t//. /.$_m}"; _t="${_t//; /;$_m}"
  _parts=("${(@ps:\x1e:)_t}")
  for _s in "${_parts[@]}"; do
    [ -n "$_s" ] || continue
    # Never folded: one sentence, one line. Keep sentences short.
    _l="${_s%% }"
    if [ "$_first" = true ]; then _log_kind "$_kind" "Cmd: # NOTE: $_l"; _first=false
    else _log_kind "$_kind" "Cmd: #       $_l"; fi
  done
}

_log_kind() {
  # A deferred new-domain NOTE goes out just before the first line of the domain.
  if [ -n "${_PENDING_NEWDOM_NOTE:-}" ] && [[ "$2" == "Cmd: "* ]]; then
    local _ndn="$_PENDING_NEWDOM_NOTE"
    typeset -g _PENDING_NEWDOM_NOTE=""
    _log_kind "$1" "$_ndn"
  fi
  # Count real command lines, for NOTEs that belong above one.
  [[ "$2" == "Cmd: "* && "$2" != "Cmd: #"* ]] && typeset -g _CMD_LINES=$(( ${_CMD_LINES:-0} + 1 ))
  case "$1" in
    USER)   log_user   "$2" ;;
    SYSTEM) log_system "$2" ;;
    *)      log_line   "$2" ;;
  esac
}

# Device.mntr.<UUID> is the display own UUID, per monitor and per Mac: --mdm
# cannot templatize it. Scoped to Device.mntr. (other UUIDs need other advice).
_note_device_uuid() {
  local kind="$1" key="$2"
  [[ "$key" == *"Device.mntr."[0-9A-Fa-f]* ]] || return 0
  _note_should_show __device_uuid__ || return 0
  _log_kind "$kind" "Cmd: # NOTE: Device.mntr.<UUID> is the DISPLAY's own UUID, per-monitor and different on every Mac."
  if [ "$MDM_OUTPUT" = "true" ]; then
    _log_kind "$kind" "Cmd: #       --mdm cannot templatize it. On the target: defaults -currentHost read -g com.apple.ColorSync.Devices"
  else
    _log_kind "$kind" "Cmd: #       To replay elsewhere, list the displays there: defaults -currentHost read -g com.apple.ColorSync.Devices"
  fi
}

_note_byhost_uuid() {
  local kind="$1" path="$2" key="${3:-}"
  # The display UUID has its own NOTE, which contradicts the --mdm advice here.
  [[ "$key" == *"Device.mntr."[0-9A-Fa-f]* ]] && return 0
  case "$path" in
    # MDM mode: $UUID is resolved once in the header; nothing to add.
    *'$UUID'*)
      return 0
      ;;
    # Normal mode: the literal UUID works on this Mac only.
    */ByHost/*)
      _note_should_show __byhost_uuid__ || return 0
      _log_note_wrapped "$kind" "this ByHost filename holds THIS Mac's hardware UUID. The path is valid on this Mac only; re-run with --mdm for a deployable form"
      ;;
  esac
}

# --debug: say which filter dropped a detected change. Silent otherwise.
_dbg_filtered() { [ "${DEBUG_FILTER:-false}" = "true" ] && log_line "Cmd: # FILTERED: $1"; return 0; }  # ALWAYS return 0: called standalone in then-blocks under set -e, so a non-zero (debug OFF → the [ ] fails, && short-circuits) would ABORT the shell

# --mdm: prefix a USER-domain command with runAsUser, or a root Jamf policy
# writes the root prefs. System commands (_EMIT_SYS) get sudo instead.
_mdm_wrap() {
  if [ "${_EMIT_SYS:-false}" = "true" ]; then
    # System pref: sudo (a no-op when Jamf is already root).
    printf 'sudo %s' "$1"
  elif [ "$MDM_OUTPUT" = "true" ]; then
    printf 'runAsUser %s' "$1"
  else
    printf '%s' "$1"
  fi
}

# `# dockutil …` is copied out and run, so --mdm wraps it too.
_mdm_wrap_comment() {
  case "$1" in
    "# dockutil "*) printf '# %s' "$(_mdm_wrap "${1#"# "}")" ;;
    *)             printf '%s' "$1" ;;
  esac
}

# A top-level key deletion stays `defaults … delete` where defaults resolves
# the domain: PlistBuddy edits behind cfprefsd and running apps are not told
# (27: Wi-Fi item stayed hidden). $1 command, $2 real plist path (may be empty).
_delete_keeps_defaults() {
  local cmd="$1" p="$2" d
  [[ "$cmd" == *'" ":'* ]] && return 1    # array or nested target: PlistBuddy
  [ -n "$p" ] || return 0
  d="${p:h}"
  case "$d" in
    */Library/Preferences/ByHost) [[ "$cmd" == *" -currentHost "* ]] || return 1 ;;
    /Library/Preferences) [[ "$cmd" == *'"/Library/Preferences/'* ]] || return 1; return 0 ;;
  esac
  # User domains only; a sandbox container also ends in Library/Preferences.
  [[ "${d%/ByHost}" =~ '^(/Users/[^/]+|/var/root|/private/var/root)/Library/Preferences$' ]]
}

# Emit a built command via _log_kind, with filters and NOTEs.
# Args: kind cmd note_dom is_delete [plist_path]
_emit_cmd() {
  local kind="$1" cmd="$2" note_dom="$3" is_delete="$4" emit_plist_path="${5:-}"

  [ -n "$cmd" ] || return 0
  if is_noisy_command "$cmd"; then _dbg_filtered "${note_dom:-?} (noise/invalid command: ${cmd[1,120]})"; return 0; fi

  # ALL mode: the per-plist diff already emitted this; the DOMAIN pass would
  # print it twice. Before the contextual note, which it would also trigger.
  if [ "$kind" = "DOMAIN" ] && [ "${ALL_MODE:-false}" = "true" ]; then
    return 0
  fi

  if [ "$is_delete" != "true" ]; then
    local _cmd_dom
    _cmd_dom=$(printf '%s' "$cmd" | /usr/bin/sed -nE 's/.*defaults([[:space:]]+-[^[:space:]]+)*[[:space:]]+write[[:space:]]+([^[:space:]]+).*/\2/p')
    # See _log: only ALL mode may drop an excluded domain.
    if [ "${ALL_MODE:-false}" = "true" ] && [ -n "$_cmd_dom" ] && is_excluded_domain "$_cmd_dom"; then _dbg_filtered "$_cmd_dom (excluded-domain)"; return 0; fi
    _emit_contextual_note "$note_dom" ""
  fi


  if [ "$is_delete" = "true" ]; then
    local pb_delete pb_line
    if _delete_keeps_defaults "$cmd" "$emit_plist_path"; then
      _note_device_uuid "$kind" "${${cmd%\"}##*\"}"
      _log_kind "$kind" "Cmd: $(_mdm_wrap "$cmd")"
    elif pb_delete=$(convert_delete_to_plistbuddy "$cmd" "$emit_plist_path" "$note_dom" 2>/dev/null); then
      while IFS= read -r pb_line; do
        [ -n "$pb_line" ] || continue
        case "$pb_line" in
          # "Cmd: " on comment lines too, or ONLY_CMDS drops them.
          "# WARNING: array deletes"*)
            _note_should_show __array_del_warning__ && _log_kind "$kind" "Cmd: $pb_line" ;;
          "#"*) _log_kind "$kind" "Cmd: $pb_line" ;;
          *)    _note_byhost_uuid "$kind" "$pb_line" "${${pb_line#*-c \'}%%\'*}"
                # Key expression only; the ByHost UUID in the path is another matter.
                _note_device_uuid "$kind" "${${pb_line#*-c \'}%%\'*}"
                _log_kind "$kind" "Cmd: $(_mdm_wrap "$pb_line")" ;;
        esac
      done <<< "$pb_delete"
    else
      _log_kind "$kind" "Cmd: $(_mdm_wrap "$cmd")"
    fi
  else
    # MDM: templatize a home path inside a string VALUE too.
    if [ "$MDM_OUTPUT" = "true" ] && [[ "$cmd" == *"$TARGET_HOME"* ]]; then
      cmd="${cmd//"$TARGET_HOME"/$_MDM_HOME_REPL}"
    fi
    _log_kind "$kind" "Cmd: $(_mdm_wrap "$cmd")"
  fi
}

# Consume the stream of the Python workers: PBCMD lines are emitted, metadata lines
# fill _SKIP_KEYS. Args: kind dom meta_raw plist_path
_process_py_meta() {
  local kind="$1" dom="$2" meta_raw="$3" plist_path="$4"
  [ -n "$meta_raw" ] || return 0

  local _domain_note_emitted=false _last_array_base=""
  local -a _pending_comments=()
  local _array_base _array_idx _array_keys _pb_cmd _pc _k _mdm_path _pb_esc pb_full
  local -a _array_key_list

  while IFS=$'\t' read -r _array_base _array_idx _array_keys; do
    [ -n "$_array_base" ] || continue
    # ARRAYRW: the whole string array in one command; the deletion worker skips it.
    if [ "$_array_base" = "ARRAYRW" ]; then
      local _rw_base="$_array_idx" _rw_host=""
      _SKIP_KEYS["$_rw_base"]=1
      _ARRAY_REWRITTEN["$_rw_base"]=1
      if is_noisy_key "$dom" "$_rw_base"; then _dbg_filtered "$dom $_rw_base (noise-array)"; continue; fi
      if [ "$_domain_note_emitted" = "false" ]; then
        _emit_contextual_note "$dom" "$_rw_base"
        _domain_note_emitted=true
      fi
      [[ "$plist_path" == *"/ByHost/"* ]] && _rw_host="-currentHost "
      if [ "$dom" = com.apple.Spotlight ] && [ "$_rw_base" = EnabledPreferenceRules ]; then
        _note_spotlight_list "$kind" "$_array_keys"
      else
        _note_should_show "__arrayrw__:$dom:$_rw_base" \
          && _log_kind "$kind" "Cmd: #       (rewrites the whole '$_rw_base' list. Reproduces it, does not merge)"
      fi
      _log_kind "$kind" "Cmd: $(_mdm_wrap "defaults ${_rw_host}write \"$(_escape_dq "$dom")\" \"$(_escape_dq "$_rw_base")\" -array ${_array_keys}")"
      continue
    fi
    if [ "$_array_base" = "PBCMD" ]; then
      _pb_cmd="$_array_idx"
      if [[ "$_pb_cmd" == "#"* ]]; then
        _pending_comments+=("$_pb_cmd")
        continue
      fi
      [ -n "$plist_path" ] || continue
      if is_noisy_pbcmd "$dom" "$_pb_cmd"; then
        # A filtered network path still gets a NOTE naming the real command.
        _note_network_service "$kind" "$dom" "$_pb_cmd" "$plist_path"
        _dbg_filtered "$dom. $_pb_cmd (noise-key)"; continue
      fi
      if [ "$_domain_note_emitted" = "false" ]; then
        _emit_contextual_note "$dom" "$_last_array_base"
        _domain_note_emitted=true
      fi
      if (( ${#_pending_comments[@]} > 0 )); then
        for _pc in "${_pending_comments[@]}"; do
          # Precede a dockutil info comment with the "it's an ALTERNATIVE" NOTE.
          [[ "$_pc" == "# dockutil"* ]] && _note_dockutil_alt "$kind"
          _log_kind "$kind" "Cmd: $(_mdm_wrap_comment "$_pc")"
        done
        _pending_comments=()
      fi
      _mdm_path=$(mdm_plist_path "$plist_path")
      _note_byhost_uuid "$kind" "$_mdm_path" "$_pb_cmd"
      _note_device_uuid "$kind" "$_pb_cmd"
      # MDM: rewrite the capture user home inside the VALUE too (quoted: literal match).
      local _mdm_home_hit=false
      if [ "$MDM_OUTPUT" = "true" ] && [[ "$_pb_cmd" == *"$TARGET_HOME"* ]]; then
        _pb_cmd="${_pb_cmd//"$TARGET_HOME"/$_MDM_HOME_REPL}"
        _mdm_home_hit=true
      fi
      # Escape ' for the -c wrapper (see _SQ_ESC).
      _pb_esc="${_pb_cmd//$_SQ/$_SQ_ESC}"
      # …then break out of the quotes so $loggedInUser expands at run time.
      [ "$_mdm_home_hit" = true ] && _pb_esc="${_pb_esc//"$_MDM_LIU"/$_MDM_LIU_QB}"
      pb_full="/usr/libexec/PlistBuddy -c '${_pb_esc}' \"$(_escape_pb_path "$_mdm_path")\""
      _log_kind "$kind" "Cmd: $(_mdm_wrap "$pb_full")"
      continue
    fi
    # Metadata line: fill _SKIP_KEYS at every level the workers produced.
    _last_array_base="$_array_base"
    _SKIP_KEYS["$_array_base"]=1
    if [ -n "$_array_idx" ]; then
      _SKIP_KEYS[":${_array_base}:${_array_idx}"]=1
    fi
    if [ -n "$_array_keys" ]; then
      IFS=',' read -rA _array_key_list <<< "$_array_keys"
      for _k in "${_array_key_list[@]}"; do
        [ -n "$_k" ] || continue
        _k="${_k#"${_k%%[![:space:]]*}"}"; _k="${_k%"${_k##*[![:space:]]}"}"   # trim, fork-free
        [ -n "$_k" ] || continue
        _SKIP_KEYS["$_k"]=1
        _SKIP_KEYS["${_array_base}:${_k}"]=1
        _SKIP_KEYS[":${_array_base}:${_k}"]=1
        if [ -n "$_array_idx" ]; then
          _SKIP_KEYS["${_array_base}:${_array_idx}:${_k}"]=1
          _SKIP_KEYS[":${_array_base}:${_array_idx}:${_k}"]=1
        fi
      done
    fi
  done <<< "$meta_raw"
  # Flush buffered comments (a NOTE can be the only output), except the two that
  # INTRODUCE commands, when every PBCMD was filtered.
  if (( ${#_pending_comments[@]} > 0 )) && [ -n "$plist_path" ]; then
    for _pc in "${_pending_comments[@]}"; do
      case "$_pc" in
        "# NOTE: array index :N is positional"*|"# NOTE: new key tree"*|"#       If this came from first opening"*) continue ;;
      esac
      [[ "$_pc" == "# dockutil"* ]] && _note_dockutil_alt "$kind"
      _log_kind "$kind" "Cmd: $(_mdm_wrap_comment "$_pc")"
    done
    _pending_comments=()
  fi
}

# Walk diff(prev,curr), emit writes/deletes via _emit_cmd for keys not in
# _SKIP_KEYS or noisy. Args: kind dom hostflag prev curr type_src diff_label
_process_diff_lines() {
  # $8 = real plist path for deletes. Not type_src, which can be a cache file.
  local kind="$1" dom="$2" hostflag="$3" prev="$4" curr="$5" type_src="$6" diff_label="$7" emit_plist_path="${8:-}"

  # No baseline: USER/SYSTEM means a domain born since startup (its first write
  # is its configuration); DOMAIN in ALL mode means "not seen yet" (stay silent).
  if [ ! -s "$prev" ]; then
    [ "${_BASELINE_DONE:-false}" = "true" ] || return 0
    [ "$kind" = "DOMAIN" ] && [ "${ALL_MODE:-false}" = "true" ] && return 0
    # An existing but EMPTY baseline is a failed snapshot, not a new domain:
    # adopt the current state silently.
    if [ -e "$prev" ]; then
      /bin/cp -f "$curr" "$prev" 2>/dev/null || :
      return 0
    fi
    # Missing prev: `diff -u` would print nothing. Create an empty baseline.
    : > "$prev" 2>/dev/null || return 0
    # DEFERRED until this domain emits a line; cleared at the end of this pass.
    if _note_should_show "__newdom__:${dom}"; then
      typeset -g _PENDING_NEWDOM_NOTE="Cmd: # NOTE: '$dom' is a new domain. The commands below are its full configuration, not a single change"
    fi
  fi

  typeset -A _added_keys
  _added_keys=()
  local _aline
  while IFS= read -r _aline; do
    # `if`, not `&&`: a non-match as last command trips set -e.
    if [[ "$_aline" =~ '^\+[[:space:]]*"([^"]+)"' ]]; then _added_keys["$match[1]"]=1; fi
  done < <(/usr/bin/diff -u "$prev" "$curr" 2>/dev/null | /usr/bin/awk 'NR>2 && $0 ~ /^\+/ && $0 !~ /^\+\+\+/' || true)  # diff exits 1 when files differ (always, here) → pipefail fires ZERR/set -e; guard it

  local dline kv keyname val snippet pretty_key array_meta array_name array_idx trimmed cmd delete_cmd
  while IFS= read -r dline; do
    [ -n "$dline" ] || continue

    _log_kind "$kind" "Diff $diff_label: $dline"

    array_meta="" array_name="" array_idx=""
    [[ "$dline" =~ '^[+-][[:space:]]*"([^"]+)"[[:space:]]*=>[[:space:]]*(.*)$' ]] || continue
    keyname="$match[1]"
    val="$match[2]"

    [ -n "${_SKIP_KEYS[$keyname]:-}" ] && continue

    # Drop sub-keys of dict additions leaking into the top-level diff.
    if [ "${_HAS_ARRAY_ADDITIONS:-false}" = "true" ] && [[ "$keyname" != *":"* ]]; then
      if [[ "$keyname" == *" "* ]] || \
         [[ "$keyname" =~ ^(InputSourceKind|KeyboardLayout|tile-data|file-data|file-label|bundle-identifier|_CFURLString).*$ ]]; then
        continue
      fi
    fi

    if is_noisy_key "$dom" "$keyname"; then _dbg_filtered "$dom $keyname (noise-key)"; continue; fi

    if array_meta=$(parse_array_index_key "$keyname" 2>/dev/null); then
      array_name="${array_meta%% *}"
      array_idx="${array_meta##* }"
      pretty_key="${array_name}[${array_idx}]"
    else
      pretty_key="$keyname"
    fi

    snippet="${val//$'\n'/ }"
    (( ${#snippet} > 160 )) && snippet="${snippet[1,157]}..."
    _log_kind "$kind" "Key: ${pretty_key} | Item: ${snippet}"

    case "$dline" in
      +*)
        [ -n "$array_name" ] && continue
        [[ "$dline" =~ ^[+][[:space:]]{4,}\" ]] && continue
        trimmed="${val#"${val%%[![:space:]]*}"}"; trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        cmd=$(_build_defaults_write_cmd "$dom" "$keyname" "$trimmed" "$hostflag" "$type_src")
        _emit_cmd "$kind" "$cmd" "$dom" false
        ;;
      -*)
        [[ "$dline" =~ ^[-][[:space:]]{4,}\" ]] && continue
        [ -n "${_added_keys[$keyname]:-}" ] && continue
        [[ "$dom" == com.apple.print.custompresets* ]] && continue
        # Truly gone, not just changed.
        if [ -z "$array_name" ] && /usr/bin/grep -qF "\"$keyname\" =>" "$curr" 2>/dev/null; then
          continue
        fi
        delete_cmd=$(_build_defaults_delete_cmd "$dom" "$keyname" "$array_name" "$array_idx" "$hostflag")
        _emit_cmd "$kind" "$delete_cmd" "$dom" true "$emit_plist_path"
        ;;
    esac
  done < <(/usr/bin/diff -u "$prev" "$curr" 2>/dev/null | /usr/bin/awk 'NR>2 && ($0 ~ /^\+/ || $0 ~ /^-/) && $0 !~ /^\+\+\+|^---/' || true)  # diff exits 1 when files differ (always, here) → pipefail fires ZERR/set -e; guard it
  # Nothing came out: drop the NOTE so it does not precede the next domain.
  typeset -g _PENDING_NEWDOM_NOTE=""
}

# ---------------------------------------
# Diff Engine
#
# Three python3 workers compare the previous and current JSON dumps of a plist:
# array additions, array deletions, nested dict changes. Their output is fed to
# _process_py_meta above.
# ---------------------------------------

parse_array_index_key() {
  local raw="$1"
  if [[ "$raw" == :*:* ]]; then
    local inner="${raw#:}"
    local base="${inner%%:*}"
    local idx="${inner##*:}"
    if [[ -n "$base" && "$idx" =~ ^[0-9]+$ ]]; then
      printf '%s %s\n' "$base" "$idx"
      return 0
    fi
  fi
  return 1
}

emit_array_additions() {
  local kind="$1" dom="$2" prev_json="$3" curr_json="$4" precomputed="${5:-}"
  [ -n "$PYTHON3_BIN" ] || return 0
  [ -s "$curr_json" ] || return 0
  [ -s "$prev_json" ] || return 0

  local py_output
  if [ -n "$precomputed" ] && [ -f "$precomputed" ]; then
    py_output=$(< "$precomputed")
  else
  py_output=$("$PYTHON3_BIN" - "$dom" "$prev_json" "$curr_json" "${(j:,:)_ELEMENT_NOISE_MARKERS}" <<'PY'
import json, sys, os

domain, prev_path, curr_path = sys.argv[1], sys.argv[2], sys.argv[3]

# _ELEMENT_NOISE_MARKERS triplets: a marked element is skipped WHOLE.
_NOISE_RULES = []
for _spec in (sys.argv[4] if len(sys.argv) > 4 else '').split(','):
    _parts = _spec.split('|')
    if len(_parts) == 3:
        _NOISE_RULES.append(tuple(_parts))
def is_noise_element(arr_name, item):
    if not _NOISE_RULES:
        return False
    blob = json.dumps(item, sort_keys=True, default=str)
    return any(d == domain and a == arr_name and m in blob for d, a, m in _NOISE_RULES)

def load(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return {}
    with open(path, 'r') as handle:
        try:
            return json.load(handle)
        except Exception:
            return {}

prev = load(prev_path)
curr = load(curr_path)

results = []

# SHARED BLOCK in the three Python workers: EDIT ALL THREE TOGETHER.
_VOLATILE_KEYS = {'parent-mod-date', 'file-mod-date', 'file-type', 'dock-extra',
                  'is-beta', 'tile-type', 'GUID', 'book'}

def strip_volatile(obj):
    """Strip volatile metadata keys for stable array element matching"""
    if isinstance(obj, dict):
        return {k: strip_volatile(v) for k, v in obj.items() if k not in _VOLATILE_KEYS}
    if isinstance(obj, list):
        return [strip_volatile(e) for e in obj]
    return obj

def diff(prev_obj, curr_obj, path):
    if isinstance(curr_obj, dict):
        prev_dict = prev_obj if isinstance(prev_obj, dict) else {}
        for key, value in curr_obj.items():
            diff(prev_dict.get(key), value, path + [key])
    elif isinstance(curr_obj, list):
        prev_list = prev_obj if isinstance(prev_obj, list) else []
        prev_fps = [json.dumps(strip_volatile(e), sort_keys=True) for e in prev_list]
        prev_avail = {}
        for i, fp in enumerate(prev_fps):
            prev_avail.setdefault(fp, []).append(i)
        for idx, item in enumerate(curr_obj):
            fp = json.dumps(strip_volatile(item), sort_keys=True)
            if fp in prev_avail and prev_avail[fp]:
                prev_avail[fp].pop(0)
            else:
                results.append((tuple(path), idx, item))
    else:
        return

def all_keys_recursive(obj):
    """Collect ALL keys recursively from nested dicts (for _skip_keys)"""
    keys = set()
    if isinstance(obj, dict):
        for k, v in obj.items():
            keys.add(str(k))
            keys |= all_keys_recursive(v)
    elif isinstance(obj, list):
        for item in obj:
            keys |= all_keys_recursive(item)
    return keys

def pb_type_value(val):
    """Return (type, value) for PlistBuddy Add command"""
    if isinstance(val, bool):
        return ("bool", "true" if val else "false")
    if isinstance(val, int):
        return ("integer", str(val))
    if isinstance(val, float):
        return ("real", str(val))
    if isinstance(val, str):
        # PlistBuddy strips a leading space: quote values with edge whitespace.
        if val[:1].isspace() or val[-1:].isspace():
            return ("string", '"' + val.replace('"', '\\"') + '"')
        return ("string", val)
    return None

def pb_escape(s):
    """Escape spaces in PlistBuddy key paths"""
    return s.replace(' ', '\\ ')

_arr_empty_noted = [False]
def emit_plistbuddy(array_name, index, item, path_prefix=""):
    """Recursively generate PlistBuddy Add commands for nested dicts"""
    cmds = []
    if isinstance(item, dict):
        for k, v in item.items():
            if k == '':
                # Empty-string key → a bare '::' PlistBuddy can't address; skip the subtree.
                if not _arr_empty_noted[0]:
                    cmds.append("PBCMD\t# NOTE: an empty-string key ('') was skipped. PlistBuddy can't address it")
                    _arr_empty_noted[0] = True
                continue
            key_path = f"{path_prefix}{pb_escape(k)}"
            if isinstance(v, dict):
                cmds.append(f"PBCMD\tAdd :{array_name}:{index}:{key_path} dict")
                cmds.extend(emit_plistbuddy(array_name, index, v, key_path + ":"))
            elif isinstance(v, list):
                cmds.append(f"PBCMD\tAdd :{array_name}:{index}:{key_path} array")
                for j, elem in enumerate(v):
                    tv = pb_type_value(elem)
                    if tv:
                        cmds.append(f"PBCMD\tAdd :{array_name}:{index}:{key_path}:{j} {tv[0]} {tv[1]}")
                    elif isinstance(elem, dict):
                        cmds.append(f"PBCMD\tAdd :{array_name}:{index}:{key_path}:{j} dict")
                        cmds.extend(emit_plistbuddy(array_name, index, elem, f"{key_path}:{j}:"))
            else:
                tv = pb_type_value(v)
                if tv:
                    cmds.append(f"PBCMD\tAdd :{array_name}:{index}:{key_path} {tv[0]} {tv[1]}")
    return cmds

diff(prev, curr, [])

# An all-string array gaining elements is emitted whole (`-array`), no index.
# A " or \ in any element falls back to the positional Add.
def rewritable(arr_name):
    arr = curr.get(arr_name)
    return (isinstance(arr, list) and arr
            and all(isinstance(e, str) for e in arr)
            and not any(any(c in e for c in '"\\\n\t') for e in arr))
_rewritten = set()

_array_add_noted = False
for prefix, index, item in results:
    if len(prefix) != 1:
        continue
    arr_name = prefix[0]
    # Whole-element noise: skip before anything is printed.
    if is_noise_element(arr_name, item):
        continue
    if arr_name not in prev:
        continue
    # Before the same-length skip: a same-length REPLACE is a content change
    # ([a, b] → [b, c] once emitted only `Set :1 c`).
    if isinstance(item, str) and rewritable(arr_name):
        print(f"{prefix[0]}\t{index}\t\t")
        if arr_name not in _rewritten:
            _rewritten.add(arr_name)
            print("ARRAYRW\t%s\t%s" % (arr_name, ' '.join(
                '"%s"' % e.replace('$', '\\$').replace('`', '\\`') for e in curr[arr_name])))
        continue
    # Same length: a reorder, not an addition.
    if arr_name in curr and isinstance(prev[arr_name], list) and isinstance(curr[arr_name], list) and len(prev[arr_name]) == len(curr[arr_name]):
        continue
    # Existing array: the index is positional. Warn once.
    if not _array_add_noted:
        print("PBCMD\t# NOTE: array index :N is positional. May land elsewhere if the target's array differs")
        _array_add_noted = True
    if isinstance(item, dict):
        keys = ','.join(sorted(all_keys_recursive(item)))
        print(f"{prefix[0]}\t{index}\t{keys}\t")
        if domain == "com.apple.dock" and arr_name in ("persistent-apps", "persistent-others"):
            td = item.get("tile-data", {})
            if isinstance(td, dict):
                label = td.get("file-label", "")
                bid = td.get("bundle-identifier", "")
                if label:
                    note = f"# Dock: {label}"
                    if bid:
                        note += f" ({bid})"
                    print(f"PBCMD\t{note}")
                # dockutil equivalent, as a comment: the Add lines below suffice.
                import urllib.parse as _up
                _url = (td.get("file-data") or {}).get("_CFURLString") or ""
                _path = _up.unquote(_url.replace("file://", "").rstrip("/")) if _url else ""
                if _path:
                    _sect = "apps" if arr_name == "persistent-apps" else "others"
                    _du = f"# dockutil --add '{_path}' --section {_sect}"
                    if arr_name == "persistent-others":
                        def _i(v):
                            try: return int(v)          # tile-data may store these as int OR string
                            except Exception: return None
                # dockutil says 'auto', not 'automatic'.
                        _view = {0: "auto", 1: "fan", 2: "grid", 3: "list"}.get(_i(td.get("showas")), "auto")
                        _disp = {0: "stack", 1: "folder"}.get(_i(td.get("displayas")), "stack")
                        _sort = {1: "name", 2: "dateadded", 3: "datemodified", 4: "datecreated", 5: "kind"}.get(_i(td.get("arrangement")), "name")
                        _du += f" --view {_view} --display {_disp} --sort {_sort}"
                    print(f"PBCMD\t{_du}")
        print(f"PBCMD\tAdd :{prefix[0]}:{index} dict")
        for pb_line in emit_plistbuddy(prefix[0], index, item):
            print(pb_line)
    else:
        tv = pb_type_value(item)
        if tv:
            print(f"{prefix[0]}\t{index}\t\t")
            print(f"PBCMD\tAdd :{prefix[0]}:{index} {tv[0]} {tv[1]}")
PY
) || return 0
  fi

  [ -n "$py_output" ] || return 0

  # Runs inside $(): the caller logs the PBCMD lines.
  printf '%s\n' "$py_output"
}

# Array-deletion worker; prints to stdout so the caller can prefetch it in parallel.
_py_deletions_raw() {
  local dom="$1" prev_json="$2" curr_json="$3"
  [ -n "$PYTHON3_BIN" ] || return 0
  [ -s "$curr_json" ] || return 0
  [ -s "$prev_json" ] || return 0
  "$PYTHON3_BIN" - "$dom" "$prev_json" "$curr_json" "${(j:,:)_ELEMENT_NOISE_MARKERS}" <<'PY'
import json, sys, os

domain, prev_path, curr_path = sys.argv[1], sys.argv[2], sys.argv[3]

# _ELEMENT_NOISE_MARKERS: on a deletion only this side sees the values.
_NOISE_RULES = []
for _spec in (sys.argv[4] if len(sys.argv) > 4 else '').split(','):
    _parts = _spec.split('|')
    if len(_parts) == 3:
        _NOISE_RULES.append(tuple(_parts))
def is_noise_element(arr_name, item):
    if not _NOISE_RULES:
        return False
    blob = json.dumps(item, sort_keys=True, default=str)
    return any(d == domain and a == arr_name and m in blob for d, a, m in _NOISE_RULES)

def load(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return {}
    with open(path, 'r') as handle:
        try:
            return json.load(handle)
        except Exception:
            return {}

prev = load(prev_path)
curr = load(curr_path)

results = []

# SHARED BLOCK in the three Python workers: EDIT ALL THREE TOGETHER.
_VOLATILE_KEYS = {'parent-mod-date', 'file-mod-date', 'file-type', 'dock-extra',
                  'is-beta', 'tile-type', 'GUID', 'book'}

def strip_volatile(obj):
    """Strip volatile metadata keys for stable array element matching"""
    if isinstance(obj, dict):
        return {k: strip_volatile(v) for k, v in obj.items() if k not in _VOLATILE_KEYS}
    if isinstance(obj, list):
        return [strip_volatile(e) for e in obj]
    return obj

def diff_deletions(prev_obj, curr_obj, path):
    """Find deleted elements by comparing prev with curr"""
    if isinstance(prev_obj, dict):
        curr_dict = curr_obj if isinstance(curr_obj, dict) else {}
        for key, value in prev_obj.items():
            diff_deletions(value, curr_dict.get(key), path + [key])
    elif isinstance(prev_obj, list):
        curr_list = curr_obj if isinstance(curr_obj, list) else []
        curr_fps = [json.dumps(strip_volatile(e), sort_keys=True) for e in curr_list]
        curr_avail = {}
        for i, fp in enumerate(curr_fps):
            curr_avail.setdefault(fp, []).append(i)
        for prev_idx, prev_item in enumerate(prev_obj):
            fp = json.dumps(strip_volatile(prev_item), sort_keys=True)
            if fp in curr_avail and curr_avail[fp]:
                curr_avail[fp].pop(0)
            else:
                results.append((tuple(path), prev_idx, prev_item))
    else:
        return

diff_deletions(prev, curr, [])

# Highest index first: each Delete shifts the ones above it.
results.sort(key=lambda r: r[1], reverse=True)

for path_tuple, index, item in results:
    if not path_tuple:
        continue
    if len(path_tuple) != 1:
        continue
    array_name = path_tuple[-1] if path_tuple else ""
    if is_noise_element(array_name, item):
        continue
    # Same length: a reorder, not a deletion.
    if array_name in prev and array_name in curr and isinstance(prev[array_name], list) and isinstance(curr[array_name], list) and len(prev[array_name]) == len(curr[array_name]):
        continue
    app_label = ""
    if domain == "com.apple.dock" and array_name in ("persistent-apps", "persistent-others"):
        if isinstance(item, dict):
            td = item.get("tile-data", {})
            if isinstance(td, dict):
                app_label = td.get("file-label", "")
    if isinstance(item, dict):
        keys = ','.join(str(k) for k in item.keys())
    else:
        keys = ""
    # 5th field: the VALUE, when it occurs exactly once (a positional Delete on a
    # different target removes whatever sits there).
    value = ""
    if isinstance(item, str) and isinstance(prev.get(array_name), list):
        if sum(1 for e in prev[array_name] if e == item) == 1 and "\t" not in item and "\n" not in item:
            value = item
    # 6th field: the array as it is NOW (`-array`), the only python3-free
    # removal. Not "prev minus this element": two removals in one diff then gave
    # two lines, each keeping the other element. All-string arrays only (-array
    # stringifies); " or \ falls back. %EMPTY% = emptied, a bare `-array`.
    rewrite = ""
    remaining = curr.get(array_name)
    if (isinstance(prev.get(array_name), list) and all(isinstance(e, str) for e in prev[array_name])
            and isinstance(remaining, list) and all(isinstance(e, str) for e in remaining)):
        if not remaining:
            rewrite = "%EMPTY%"
        elif not any(any(c in e for c in '"\\\n\t') for e in remaining):
            rewrite = ' '.join(
                '"%s"' % e.replace('$', '\\$').replace('`', '\\`') for e in remaining)
    # \x1f, not tab: zsh collapses consecutive tabs, empty fields vanish.
    print(f"{array_name}\x1f{index}\x1f{keys}\x1f{app_label}\x1f{value}\x1f{rewrite}")
PY
}

# Remove ONE array element by VALUE through python3 and defaults export/import
# (cfprefsd would overwrite a direct write). Empty if a quote would break it.
_build_array_value_delete() {
  local dom="$1" key="$2" val="$3"
  case "$dom$key$val" in *\'*|*\\*) return 1 ;; esac
  printf "/usr/bin/python3 -c 'import subprocess as s, plistlib; d=\"%s\"; k=\"%s\"; v=\"%s\"; p=plistlib.loads(s.run([\"/usr/bin/defaults\",\"export\",d,\"-\"],capture_output=True).stdout); p[k]=[x for x in p.get(k,[]) if x!=v]; s.run([\"/usr/bin/defaults\",\"import\",d,\"-\"],input=plistlib.dumps(p))'" \
    "$(_escape_dq "$dom")" "$(_escape_dq "$key")" "$(_escape_dq "$val")"
}

emit_array_deletions() {
  # $6 = real plist path, so a ByHost array deletion targets the ByHost file.
  local kind="$1" dom="$2" prev_json="$3" curr_json="$4" precomputed="${5:-}" emit_plist_path="${6:-}"
  [ -n "$PYTHON3_BIN" ] || return 0
  [ -s "$curr_json" ] || return 0
  [ -s "$prev_json" ] || return 0

  local py_output
  if [ -n "$precomputed" ] && [ -f "$precomputed" ]; then
    py_output=$(< "$precomputed")
  else
    py_output=$(_py_deletions_raw "$dom" "$prev_json" "$curr_json") || return 0
  fi

  [ -n "$py_output" ] || return 0

  typeset -A _noted_del_arrays=()
  while IFS=$'\x1f' read -r base idx keylist app_label elem_value elem_rewrite; do
    [ -n "$base" ] || continue
    # This worker owns the key, or the diff pass builds an invalid write.
    _SKIP_KEYS["$base"]=1

    if is_noisy_key "$dom" "$base"; then _dbg_filtered "$dom $base (noise-array)"; continue; fi
    # Already emitted whole by the additions worker (a replace in one diff).
    if [ -n "${_ARRAY_REWRITTEN[$base]:-}" ]; then _dbg_filtered "$dom $base (rewritten whole above)"; continue; fi
    # Print presets: deletions skipped (removing a printer empties the plist).
    if [[ "$dom" == com.apple.print.custompresets* ]]; then _dbg_filtered "$dom :$base:$idx (preset deletion, by design)"; continue; fi

    if [ -z "${_noted_del_arrays[$base]:-}" ]; then
      _emit_contextual_note "$dom" "$base"
      _noted_del_arrays[$base]=1
    fi

    # Dock: `dockutil --remove` by label; the Delete below works on its own.
    if [ -n "$app_label" ]; then
      _note_dockutil_alt "$kind"
      _log_kind "$kind" "Cmd: # dockutil --remove '$app_label'"
    fi

    # $dom and $base come from the plist: escape them like the builder does.
    local delete_cmd="defaults delete \"$(_escape_dq "$dom")\" \":$(_escape_dq "$base"):${idx}\""

    local _val_cmd="" _rw_cmd=""
    # Prefer the python3-free form: the target usually lacks the CLT.
    if [ "${elem_rewrite:-}" = "%EMPTY%" ]; then
      _rw_cmd="defaults write \"$(_escape_dq "$dom")\" \"$(_escape_dq "$base")\" -array"
    elif [ -n "${elem_rewrite:-}" ]; then
      _rw_cmd="defaults write \"$(_escape_dq "$dom")\" \"$(_escape_dq "$base")\" -array ${elem_rewrite}"
    fi
    if [ -z "$_rw_cmd" ] && [ -n "${elem_value:-}" ]; then _val_cmd=$(_build_array_value_delete "$dom" "$base" "$elem_value") || _val_cmd=""; fi

    if is_noisy_command "$delete_cmd"; then
      :
    elif [ "$kind" = "DOMAIN" ] && [ "${ALL_MODE:-false}" = "true" ]; then
      :
    elif [ -n "$_rw_cmd" ]; then
      # Whole-array rewrite: no index, no "order shown" warning. Replaces, does not merge.
      if [ "$dom" = com.apple.Spotlight ] && [ "$base" = EnabledPreferenceRules ]; then
        _note_spotlight_list "$kind" "${${elem_rewrite#%EMPTY%}}"
      else
        _note_should_show "__arrayrw__:$dom:$base" \
          && _log_kind "$kind" "Cmd: #       (rewrites the whole '$base' list. Reproduces it, does not merge)"
      fi
      _log_kind "$kind" "Cmd: $(_mdm_wrap "$_rw_cmd")"
      # The final state is out: the array's other deletions are covered.
      _ARRAY_REWRITTEN[$base]=1
    elif [ -n "$_val_cmd" ]; then
      # Value-targeted: no index, so no "order shown" warning.
      _log_kind "$kind" "Cmd: $(_mdm_wrap "$_val_cmd")"
      # Same caveat as the Bluetooth line: this one runs python3 on the TARGET.
      _note_should_show __arraydel_py__ \
        && _log_kind "$kind" "Cmd: #       (needs python3 on the TARGET. Without the Command Line Tools /usr/bin/python3 only offers to install them)"
    else
      local pb_delete=""  # init: re-`local` in this read-loop would print `pb_delete=…`
      if pb_delete=$(convert_delete_to_plistbuddy "$delete_cmd" "$emit_plist_path" "$dom" 2>/dev/null); then
        while IFS= read -r pb_line; do
          [ -n "$pb_line" ] || continue
          case "$pb_line" in
            "# WARNING: array deletes"*)
              _note_should_show __array_del_warning__ || continue ;;
          esac
          # Only the real PlistBuddy command is --mdm-wrapped, not comments.
          case "$pb_line" in
            "#"*) _log_kind "$kind" "Cmd: $pb_line" ;;
            *)    _log_kind "$kind" "Cmd: $(_mdm_wrap "$pb_line")" ;;
          esac
        done <<< "$pb_delete"
      else
        _log_kind "$kind" "Cmd: $(_mdm_wrap "$delete_cmd")"
      fi
    fi
  done <<< "$py_output"
}

# PlistBuddy commands for changes deep inside nested dicts (symbolichotkeys, …).
emit_nested_dict_changes() {
  local kind="$1" dom="$2" prev_json="$3" curr_json="$4" precomputed="${5:-}"
  [ -n "$PYTHON3_BIN" ] || return 0
  [ -s "$curr_json" ] || return 0
  [ -s "$prev_json" ] || return 0

  local py_output
  if [ -n "$precomputed" ] && [ -f "$precomputed" ]; then
    py_output=$(< "$precomputed")
  else
  py_output=$("$PYTHON3_BIN" - "$dom" "$prev_json" "$curr_json" "${(j:,:)_PRINT_PRESET_NOISE}" <<'PY'
import json, sys, os

domain, prev_path, curr_path = sys.argv[1], sys.argv[2], sys.argv[3]

def load(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return {}
    with open(path, 'r') as handle:
        try:
            return json.load(handle)
        except Exception:
            return {}

prev = load(prev_path)
curr = load(curr_path)

# SHARED BLOCK in the three Python workers: EDIT ALL THREE TOGETHER.
_VOLATILE_KEYS = {'parent-mod-date', 'file-mod-date', 'file-type', 'dock-extra',
                  'is-beta', 'tile-type', 'GUID', 'book'}

def strip_volatile(obj):
    """Strip volatile metadata keys for stable array element matching"""
    if isinstance(obj, dict):
        return {k: strip_volatile(v) for k, v in obj.items() if k not in _VOLATILE_KEYS}
    if isinstance(obj, list):
        return [strip_volatile(e) for e in obj]
    return obj

def pb_type_value(val):
    """Return (type, value) for PlistBuddy Add command"""
    if isinstance(val, bool):
        return ("bool", "true" if val else "false")
    if isinstance(val, int):
        return ("integer", str(val))
    if isinstance(val, float):
        return ("real", str(val))
    if isinstance(val, str):
        # PlistBuddy strips a leading space: quote values with edge whitespace.
        if val[:1].isspace() or val[-1:].isspace():
            return ("string", '"' + val.replace('"', '\\"') + '"')
        return ("string", val)
    return None

def find_leaf_changes(prev_obj, curr_obj, path_parts):
    """Recursively find changed leaf values, added sub-keys, and deleted sub-keys."""
    if prev_obj == curr_obj:
        return [], [], []
    changes = []
    additions = []
    deletions = []
    if isinstance(prev_obj, dict) and isinstance(curr_obj, dict):
        all_keys = sorted(set(list(prev_obj.keys()) + list(curr_obj.keys())))
        for key in all_keys:
            if key in prev_obj and key in curr_obj:
                c, a, d = find_leaf_changes(prev_obj[key], curr_obj[key], path_parts + [str(key)])
                changes.extend(c)
                additions.extend(a)
                deletions.extend(d)
            elif key in curr_obj:
                additions.append((path_parts + [str(key)], curr_obj[key]))
            elif key in prev_obj:
                deletions.append((path_parts + [str(key)],))
    elif isinstance(prev_obj, list) and isinstance(curr_obj, list):
        for i in range(min(len(prev_obj), len(curr_obj))):
            c, a, d = find_leaf_changes(prev_obj[i], curr_obj[i], path_parts + [str(i)])
            changes.extend(c)
            additions.extend(a)
            deletions.extend(d)
        for i in range(len(prev_obj), len(curr_obj)):
            additions.append((path_parts + [str(i)], curr_obj[i]))
        # Array shrank: highest index first.
        for i in reversed(range(len(curr_obj), len(prev_obj))):
            deletions.append((path_parts + [str(i)],))
    else:
        tv = pb_type_value(curr_obj)
        if tv:
            changes.append((path_parts, tv))
    return changes, additions, deletions

# An empty-string key makes a bare '::' path that PlistBuddy collapses (the value
# lands one level up). Skip that subtree and note it once.
_empty_key_noted = [False]
def _note_empty_key():
    if not _empty_key_noted[0]:
        print("PBCMD\t# NOTE: a key path has an empty-string key (''). PlistBuddy can't address it, so that subtree is skipped (not reproducible)")
        _empty_key_noted[0] = True

def emit_add_tree(base_parts, obj):
    if any(p == '' for p in base_parts):
        _note_empty_key(); return
    if isinstance(obj, dict):
        path = ':'.join(p.replace(' ', '\\ ') for p in base_parts)
        print(f"PBCMD\tAdd :{path} dict")
        for k in sorted(obj.keys()):
            emit_add_tree(base_parts + [str(k)], obj[k])
    elif isinstance(obj, list):
        path = ':'.join(p.replace(' ', '\\ ') for p in base_parts)
        print(f"PBCMD\tAdd :{path} array")
        for i, item in enumerate(obj):
            emit_add_tree(base_parts + [str(i)], item)
    else:
        tv = pb_type_value(obj)
        if tv:
            path = ':'.join(p.replace(' ', '\\ ') for p in base_parts)
            print(f"PBCMD\tAdd :{path} {tv[0]} {tv[1]}")

# Print preset noise from the shell, fnmatchcase = zsh `case` semantics.
import fnmatch
_PRINT_PRESET_NOISE = [g for g in (sys.argv[4] if len(sys.argv) > 4 else '').split(',') if g]

def filter_print_preset_settings(settings_dict):
    """Drop the driver internals and last-job traces; keep everything else."""
    if not isinstance(settings_dict, dict):
        return settings_dict
    return {k: v for k, v in settings_dict.items()
            if not any(fnmatch.fnmatchcase(k, g) for g in _PRINT_PRESET_NOISE)}

is_print_preset = domain.startswith('com.apple.print.custompresets')

changed_top_keys = set()
_first_create_noted = False
for top_key in sorted(curr.keys()):
    if not isinstance(curr[top_key], (dict, list)):
        continue
    if top_key not in prev:
        # A NEW all-string list is one `-array` write: no tree, no index, no NOTE.
        _nv = curr[top_key]
        if (isinstance(_nv, list) and _nv and all(isinstance(e, str) for e in _nv)
                and not any(any(c in e for c in '"\\\n\t') for e in _nv)):
            changed_top_keys.add(top_key)
            print(f"{top_key}\t\t")
            print("ARRAYRW\t%s\t%s" % (top_key, ' '.join(
                '"%s"' % e.replace('$', '\\$').replace('`', '\\`') for e in _nv)))
            continue
        if not _first_create_noted:
            # A whole tree appearing is the first-open-a-pane case. Four leaves or
            # more: two Spotlight categories disabled by hand are not "defaults".
            def _leaves(o):
                if isinstance(o, dict): return sum(_leaves(v) for v in o.values())
                if isinstance(o, list): return sum(_leaves(v) for v in o)
                return 1
            print("PBCMD\t# NOTE: new key tree. The Add commands build it top-down; later changes to it emit Set.")
            if _leaves(curr[top_key]) >= 4:
                print("PBCMD\t#       If this came from first opening a settings pane, most of these values are untouched defaults, not your choices.")
            _first_create_noted = True
        changed_top_keys.add(top_key)
        sub_keys = set()
        def collect_keys(obj, parts):
            if isinstance(obj, dict):
                for k in obj:
                    sub_keys.add(k)
                    collect_keys(obj[k], parts + [k])
        tree_obj = curr[top_key]
        if is_print_preset and isinstance(tree_obj, dict):
            settings_key = 'com.apple.print.preset.settings'
            if settings_key in tree_obj:
                tree_obj = dict(tree_obj)
                tree_obj[settings_key] = filter_print_preset_settings(tree_obj[settings_key])
        collect_keys(tree_obj, [top_key])
        print(f"{top_key}\t\t{','.join(sorted(sub_keys))}")
        emit_add_tree([top_key], tree_obj)
        continue
    if not isinstance(prev[top_key], (dict, list)):
        continue
    changes, additions, deletions = find_leaf_changes(prev[top_key], curr[top_key], [top_key])
    # Top-level arrays: Add/Delete belong to the array workers; Set only in place.
    if isinstance(curr[top_key], list):
        additions = []
        deletions = []
        if len(prev[top_key]) != len(curr[top_key]):
            changes = []
        elif (curr[top_key] and all(isinstance(e, str) for e in curr[top_key])
              and not any(any(c in e for c in '"\\\n\t') for e in curr[top_key])):
            # All-string list: rewritten whole by emit_array_additions; per-index
            # Sets were wrong when an element also moved.
            changes = []
        elif changes:
            # Same length: drop Sets for elements that merely moved (reorders).
            prev_fps = [json.dumps(strip_volatile(e), sort_keys=True) for e in prev[top_key]]
            prev_fp_set = set(prev_fps)
            moved = set()
            for i, elem in enumerate(curr[top_key]):
                fp = json.dumps(strip_volatile(elem), sort_keys=True)
                if fp != prev_fps[i] and fp in prev_fp_set:
                    moved.add(str(i))
            if moved:
                changes = [(pp, tv) for pp, tv in changes if len(pp) < 2 or pp[1] not in moved]
    if not changes and not additions and not deletions:
        continue
    changed_top_keys.add(top_key)
    sub_keys = set()
    for path_parts, tv in changes:
        for part in path_parts:
            sub_keys.add(part)
    for path_parts, obj in additions:
        for part in path_parts:
            sub_keys.add(part)
    for tup in deletions:
        for part in tup[0]:
            sub_keys.add(part)
    print(f"{top_key}\t\t{','.join(sorted(sub_keys))}")
    # Deletes first: they must precede Adds for array replacements.
    for (path_parts,) in deletions:
        if any(p == '' for p in path_parts):
            _note_empty_key(); continue
        full_path = ':'.join(p.replace(' ', '\\ ') for p in path_parts)
        print(f"PBCMD\tDelete :{full_path}")
    for path_parts, obj in additions:
        emit_add_tree(path_parts, obj)
    for path_parts, (ptype, pvalue) in changes:
        if is_print_preset and len(path_parts) >= 3 and path_parts[1] == 'com.apple.print.preset.settings':
            settings_key = path_parts[2]
            if any(fnmatch.fnmatchcase(settings_key, g) for g in _PRINT_PRESET_NOISE):
                continue
        if any(p == '' for p in path_parts):
            _note_empty_key(); continue
        full_path = ':'.join(p.replace(' ', '\\ ') for p in path_parts)
        print(f"PBCMD\tSet :{full_path} {pvalue}")
PY
) || return 0
  fi

  [ -n "$py_output" ] || return 0

  printf '%s\n' "$py_output"
}

# Run the 3 Python workers in parallel; fill the GLOBALS _SKIP_KEYS and
# _HAS_ARRAY_ADDITIONS (never local). Args: kind dom prev_json curr_json path key
_run_py_diff_workers() {
  local kind="$1" dom="$2" prev_json="$3" curr_json="$4" pb_plist_path="$5" key="$6"
  local _py_add="$CACHE_DIR/${key}.py.add" _py_del="$CACHE_DIR/${key}.py.del" _py_nest="$CACHE_DIR/${key}.py.nest"
  # Wait on these three pids, never a bare `wait` (the fs_watch flush hint).
  local _pyw_add _pyw_del _pyw_nest
  emit_array_additions "$kind" "$dom" "$prev_json" "$curr_json" > "$_py_add" 2>/dev/null &
  _pyw_add=$!
  _py_deletions_raw "$dom" "$prev_json" "$curr_json" > "$_py_del" 2>/dev/null &
  _pyw_del=$!
  emit_nested_dict_changes "$kind" "$dom" "$prev_json" "$curr_json" > "$_py_nest" 2>/dev/null &
  _pyw_nest=$!
  wait "$_pyw_add" "$_pyw_del" "$_pyw_nest" 2>/dev/null || true
  local _array_meta_raw _nested_raw
  _array_meta_raw=$(< "$_py_add")
  _nested_raw=$(< "$_py_nest")
  if [ -n "$_nested_raw" ]; then
    if [ -n "$_array_meta_raw" ]; then
      _array_meta_raw="${_array_meta_raw}"$'\n'"${_nested_raw}"
    else
      _array_meta_raw="$_nested_raw"
    fi
  fi
  if [ -n "$_array_meta_raw" ]; then
    _HAS_ARRAY_ADDITIONS=true
    _process_py_meta "$kind" "$dom" "$_array_meta_raw" "$pb_plist_path"
  fi
  emit_array_deletions "$kind" "$dom" "$prev_json" "$curr_json" "$_py_del" "$pb_plist_path"
  /bin/rm -f "$_py_add" "$_py_del" "$_py_nest" 2>/dev/null || true
}

# ---------------------------------------
# Contextual NOTEs
#
# A `# NOTE:` line that rides on a change: how to apply it, what reproduces it
# when defaults cannot, or why it is not reproducible. One function per topic.
# ---------------------------------------

# EnabledPreferenceRules lists the DISABLED categories: an empty list turns them
# all back ON. Said on each command, the line an admin copies.
# $2 = the quoted elements as emitted, empty for an empty list.
_note_spotlight_list() {
  local kind="$1" els="$2"
  if [ -z "$els" ]; then
    _log_kind "$kind" "Cmd: #       No category disabled after this line, every category is shown again (the target's list is replaced)"
  else
    _log_kind "$kind" "Cmd: #       Categories DISABLED by this line: ${els//\"/} (the whole list, the target's is replaced)"
  fi
}

# Per-burst dedup: a NOTE re-appears only after _NOTE_BURST_GAP seconds of quiet.
typeset -gA _NOTED_DOMAIN=()
typeset -g _NOTE_BURST_GAP=15   # seconds of quiet between bursts; tune to taste

# 0 = show the notice $1. The timestamp updates on EVERY call.
_note_should_show() {
  local _last=${_NOTED_DOMAIN[$1]:-0}
  _NOTED_DOMAIN[$1]=$EPOCHSECONDS
  (( EPOCHSECONDS - _last < _NOTE_BURST_GAP )) && return 1
  return 0
}

# Before `# dockutil …`: it does the SAME thing as the PlistBuddy lines. Pick one.
_note_dockutil_alt() {
  _note_should_show __dockutil_alt__ || return 0
  _log_kind "$1" "Cmd: # NOTE: dockutil (github.com/kcrawford/dockutil) is an ALTERNATIVE to the PlistBuddy line(s): run one or the other"
}

# Contextual notes for domains that need extra steps.
typeset -gA _BULK_N=() _BULK_SEEN_AT=()
_emit_contextual_note() {
  local dom="$1" array_base="$2" _note="" _bulk_only=false
  case "$dom" in
    com.apple.HIToolbox)
      case "$array_base" in
        AppleEnabledInputSources|AppleSelectedInputSources|AppleInputSourceHistory)
          _note="Keyboard layout changes require logout/login to take effect" ;;
      esac ;;
    com.apple.dock)
      case "$array_base" in
        persistent-apps|persistent-others)
          _note="Run 'killall Dock' to apply Dock changes" ;;
      esac ;;
    com.apple.systemuiserver)
      case "$array_base" in
        menuExtras)
          _note="Run 'killall SystemUIServer' to apply menu bar extra changes" ;;
      esac ;;
    com.apple.symbolichotkeys)
      _note="Keyboard shortcut changes require logout/login to take effect"
      case "$array_base" in
        AppleSymbolicHotKeys) _note="macOS rewrites a shortcut's parameters the first time it is enabled or disabled. If a binding you never touched shows up here, that is why" ;;
      esac ;;
    com.apple.finder)
      _note="Finder prefs apply on a new window or after 'killall Finder'; icon/list View Options (Cmd+J) need 'Use as Defaults' to be detectable"
      case "$array_base" in
        PreviewPaneSettings) _note="opening Finder's Preview pane options writes the full attribute list at once. If the whole list is here, most of it is not your change" ;;
        StandardViewSettings) _note="'Use as Defaults' on a Finder view writes the entire structure, every column. If all of them are here, most are not your change" ;;
      esac ;;
    # Fire on every emission, a lone toggle included: the sentence carries the condition.
    com.apple.WindowManager)
      _note="opening Desktop & Dock settings writes every default at once. Most of these are not changes you made"; _bulk_only=true ;;
    com.apple.universalaccess)
      _note="opening Accessibility settings writes every default at once. Most of these are not changes you made"; _bulk_only=true ;;
    # AirDrop: the write is INERT until `killall sharingd` (measured 26.6.2).
    com.apple.sharingd)
      _note="Run 'killall sharingd' to apply. The write alone is inert, Control Center keeps the previous value" ;;
    com.apple.prodisplaylibrary)
      _note="'defaults write' alone does not apply display presets. Alternative third-party tools exist" ;;
    # Spotlight: INERT until something re-reads the plist (reopening the pane does;
    # `killall Spotlight` did not).
    com.apple.Spotlight)
      case "$array_base" in
        EnabledPreferenceRules|DisabledUTTypes)
          _note="Spotlight re-reads this only when its Settings pane is reopened, or at the next login" ;;
      esac ;;
  esac
  case "$array_base" in
    com.apple.ColorSync.Devices)
      _note="Color profile changes require logout/login to take effect" ;;
    # Toolbar config: a customized toolbar is real, so annotated, not filtered.
    NSToolbar\ Configuration*|TB\ Item\ Identifiers*)
      _note="opening this window writes the full toolbar layout at once. If the whole layout is here, most of it is not a customization; 'TB Is Shown' is also rewritten by the app on window open/close" ;;
  esac
  [ -n "$_note" ] || return 0

  # "First open writes everything" is only true for a burst: count, then print
  # once past the threshold. A lone toggle gets no note.
  if [ "${_bulk_only:-false}" = true ]; then
    local _now=$EPOCHSECONDS
    (( _now - ${_BULK_SEEN_AT[$dom]:-0} > _NOTE_BURST_GAP )) && _BULK_N[$dom]=0
    _BULK_SEEN_AT[$dom]=$_now
    _BULK_N[$dom]=$(( ${_BULK_N[$dom]:-0} + 1 ))
    (( ${_BULK_N[$dom]} >= 4 )) || return 0
  fi

  _note_should_show "${dom}:${_note}" || return 0
  _log_note_wrapped "" "$_note"
}

# Service order: ServiceOrder holds local UUIDs, `-ordernetworkservices` takes
# NAMES. Returns 1 (generic NOTE) outside CurrentSet, for an unnamed or shared
# name. Names are escaped like values: they are pasted into a root shell.
_note_network_order() {
  local kind="$1" cmd="$2" path="${3:-}" set_uuid names
  [ -n "$PYTHON3_BIN" ] || return 1
  # The diffed file, else the canonical path (the ~ path of show_domain_diff is wrong).
  [ -r "$path" ] || path="/Library/Preferences/SystemConfiguration/preferences.plist"
  [ -r "$path" ] || return 1
  set_uuid="${cmd#*:Sets:}"; set_uuid="${set_uuid%%:*}"
  [ -n "$set_uuid" ] || return 1
  # networksetup accepts only the services it lists, which can be fewer than
  # ServiceOrder (27.0 VM): intersect with -listallnetworkservices, name the rest.
  local _known
  _known=$(/usr/sbin/networksetup -listallnetworkservices 2>/dev/null | /usr/bin/sed '1d; s/^\*//') || _known=""
  local _out
  _out=$(NS_KNOWN="$_known" "$PYTHON3_BIN" - "$path" "$set_uuid" 2>/dev/null <<'PY'
import os, plistlib, sys

def esc(s):
    for a, b in (('\\', '\\\\'), ('"', '\\"'), ('$', '\\$'), ('`', '\\`')):
        s = s.replace(a, b)
    return s

try:
    with open(sys.argv[1], 'rb') as fh:
        doc = plistlib.load(fh)
    want = sys.argv[2]
    if str(doc.get('CurrentSet', '')).rsplit('/', 1)[-1] != want:
        sys.exit(1)
    order = doc['Sets'][want]['Network']['Global']['IPv4']['ServiceOrder']
    services = doc.get('NetworkServices') or {}
    names = []
    for uuid in order:
        name = (services.get(uuid) or {}).get('UserDefinedName')
        if not name:
            sys.exit(1)
        names.append(str(name))
    if len(set(names)) != len(names) or not names:
        sys.exit(1)
    known = [k for k in os.environ.get('NS_KNOWN', '').split('\n') if k]
    dropped = [n for n in names if known and n not in known]
    names = [n for n in names if n not in dropped]
    if not names:
        sys.exit(1)
    print(' '.join('"%s"' % esc(n) for n in names))
    print(', '.join("'%s'" % n for n in dropped))
except Exception:
    sys.exit(1)
PY
) || return 1
  names="${_out%%$'\n'*}"; local _dropped="${_out#*$'\n'}"
  [ "$_dropped" = "$_out" ] && _dropped=""
  [ -n "$names" ] || return 1
  _note_should_show "__network_order__:$names" || return 0
  _log_kind "$kind" "Cmd: # NOTE: network service order changed (interface priority)."
  [ -n "$_dropped" ] && _log_kind "$kind" "Cmd: #       Left out, unknown to networksetup on this Mac: $_dropped"
  _log_kind "$kind" "Cmd: sudo /usr/sbin/networksetup -ordernetworkservices $names"
}

# Location switch: :CurrentSet is a local UUID path; `scselect <name>` applies it.
# Returns 1 when the set has no name or the name is shared.
_note_network_location() {
  local kind="$1" path="${2:-}" name
  [ -n "$PYTHON3_BIN" ] || return 1
  [ -r "$path" ] || path="/Library/Preferences/SystemConfiguration/preferences.plist"
  [ -r "$path" ] || return 1
  name=$("$PYTHON3_BIN" - "$path" 2>/dev/null <<'LOC'
import plistlib, sys
try:
    with open(sys.argv[1], 'rb') as handle:
        doc = plistlib.load(handle)
    sets = doc.get('Sets') or {}
    current = str(doc.get('CurrentSet', '')).rsplit('/', 1)[-1]
    name = (sets.get(current) or {}).get('UserDefinedName')
    if not name:
        sys.exit(1)
    if [(v or {}).get('UserDefinedName') for v in sets.values()].count(name) != 1:
        sys.exit(1)
    text = str(name)
    for a, b in (('\\', '\\\\'), ('"', '\\"'), ('$', '\\$'), ('`', '\\`')):
        text = text.replace(a, b)
    print(text)
except SystemExit:
    raise
except Exception:
    sys.exit(1)
LOC
) || return 1
  [ -n "$name" ] || return 1
  _note_should_show "__network_location__:$name" || return 0
  _log_kind "$kind" "Cmd: # NOTE: network location changed. It must already exist on the target Mac."
  _log_kind "$kind" "Cmd: sudo /usr/sbin/scselect \"$name\""
}

# DNS, search domains, proxies, TCP/IP method, service on/off: networksetup
# addresses the service BY NAME, so the UUID subtree still yields a command.
# Only verbs `networksetup -help` lists (26.6.2). Returns 1 for an unmapped key,
# an unnamed or shared service name, or an enabled proxy with no host.
_note_network_svc_setting() {
  local kind="$1" cmd="$2" path="${3:-}" uuid group out line
  [ -n "$PYTHON3_BIN" ] || return 1
  [ -r "$path" ] || path="/Library/Preferences/SystemConfiguration/preferences.plist"
  [ -r "$path" ] || return 1
  uuid="${cmd#*:NetworkServices:}"; uuid="${uuid%%:*}"
  [ -n "$uuid" ] || return 1
  # __INACTIVE__ first: the same key under DNS means something else.
  group=""
  case "${${cmd#*:NetworkServices:}#*:}" in
    __INACTIVE__*) group=enabled ;;
  esac
  if [ -z "$group" ]; then
    case "$cmd" in
      *":DNS:ServerAddresses"*)                                              group=dns ;;
      *":DNS:SearchDomains"*)                                                group=search ;;
      *":Proxies:HTTPEnable"*|*":Proxies:HTTPProxy"*|*":Proxies:HTTPPort"*|*":Proxies:HTTPUser"*)          group=web ;;
      *":Proxies:HTTPSEnable"*|*":Proxies:HTTPSProxy"*|*":Proxies:HTTPSPort"*|*":Proxies:HTTPSUser"*)      group=secure ;;
      *":Proxies:SOCKSEnable"*|*":Proxies:SOCKSProxy"*|*":Proxies:SOCKSPort"*|*":Proxies:SOCKSUser"*)      group=socks ;;
      *":Proxies:ProxyAutoConfig"*)                                          group=pac ;;
      *":Proxies:ProxyAutoDiscoveryEnable"*)                                 group=wpad ;;
      *":Proxies:ExceptionsList"*)                                           group=bypass ;;
      *":IPv4:"*)                                                            group=ipv4 ;;
      *":IPv6:"*)                                                            group=ipv6 ;;
      *) return 1 ;;
    esac
  fi
  out=$("$PYTHON3_BIN" - "$path" "$uuid" "$group" 2>/dev/null <<'NS'
import plistlib, sys

def esc(text):
    for a, b in (('\\', '\\\\'), ('"', '\\"'), ('$', '\\$'), ('`', '\\`')):
        text = text.replace(a, b)
    return text

def quoted(value):
    return '"%s"' % esc(str(value))

def port_of(value):
    digits = ''.join(c for c in str(value or '') if c.isdigit())
    return digits or '0'

try:
    path, uuid, group = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(path, 'rb') as handle:
        doc = plistlib.load(handle)
    services = doc.get('NetworkServices') or {}
  # Names need only be unique in the CURRENT location (stale services elsewhere).
    current = str(doc.get('CurrentSet', '')).rsplit('/', 1)[-1]
    try:
        order = doc['Sets'][current]['Network']['Global']['IPv4']['ServiceOrder']
    except Exception:
        sys.exit(1)
    if uuid not in order:
        sys.exit(1)
    service = services.get(uuid) or {}
    name = service.get('UserDefinedName')
    if not name:
        sys.exit(1)
    # A shared name would configure the wrong service.
    if [(services.get(u) or {}).get('UserDefinedName') for u in order].count(name) != 1:
        sys.exit(1)

    who = quoted(name)
    dns = service.get('DNS') or {}
    proxies = service.get('Proxies') or {}
    NS = 'sudo /usr/sbin/networksetup'
    lines = []

    def listing(values):
        return ' '.join(quoted(v) for v in values) if values else '"Empty"'

    if group == 'dns':
        lines.append('%s -setdnsservers %s %s' % (NS, who, listing(dns.get('ServerAddresses'))))
    elif group == 'search':
        lines.append('%s -setsearchdomains %s %s' % (NS, who, listing(dns.get('SearchDomains'))))
    elif group == 'bypass':
        lines.append('%s -setproxybypassdomains %s %s' % (NS, who, listing(proxies.get('ExceptionsList'))))
    elif group == 'enabled':
        state = 'off' if service.get('__INACTIVE__') else 'on'
        lines.append('%s -setnetworkserviceenabled %s %s' % (NS, who, state))
    elif group in ('ipv4', 'ipv6'):
        # Only methods with a one-to-one verb; any other shape gets the NOTE.
        block = service.get('IPv4' if group == 'ipv4' else 'IPv6') or {}
        method = str(block.get('ConfigMethod') or '')
        if group == 'ipv4':
            if method == 'DHCP':
                client = block.get('DHCPClientID')
                lines.append(('%s -setdhcp %s %s' % (NS, who, quoted(client))) if client
                             else ('%s -setdhcp %s' % (NS, who)))
            elif method == 'BOOTP':
                lines.append('%s -setbootp %s' % (NS, who))
            elif method == 'Manual':
                addresses = block.get('Addresses') or []
                masks = block.get('SubnetMasks') or []
                router = block.get('Router')
                if not addresses or not masks or not router:
                    sys.exit(1)
                lines.append('%s -setmanual %s %s %s %s' % (NS, who, quoted(addresses[0]),
                                                            quoted(masks[0]), quoted(router)))
            elif method in ('Off', ''):
                lines.append('%s -setv4off %s' % (NS, who))
            else:
                sys.exit(1)
        else:
            if method == 'Automatic':
                lines.append('%s -setv6automatic %s' % (NS, who))
            elif method == 'LinkLocal':
                lines.append('%s -setv6LinkLocal %s' % (NS, who))
            elif method == 'Manual':
                addresses = block.get('Addresses') or []
                prefixes = block.get('PrefixLength') or []
                router = block.get('Router')
                if not addresses or not prefixes or not router:
                    sys.exit(1)
                lines.append('%s -setv6manual %s %s %s %s' % (NS, who, quoted(addresses[0]),
                                                              quoted(prefixes[0]), quoted(router)))
            elif method in ('Off', ''):
                lines.append('%s -setv6off %s' % (NS, who))
            else:
                sys.exit(1)
    elif group == 'wpad':
        state = 'on' if proxies.get('ProxyAutoDiscoveryEnable') else 'off'
        lines.append('%s -setproxyautodiscovery %s %s' % (NS, who, state))
    elif group == 'pac':
        url = proxies.get('ProxyAutoConfigURLString')
        if proxies.get('ProxyAutoConfigEnable') and url:
            lines.append('%s -setautoproxyurl %s %s' % (NS, who, quoted(url)))
        else:
            lines.append('%s -setautoproxystate %s off' % (NS, who))
    elif group in ('web', 'secure', 'socks'):
        prefix, verb = {'web': ('HTTP', '-setwebproxy'),
                        'secure': ('HTTPS', '-setsecurewebproxy'),
                        'socks': ('SOCKS', '-setsocksfirewallproxy')}[group]
        if proxies.get(prefix + 'Enable'):
            host = proxies.get(prefix + 'Proxy')
            if not host:
                sys.exit(1)
            lines.append('%s %s %s %s %s' % (NS, verb, who, quoted(host),
                                             port_of(proxies.get(prefix + 'Port'))))
            user = proxies.get(prefix + 'User')
            if user:
                lines.append('#       authenticated proxy, user %s. The password is in the keychain,'
                             % quoted(user))
                lines.append('#       not in this file. Append: on <user> <password>')
        else:
            lines.append('%s %sstate %s off' % (NS, verb, who))
    else:
        sys.exit(1)

    for line in lines:
        print(line)
except SystemExit:
    raise
except Exception:
    sys.exit(1)
NS
) || return 1
  [ -n "$out" ] || return 1
  _note_should_show "__network_svc__:$uuid:$group:$out" || return 0
  printf '%s\n' "$out" | while IFS= read -r line; do
    [ -n "$line" ] && _log_kind "$kind" "Cmd: $line"
  done
  return 0
}

# NOTE for the rest of the network tree: service UUIDs are minted on THIS Mac
# (and re-minted by VPN agents on wake). Names the real reproducers.
_note_network_service() {
  local kind="$1" dom="$2" cmd="$3" path="${4:-}"
  [ "$dom" = preferences ] || return 0
  case "$cmd" in
    # An order change is reproducible: emit it; NOTE only if it cannot be built.
    *":CurrentSet"*)
      if _note_network_location "$kind" "$path"; then return 0; fi
      ;;
    *":Network:Global:IPv4:ServiceOrder"*)
      if _note_network_order "$kind" "$cmd" "$path"; then return 0; fi
      ;;
    # Same rule for DNS, proxies, TCP/IP method and service on/off.
    *":NetworkServices:"*":DNS:"*|*":NetworkServices:"*":Proxies:"*|\
    *":NetworkServices:"*":IPv4:"*|*":NetworkServices:"*":IPv6:"*|\
    *":NetworkServices:"*":__INACTIVE__"*)
      if _note_network_svc_setting "$kind" "$cmd" "$path"; then return 0; fi
      ;;
    *":NetworkServices:"*|*":Sets:"*":Network:"*) ;;
    *) return 0 ;;
  esac
  _note_should_show __network_service__ || return 0
  _log_note_wrapped "$kind" "network service configuration changed (VPN / proxies / DNS / service order). Not emitted: configd owns this file, and each service is keyed by a UUID minted on this Mac. A VPN client recreating its service mints a new one. Reproduce it with networksetup where it has a verb for the setting, or with a configuration profile for a VPN. A 'com.apple.payload' subtree means the service is already profile-managed: deploy the profile, not this file."
}

# Menu bar positions are pixel offsets, filtered: a Cmd+drag reorder gets a NOTE.
# Value changes only (add/remove = show/hide, emitted). A display change moves them too.
_note_menubar_positions() {
  local kind="$1" prev="$2" curr="$3" dom="${4:-}" _k _pat
  [ -s "$prev" ] && [ -s "$curr" ] || return 0
  # Per-app `NSStatusItem Preferred Position <Item>`; on 27 also in MenuBarAgent.
  _pat='"NSStatusItem Preferred Position'
  [ "$dom" = "com.apple.MenuBarAgent" ] && _pat='"(module|status):'
  # `|| true` INSIDE the $(): diff exits 1 on a difference, pipefail would wipe the key.
  _k=$(/usr/bin/diff "$prev" "$curr" 2>/dev/null \
        | /usr/bin/grep -E "^[<>].*$_pat" \
        | /usr/bin/sed -E 's/^[<>][[:space:]]*//; s/[[:space:]]*=.*//' \
        | /usr/bin/sort | /usr/bin/uniq -d | /usr/bin/head -1 || true)
  [ -n "$_k" ] || return 0
  _note_should_show __menubar_pos__ || return 0
  _log_note_wrapped "$kind" "menu bar layout changed. Item positions are pixel offsets, not portable, so not emitted. A reorder OR a display connect/disconnect triggers this."
}

# Pure Dock reorder: positional churn is filtered, so a NOTE instead.
_note_dock_reorder() {
  local kind="$1" pj="$2" cj="$3" _r
  [ -n "$PYTHON3_BIN" ] || return 0
  [ -s "$pj" ] && [ -s "$cj" ] || return 0
  _r=$("$PYTHON3_BIN" - "$pj" "$cj" 2>/dev/null <<'PY'
import json, sys
def ids(doc, key):
    out = []
    for el in (doc.get(key) or []):
        td = (el or {}).get("tile-data") or {}
        i = td.get("bundle-identifier")
        if not i:
            fd = td.get("file-data") or {}
            i = fd.get("_CFURLString") or td.get("file-label")
        if i:
            out.append(i)
    return out
try:
    p = json.load(open(sys.argv[1])); c = json.load(open(sys.argv[2]))
except Exception:
    sys.exit(0)
for key in ("persistent-apps", "persistent-others"):
    po, co = ids(p, key), ids(c, key)
    if po and co and sorted(po) == sorted(co) and po != co:
        print("1"); break
PY
)
  if [ -n "$_r" ] && _note_should_show __dock_reorder__; then
    _log_note_wrapped "$kind" "Dock icons reordered. No command emitted; reproduce the order for deployment with dockutil (github.com/kcrawford/dockutil), for example: $(_mdm_wrap "dockutil --move <app> --position <N>")"
  fi
}

# Time Machine: AutoBackup → tmutil enable/disable, SkipPaths → add/removeexclusion
# (raw writes filtered: backupd owns the file). Only moved paths become commands.
_tm_skippaths() {
  [ -s "$1" ] || return 0
  # `plutil -p` escapes nothing: the value runs to the line end minus the quote.
  /usr/bin/awk '
    /"SkipPaths" => \[/ { inside = 1; next }
    inside && /^[[:space:]]*\]/ { inside = 0 }
    inside && match($0, /=> "/) {
      line = substr($0, RSTART + 4)
      sub(/"[[:space:]]*$/, "", line)
      print line
    }' "$1" 2>/dev/null
}

# AutoBackupInterval follows AutoBackup (measured 27.0), so it is skipped then.
_tm_autobackup_moved() {
  local _p _c
  _p=$(/usr/bin/sed -n 's/^[[:space:]]*"AutoBackup" => \(.*\)$/\1/p' "$1" 2>/dev/null | /usr/bin/head -1) || _p=""
  _c=$(/usr/bin/sed -n 's/^[[:space:]]*"AutoBackup" => \(.*\)$/\1/p' "$2" 2>/dev/null | /usr/bin/head -1) || _c=""
  [ "$_p" != "$_c" ]
}

_note_timemachine() {
  local kind="$1" prev="$2" curr="$3" _p _c _path
  [ -s "$prev" ] && [ -s "$curr" ] || return 0

  _p=$(/usr/bin/sed -n 's/^[[:space:]]*"AutoBackup" => \(.*\)$/\1/p' "$prev" 2>/dev/null | /usr/bin/head -1) || _p=""
  _c=$(/usr/bin/sed -n 's/^[[:space:]]*"AutoBackup" => \(.*\)$/\1/p' "$curr" 2>/dev/null | /usr/bin/head -1) || _c=""
  if [ -n "$_c" ] && [ "$_p" != "$_c" ] && _note_should_show "__tm_auto__:$_c"; then
    case "$_c" in
      1|true|TRUE) _log_kind "$kind" "Cmd: sudo /usr/bin/tmutil enable" ;;
      *)           _log_kind "$kind" "Cmd: sudo /usr/bin/tmutil disable" ;;
    esac
  fi

  local _pf="$CACHE_DIR/tm.skip.prev" _cf="$CACHE_DIR/tm.skip.curr"
  _tm_skippaths "$prev" | /usr/bin/sort -u > "$_pf" 2>/dev/null || : > "$_pf"
  _tm_skippaths "$curr" | /usr/bin/sort -u > "$_cf" 2>/dev/null || : > "$_cf"
  if ! /usr/bin/cmp -s "$_pf" "$_cf" 2>/dev/null; then
    if _note_should_show "__tm_skip__"; then
      while IFS= read -r _path; do
        [ -n "$_path" ] && _log_kind "$kind" "Cmd: sudo /usr/bin/tmutil addexclusion -p \"$(_escape_dq "$_path")\""
      done < <(/usr/bin/comm -13 "$_pf" "$_cf" 2>/dev/null)
      while IFS= read -r _path; do
        [ -n "$_path" ] && _log_kind "$kind" "Cmd: sudo /usr/bin/tmutil removeexclusion -p \"$(_escape_dq "$_path")\""
      done < <(/usr/bin/comm -23 "$_pf" "$_cf" 2>/dev/null)
    fi
  fi
  /bin/rm -f "$_pf" "$_cf" 2>/dev/null || true
}

# Media Sharing: every key filtered, so the domain gets a NOTE instead of silence.
_note_mediasharing() {
  local kind="$1"
  _note_should_show __mediasharing__ || return 0
  _log_note_wrapped "$kind" "Media Sharing changed, not reproducible via defaults. These keys mirror state the daemon writes and never reads back. Measured: the write survives a restart of mediasharingd, and the pane never follows. Set it in System Settings > General > Sharing."
}

# Print presets: applies after logout/login; the DOMAIN carries the CUPS queue
# name, so it matches only where the queue has that name; the macOS presets
# are localised, so only a preset the admin named travels.
_note_print_preset() {
  local kind="$1" dom="$2"
  case "$dom" in com.apple.print.custompresets*) ;; *) return 0 ;; esac
  _note_should_show "__print_preset__:$dom" || return 0
  local _pp="print preset changed. It takes effect after a logout/login."
  case "$dom" in
    *.forprinter.*) _pp="$_pp This domain names the print queue ('${dom##*.forprinter.}'), which is whatever the printer was added as; the path matches only where the queue has that name." ;;
  esac
  _log_note_wrapped "$kind" "$_pp The top-level key is the preset's NAME. macOS's own entries are localised ('Réglages par défaut' here). Their path finds nothing on a Mac in another language. A preset you named yourself carries the name you chose, and travels."
}

# Wi-Fi power: airportd owns the file; `networksetup -setairportpower <device>`.
_note_wifi_power() {
  local kind="$1" prev="$2" curr="$3" _p _c _dev
  [ -s "$prev" ] && [ -s "$curr" ] || return 0
  _p=$(/usr/bin/sed -n 's/^[[:space:]]*"PowerEnabled" => \(.*\)$/\1/p' "$prev" 2>/dev/null | /usr/bin/head -1) || _p=""
  _c=$(/usr/bin/sed -n 's/^[[:space:]]*"PowerEnabled" => \(.*\)$/\1/p' "$curr" 2>/dev/null | /usr/bin/head -1) || _c=""
  [ -n "$_c" ] && [ "$_p" != "$_c" ] || return 0
  _note_should_show "__wifi_power__:$_c" || return 0
  _dev=$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null \
           | /usr/bin/awk '/^Hardware Port: Wi-Fi$/{getline; print $2; exit}') || _dev=""
  [ -n "$_dev" ] || _dev="en0"
  case "$_c" in
    1|true|TRUE) _log_kind "$kind" "Cmd: sudo /usr/sbin/networksetup -setairportpower $_dev on" ;;
    *)           _log_kind "$kind" "Cmd: sudo /usr/sbin/networksetup -setairportpower $_dev off" ;;
  esac
  _log_kind "$kind" "Cmd: #       ($_dev is this Mac's Wi-Fi device; on the target: networksetup -listallhardwareports)"
}

# Beta enrollment (27.0): leaving deletes CatalogURL and NSShowFeedbackMenu; no
# command enrolls (seedutil is unsupported). A NOTE naming the program.
_note_seed_enrollment() {
  local kind="$1" prev="$2" curr="$3" _p _c _prog
  [ -s "$prev" ] && [ -s "$curr" ] || return 0
  _p=$(/usr/bin/sed -n 's/^[[:space:]]*"CatalogURL" => "\(.*\)"$/\1/p' "$prev" 2>/dev/null | /usr/bin/head -1) || _p=""
  _c=$(/usr/bin/sed -n 's/^[[:space:]]*"CatalogURL" => "\(.*\)"$/\1/p' "$curr" 2>/dev/null | /usr/bin/head -1) || _c=""
  [ "$_p" != "$_c" ] || return 0
  _note_should_show "__seed__:${_c:+on}" || return 0
  if [ -z "$_c" ]; then
    _log_note_wrapped "$kind" "left the beta program. Not a command. Beta enrollment is managed in System Settings > General > Software Update. seedutil no longer enrolls, its own binary says so"
  else
    _prog=$(/usr/bin/plutil -p /System/Library/PrivateFrameworks/Seeding.framework/Versions/A/Resources/SeedCatalogs.plist 2>/dev/null \
              | /usr/bin/grep -F "\"$_c\"" | /usr/bin/sed -n 's/^[[:space:]]*"\([^"]*\)" =>.*/\1/p' | /usr/bin/head -1) || _prog=""
    _log_note_wrapped "$kind" "joined the beta program${_prog:+ '$_prog'}. Not a command. Beta enrollment is managed in System Settings > General > Software Update. seedutil no longer enrolls, its own binary says so"
  fi
}

_note_charge_limit() {
  local kind="$1"
  _note_should_show __charge_limit__ || return 0
  _log_note_wrapped "$kind" "battery charge limit changed. Managed by the power daemon (SMC), not reproducible via defaults; set it in System Settings > Battery"
}

# The desktoppr lastPath is replaced by the desktoppr command itself. In ALL mode
# with python3 wallpaper_watch already emits it, so only elsewhere here.
_desktoppr_lastpath() {
  [ -s "$1" ] || return 0
  # No pipe: `$(cmd | head)` dies under set -e + pipefail.
  /usr/bin/sed -n 's/^[[:space:]]*"lastPath" => "\(.*\)"$/\1/p' "$1" 2>/dev/null
}

# The desktoppr header, shared by _note_desktoppr and wallpaper_watch.
_note_desktoppr_head() { _log_kind "${1:-}" "Cmd: # NOTE: needs desktoppr (github.com/scriptingosx/desktoppr)"; }

_note_desktoppr() {
  local kind="$1" _p _c
  _p="$(_desktoppr_lastpath "$2")" ; _c="$(_desktoppr_lastpath "$3")"
  [ -n "$_c" ] && [ "$_p" != "$_c" ] || return 0
  _note_should_show "__desktoppr__:$_c" || return 0
  # Every key is filtered: claim the slot of the new-domain NOTE.
  _NOTED_DOMAIN[__newdom__:com.scriptingosx.desktoppr]=$EPOCHSECONDS
  [ "${ALL_MODE:-false}" = "true" ] && [ -n "$PYTHON3_BIN" ] && return 0
  _note_desktoppr_head "$kind"
  # Wallpaper is per-user: --mdm wraps it in runAsUser.
  local _dp="desktoppr \"$(_escape_dq "$_c")\""
  _log_kind "$kind" "Cmd: $(_mdm_wrap "$_dp")"
}

# A domain whose only plist sits in a GROUP container is not addressable by name
# (23 of 23 export zero keys): explained, never watched. ~/Library/Containers is
# reachable by name and keeps its branch.
_note_group_container_domain() {
  local dom="$1"
  local -a _gc
  _gc=( "$TARGET_HOME/Library/Group Containers"/*/Library/Preferences/"${dom}.plist"(N.) )
  (( ${#_gc[@]} )) || return 1
  log_line "Cmd: # NOTE: '$dom' has no preference file of its own. It lives in a group container:"
  log_line "Cmd: #       ${_gc[1]}"
  log_line "Cmd: #       'defaults' cannot address a group container by domain name (measured: the export comes back empty);"
  log_line "Cmd: #       no command can be emitted for it and none will be."
  return 0
}

# ---------------------------------------
# Diff Drivers
#
# show_plist_diff: a plist FILE changed on disk (poll_watch / fs_watch).
# show_domain_diff: a DOMAIN changed as cfprefsd sees it (`defaults export`).
# ---------------------------------------

show_plist_diff() {
  local kind="$1" path="$2" mode="${3:-normal}" silent="false"
  [ "$mode" = "silent" ] && silent="true"
  [ -f "$path" ] || return 0

  local _dom
  _dom="$(domain_from_plist_path "$path")"
  if is_excluded_domain "$_dom"; then
    _dbg_filtered "$_dom (excluded-domain)"
    return 0
  fi

  # System prefs: commands target the /Library file, not the ~/Library copy.
  typeset -g _EMIT_SYS=false _EMIT_SYS_DOM=""
  # The REAL path: system plists can sit in subdirectories.
  [[ "$path" == /Library/Preferences/* && "$path" != */ByHost/* ]] && { _EMIT_SYS=true; _EMIT_SYS_DOM="${path%.plist}"; }

  init_cache
  local key prev curr prev_json curr_json
  key=$(hash_path "$path")
  prev="$CACHE_DIR/${key}.prev"
  curr="$CACHE_DIR/${key}.curr"
  prev_json="$CACHE_DIR/${key}.prev.json"
  curr_json="$CACHE_DIR/${key}.curr.json"

  # fs_watch/poll_watch mutex per plist (3s). Locks older than 10s are reclaimed:
  # an orphaned lock would silence the plist for the run.
  local lockdir="$CACHE_DIR/${key}.lock"
  if [ -d "$lockdir" ]; then
    local _lock_mtime=""
    if [ "$HAVE_ZSH_STAT" = "true" ]; then
      typeset -A _lockstat
      zstat -H _lockstat "$lockdir" 2>/dev/null && _lock_mtime="${_lockstat[mtime]:-}"
    else
      _lock_mtime=$(/usr/bin/stat -f %m "$lockdir" 2>/dev/null || printf '')
    fi
    if [ -n "$_lock_mtime" ] && (( EPOCHSECONDS - _lock_mtime > 10 )); then
      /bin/rmdir "$lockdir" 2>/dev/null || true
    fi
  fi
  local _wait_attempts=0
  while ! /bin/mkdir "$lockdir" 2>/dev/null; do
    _wait_attempts=$((_wait_attempts + 1))
    if [ "$_wait_attempts" -gt 30 ]; then
      # The other watcher is emitting this diff: skip, not an error.
      return 0
    fi
    /bin/sleep 0.1
  done

  if [ "$silent" != "true" ]; then
    # Wait on these two pids: a bare `wait` also waits for the fs_watch flush hint
    # and, on a hung cfprefsd, froze the diff while holding the lock.
    local _dp_pid _dpj_pid
    dump_plist "$path" "$curr" &
    _dp_pid=$!
    dump_plist_json "$path" "$curr_json" &
    _dpj_pid=$!
    wait "$_dp_pid" "$_dpj_pid" 2>/dev/null || true
  else
    dump_plist "$path" "$curr"
  fi

  # cfprefsd writes asynchronously: retry with growing delays, hinting a sync.
  if [ -s "$prev" ] && [ -s "$curr" ] && /usr/bin/cmp -s "$prev" "$curr" 2>/dev/null; then
    local _retry_delay _retry_changed=false _last_mtime _cur_mtime
    # ByHost needs its own -currentHost flush.
    local _flush_hostflag=""
    [[ "$path" == *"/ByHost/"* ]] && _flush_hostflag="-currentHost"
    # zstat, not a `stat` fork; same one-second granularity.
    local -A _mst
    _mtime_of() {
      if [ "$HAVE_ZSH_STAT" = "true" ]; then
        zstat -H _mst "$1" 2>/dev/null && printf '%s' "${_mst[mtime]}" || printf ''
      else
        /usr/bin/stat -f %m "$1" 2>/dev/null || printf ''
      fi
    }
    _last_mtime=$(_mtime_of "$path")
    for _retry_delay in 0.1 0.2 0.3 0.5 0.7; do
      /bin/sleep "$_retry_delay"
      "${RUN_AS_USER[@]}" /usr/bin/defaults ${_flush_hostflag:+$_flush_hostflag} read "$_dom" >/dev/null 2>&1 || true
      _cur_mtime=$(_mtime_of "$path")
      # Last retry: always dump (mtime cannot see a same-second write).
      if [ "$_retry_delay" != "0.7" ] && [ -n "$_cur_mtime" ] && [ "$_cur_mtime" = "$_last_mtime" ]; then
        continue
      fi
      _last_mtime="$_cur_mtime"
      dump_plist "$path" "$curr"
      if ! /usr/bin/cmp -s "$prev" "$curr" 2>/dev/null; then
        _retry_changed=true
        break
      fi
    done
    if [ "$_retry_changed" = "true" ] && [ "$silent" != "true" ]; then
      dump_plist_json "$path" "$curr_json"
    fi
    if [ -s "$prev" ] && [ -s "$curr" ] && /usr/bin/cmp -s "$prev" "$curr" 2>/dev/null; then
      /bin/rm -f "$curr" "$curr_json" 2>/dev/null || true
      /bin/rmdir "$lockdir" 2>/dev/null || true
      return 0
    fi
  fi

  # An EMPTY dump is a non-atomic rewrite, not "every key deleted": skip.
  if [ ! -s "$curr" ]; then
    /bin/rm -f "$curr" "$curr_json" 2>/dev/null || true
    /bin/rmdir "$lockdir" 2>/dev/null || true
    return 0
  fi

  typeset -gA _SKIP_KEYS _ARRAY_REWRITTEN
  _SKIP_KEYS=(); _ARRAY_REWRITTEN=()
  typeset -g _HAS_ARRAY_ADDITIONS=false
  # The print-preset NOTE below needs this diff to add a command line.
  local _cmd0=${_CMD_LINES:-0}

  if [ "$silent" != "true" ] && [ -n "$PYTHON3_BIN" ] && [ -s "$prev_json" ] && [ -s "$curr_json" ]; then
    _run_py_diff_workers "$kind" "$_dom" "$prev_json" "$curr_json" "$path" "$key"
  fi

  if [ "$silent" != "true" ]; then
    local _base="$(/usr/bin/basename "$path")"
    local _emit_dom="${_base%.plist}" _emit_hostflag=""
    if [[ "$path" == *"/ByHost/"* ]]; then
      _emit_hostflag="-currentHost"
      _emit_dom="$(printf '%s' "$_emit_dom" | /usr/bin/sed -E 's/\.[0-9A-Fa-f-]{8,}$//')"
    fi
    if [ "$_dom" = "com.scriptingosx.desktoppr" ]; then
      _note_desktoppr "$kind" "$prev" "$curr"
    fi
    # Network location: CurrentSet is filtered; say what reproduces it.
    if [ "$_dom" = preferences ] && [[ "$path" == */SystemConfiguration/preferences.plist ]] \
       && [ "$(/usr/bin/sed -n 's/^[[:space:]]*"CurrentSet" => //p' "$prev" 2>/dev/null)" != "$(/usr/bin/sed -n 's/^[[:space:]]*"CurrentSet" => //p' "$curr" 2>/dev/null)" ]; then
      _note_network_location "$kind" "$path" || _log_kind "$kind" "Cmd: # NOTE: network location changed. Its name could not be resolved, so no scselect command is emitted."
    fi
    if [ "$_dom" = "com.apple.TimeMachine" ] && _tm_autobackup_moved "$prev" "$curr"; then
      _SKIP_KEYS[AutoBackupInterval]=1
      _dbg_filtered "$_dom AutoBackupInterval (follows AutoBackup, which tmutil handles)"
    fi
    _process_diff_lines "$kind" "$_emit_dom" "$_emit_hostflag" "$prev" "$curr" "$path" "$path" "$path"
    [ "$_dom" = "com.apple.dock" ] && _note_dock_reorder "$kind" "$prev_json" "$curr_json"
    _note_menubar_positions "$kind" "$prev" "$curr" "$_dom"
    [ "$_dom" = "com.apple.batteryui.charging.mac" ] && _note_charge_limit "$kind"
    [ "$_dom" = "com.apple.airport.preferences" ] && _note_wifi_power "$kind" "$prev" "$curr"
    [ "$_dom" = "com.apple.TimeMachine" ] && _note_timemachine "$kind" "$prev" "$curr"
    [ "$_dom" = "com.apple.SoftwareUpdate" ] && _note_seed_enrollment "$kind" "$prev" "$curr"
    [ "$_dom" = "com.apple.amp.mediasharingd" ] && _note_mediasharing "$kind"
    # Only above a command: an emptied preset plist emits nothing.
    [ "${_CMD_LINES:-0}" -gt "$_cmd0" ] && _note_print_preset "$kind" "$_dom"
  fi

  /bin/mv -f "$curr" "$prev" 2>/dev/null || /bin/cp -f "$curr" "$prev" 2>/dev/null || :
  [ -f "$curr_json" ] && { /bin/mv -f "$curr_json" "$prev_json" 2>/dev/null || /bin/cp -f "$curr_json" "$prev_json" 2>/dev/null || : ; }
  /bin/rmdir "$lockdir" 2>/dev/null || true
}

show_domain_diff() {
  local dom="$1"
  local skip_arrays="${2:-false}"

  # Domain mode is user-domain: clear a system flag left by show_plist_diff.
  typeset -g _EMIT_SYS=false _EMIT_SYS_DOM=""

  if [ "${ALL_MODE:-false}" = "true" ] && is_excluded_domain "$dom"; then
    return 0
  fi

  init_cache
  local key prev curr tmpplist prev_json curr_json
  key=$(hash_path "domain:${CONSOLE_USER}:${dom}")
  prev="$CACHE_DIR/${key}.prev"
  curr="$CACHE_DIR/${key}.curr"
  tmpplist="$CACHE_DIR/${key}.plist"

  "${RUN_AS_USER[@]}" /usr/bin/defaults export "$dom" - > "$tmpplist" 2>/dev/null || :
  # Empty export = absent domain or busy cfprefsd: keep the last good state.
  [ -s "$tmpplist" ] || return 0
  /usr/bin/plutil -p "$tmpplist" > "$curr" 2>/dev/null || /bin/cat "$tmpplist" > "$curr" 2>/dev/null || :
  curr_json="$CACHE_DIR/${key}.curr.json"
  # The JSON feeds only the Python workers, off when skip_arrays is true.
  [ "$skip_arrays" != "true" ] && dump_plist_json "$tmpplist" "$curr_json"

  prev_json="$CACHE_DIR/${key}.prev.json"
  typeset -gA _SKIP_KEYS _ARRAY_REWRITTEN
  _SKIP_KEYS=(); _ARRAY_REWRITTEN=()
  typeset -g _HAS_ARRAY_ADDITIONS=false
  local _cmd0=${_CMD_LINES:-0}

  if [ "$skip_arrays" != "true" ] && [ -n "$PYTHON3_BIN" ] && [ -s "$prev_json" ] && [ -s "$curr_json" ]; then
    _run_py_diff_workers DOMAIN "$dom" "$prev_json" "$curr_json" "$(get_plist_path "$dom" 2>/dev/null)" "$key"
  fi

  if [ "$dom" = "com.scriptingosx.desktoppr" ]; then
    _note_desktoppr DOMAIN "$prev" "$curr"
  fi
  _process_diff_lines DOMAIN "$dom" "" "$prev" "$curr" "$tmpplist" "$dom"
  [ "${_CMD_LINES:-0}" -gt "$_cmd0" ] && _note_print_preset DOMAIN "$dom"

  /bin/mv -f "$curr" "$prev" 2>/dev/null || /bin/cp -f "$curr" "$prev" 2>/dev/null || :
  [ "$skip_arrays" != "true" ] && { /bin/mv -f "$curr_json" "$prev_json" 2>/dev/null || /bin/cp -f "$curr_json" "$prev_json" 2>/dev/null || : ; }
  return 0
}

# ---------------------------------------
# Console & Process Tree
# ---------------------------------------

is_console_running() {
  /usr/bin/pgrep -x "Console" >/dev/null 2>/dev/null
}

launch_console() {
  local open_cmd=(/usr/bin/open)
  if command -v /bin/launchctl >/dev/null 2>&1 && id -u "$CONSOLE_USER" >/dev/null 2>&1; then
    open_cmd=(/bin/launchctl asuser "$(id -u "$CONSOLE_USER")" /usr/bin/open)
  fi
  if [ -f "$LOGFILE" ]; then
    "${open_cmd[@]}" -b com.apple.Console "$LOGFILE" >/dev/null 2>&1 || \
    "${open_cmd[@]}" -a Console "$LOGFILE" >/dev/null 2>&1 || \
    "${open_cmd[@]}" -a Console >/dev/null 2>&1 || true
  else
    "${open_cmd[@]}" -a Console >/dev/null 2>&1 || true
  fi
}

# --mdm: the deploy helpers once, as Cmd: lines a root Jamf policy can run
# (runAsUser for user domains, $loggedInUser / $UUID for PlistBuddy paths).
_emit_mdm_resolver_header() {
  [ "$MDM_OUTPUT" = "true" ] || return 0
  log_line "Cmd: # NOTE: put these 4 lines at the top of your deployment script"
  log_line "Cmd: loggedInUser=\$(/usr/bin/stat -f%Su /dev/console)"
  log_line "Cmd: uid=\$(/usr/bin/id -u \"\$loggedInUser\")"
  log_line "Cmd: UUID=\$(/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice | /usr/bin/awk -F'\"' '/IOPlatformUUID/{print \$4}')"
  log_line "Cmd: runAsUser() { /bin/launchctl asuser \"\$uid\" /usr/bin/sudo -u \"\$loggedInUser\" \"\$@\"; }"
}

# Watcher PIDs: `_spawn <fn>` records each so the teardown gets them all.
typeset -ga _WATCH_PIDS=()
_spawn() { "$@" & _WATCH_PIDS+=($!); }

# Kill a process tree, leaves first. Shared by the watcher subshell and MAIN.
_kill_tree() {
  local _root=$1 _kid
  [ -n "$_root" ] || return 0
  # `|| true`: pgrep exits 1 at every leaf, which would trip set -e mid-teardown.
  for _kid in $(pgrep -P "$_root" 2>/dev/null || true); do _kill_tree "$_kid"; done
  kill -TERM "$_root" 2>/dev/null || true
}

_shutdown_watcher() {
  # Idempotent: the signal trap, then the EXIT trap, both call it.
  [ "${_SHUTDOWN_DONE:-false}" = "true" ] && return 0
  typeset -g _SHUTDOWN_DONE=true
  _kill_tree "${WATCH_PID:-}"
  wait ${WATCH_PID:-} 2>/dev/null || true
  # Snapshot workers may still be writing: retry the rm until it wins (~1s).
  local _i
  for _i in 1 2 3 4 5 6; do
    /bin/rm -rf "$PREFWATCH_TMPDIR" 2>/dev/null || true
    [ -d "$PREFWATCH_TMPDIR" ] || break
    sleep 0.3
  done
}

# SIGKILL runs no trap: this watchdog sees the PPID of the watcher root turn 1 and
# signals it, so its TERM trap tears down. Not `kill -0` (pids are recycled).
_orphan_watchdog() {
  local _root="$1" _pp
  [ -n "$_root" ] || return 0
  while :; do
    /bin/sleep 5 || true
    _pp=$(/bin/ps -o ppid= -p "$_root" 2>/dev/null | /usr/bin/tr -d ' ') || _pp=""
    # Root already gone: nothing to signal.
    [ -n "$_pp" ] || return 0
    [ "$_pp" = 1 ] || continue
    /bin/kill -TERM "$_root" 2>/dev/null || true
    return 0
  done
}

_watchers_teardown() {
  # Idempotent: the signal trap, then the EXIT trap.
  [ "${_TEARDOWN_DONE:-false}" = "true" ] && return 0
  typeset -g _TEARDOWN_DONE=true
  # Kill the SUBTREE of each watcher, never `wait`: pipeline members survive a signal
  # to their shell, and a `wait` hung a root teardown.
  local _p
  for _p in ${_WATCH_PIDS[@]}; do _kill_tree "$_p"; done
  # Bounded wait; stop when NO pid answers (`kill -0 a b` fails on the first gone).
  local _i _q _alive
  for _i in 1 2 3 4 5 6; do
    /bin/sleep 0.25
    _alive=0
    for _q in ${_WATCH_PIDS[@]}; do
      if kill -0 "$_q" 2>/dev/null; then _alive=1; break; fi
    done
    [ "$_alive" -eq 0 ] && break
  done
  /bin/rm -rf "$PREFWATCH_TMPDIR" 2>/dev/null || true
}

# ---------------------------------------
# Watcher Framework
#
# _WATCHERS is the registry: name | guard | function | listed in the startup summary.
# _snapshot_watch runs a read function every N seconds and calls an on-change
# function when its output differs. Most watchers below are built on it.
# ---------------------------------------

# Watcher registry "name|guard|fn|summary", the one source for the spawn loop
# and the "Watchers active" line. guard is evaluated at launch; summary "y" lists it.
typeset -ga _WATCHERS=(
  'fs|[ "$(id -u)" -eq 0 ] && [ "$FS_USAGE" = true ]|fs_watch|'
  'poll|true|poll_watch|'
  'cups|true|cups_watch|'
  'pmset|true|pmset_watch|'
  'cups_sharing|[ -d /etc/cups ]|cups_sharing_watch|y'
  'ard_privs|[ -x /usr/bin/dscl ]|ard_privs_watch|y'
  'sharepoints|[ -x /usr/bin/dscl ] && [ -n "$PYTHON3_BIN" ]|sharepoints_watch|y'
  'bluetooth|[ -x /usr/sbin/system_profiler ]|bluetooth_watch|y'
  'useracct|[ -x /usr/bin/dscl ]|useracct_watch|y'
  'hostname|[ -x /usr/sbin/scutil ]|hostname_watch|y'
  'default_apps|[ -n "$PYTHON3_BIN" ]|default_apps_watch|y'
  'wallpaper|[ -n "$PYTHON3_BIN" ]|wallpaper_watch|y'
  'tcc|[ -x /usr/bin/sqlite3 ]|tcc_watch|y'
  'nvram|[ -x /usr/sbin/nvram ]|nvram_watch|y'
  'timezone|[ -L /etc/localtime ]|timezone_watch|y'
  'security|[ -x /usr/sbin/spctl ]|security_watch|y'
  'fw_apps|[ -x /usr/libexec/ApplicationFirewall/socketfilterfw ]|fw_apps_watch|y'
  'spotlight_index|[ -x /usr/bin/mdutil ]|spotlight_watch|y'
  'defprinter|[ -x /usr/bin/lpoptions ]|defprinter_watch|y'
  'touchid|[ -x /usr/bin/bioutil ]|touchid_watch|y'
  'sharing_exec|[ "$(id -u)" -eq 0 ] && [ -x /usr/bin/eslogger ] && [ -n "$PYTHON3_BIN" ]|sharing_exec_watch|y'
  'launchd_state|[ "$(id -u)" -eq 0 ] && [ -n "$PYTHON3_BIN" ]|launchd_state_watch|y'
)

_watcher_parse() {
  local _e="$1"
  _W_NAME="${_e%%|*}"; _e="${_e#*|}"
  _W_GUARD="${_e%%|*}"; _e="${_e#*|}"
  _W_FN="${_e%%|*}"; _W_SUMMARY="${_e##*|}"
}

# Empty re-read = transient tool failure: keep the last good baseline.
_guard_nonempty() { [ -s "$1" ]; }

# Generic poll loop: every <interval>s re-read state via <read-fn>, let
# [guard-fn] veto it, and on a change run <onchange-fn snap curr>.
# The fns are nested functions of the caller (dynamic scoping).
_snapshot_watch() {
  local _name="$1" _interval="$2" _readfn="$3" _onchange="$4" _guard="${5:-}"
  local _snap="$PREFWATCH_TMPDIR/${_name}.snap" _curr="$PREFWATCH_TMPDIR/${_name}.curr"
  "$_readfn" > "$_snap" 2>/dev/null || true
  while true; do
    /bin/sleep "$_interval"
    "$_readfn" > "$_curr" 2>/dev/null || true
    if [ -n "$_guard" ]; then "$_guard" "$_curr" || continue; fi
    if ! /usr/bin/cmp -s "$_snap" "$_curr" 2>/dev/null; then
      "$_onchange" "$_snap" "$_curr" || true
      /bin/cp -f "$_curr" "$_snap" 2>/dev/null || true
    fi
  done
}

# ---------------------------------------
# Single-domain Mode
# ---------------------------------------

start_watch() {
  local plist_path last_mtime current_mtime

  # No plist yet (app never configured): fall back to full-domain polling.
  plist_path=$(get_plist_path_for_domain "$DOMAIN") || plist_path=""

  if [ -n "$plist_path" ]; then
    log_line "Mode: optimized mtime polling (0.5s check on $plist_path)"

    (
      show_domain_diff "$DOMAIN"
      # From here a domain appearing is reportable.
      typeset -g _BASELINE_DONE=true
      last_mtime=$(stat -f %m "$plist_path" 2>/dev/null || echo "")
      local _forced_tick=0
      while true; do
        if [ -f "$plist_path" ]; then
          current_mtime=$(stat -f %m "$plist_path" 2>/dev/null || echo "")

          if [ -n "$current_mtime" ] && [ "$current_mtime" != "$last_mtime" ]; then
            show_domain_diff "$DOMAIN"
            last_mtime="$current_mtime"
            _forced_tick=0
          else
            # Forced diff every ~2s: mtime cannot see a same-second write.
            _forced_tick=$((_forced_tick + 1))
            if [ "$_forced_tick" -ge 4 ]; then
              show_domain_diff "$DOMAIN"
              last_mtime="$current_mtime"
              _forced_tick=0
            fi
          fi
        else
          last_mtime=""
        fi
        sleep 0.5  # Check twice per second for responsiveness
      done
    ) &
    _WATCH_PIDS+=($!)
  else
    _note_group_container_domain "$DOMAIN" || true
    log_line "Mode: standard polling (plist not found, checking domain every 1s)"

    (
      # Baseline first; only then may the domain be reported as new.
      show_domain_diff "$DOMAIN"
      typeset -g _BASELINE_DONE=true
      while true; do
        show_domain_diff "$DOMAIN"
        sleep 1
      done
    ) &
    _WATCH_PIDS+=($!)
  fi

  _emit_mdm_resolver_header

  # The orphan watchdog survives a SIGKILL of main, which no trap catches.
  local _wt_self=""
  [ "${HAVE_ZSH_SYSTEM:-false}" = true ] && _wt_self="${sysparams[pid]}"
  if [ -n "$_wt_self" ]; then
    _orphan_watchdog "$_wt_self" &
    _WATCH_PIDS+=($!)
  fi

  # EXIT armed here: a trap inherited from main does not fire in a `&` job.
  trap '_watchers_teardown; exit 0' TERM INT
  trap '_watchers_teardown' EXIT
  wait
}

# ---------------------------------------
# ALL Mode (core)
#
# Baseline snapshot of every plist, then the two core detectors: poll_watch
# (mtime polling) and fs_watch (fs_usage, deprecated). The feature watchers
# they run next to are in the WATCHERS section that follows.
# ---------------------------------------

start_watch_all() {
  if [ "$(id -u)" -ne 0 ]; then
    log_line "Mode: monitoring ALL preferences (polling only. No root)"
  elif [ "$FS_USAGE" = true ]; then
    log_line "Mode: monitoring ALL preferences (fs_usage + polling)"
    log_line "Cmd: # NOTE: --fs-usage (Jamf \$12) is deprecated and will be removed in the next release. Polling sees the same writes."
  else
    log_line "Mode: monitoring ALL preferences (polling)"
  fi

  local prefs_user prefs_system
  prefs_system="/Library/Preferences"
  prefs_user="$TARGET_HOME/Library/Preferences"

  _snapshot_one_plist() {
    local path="$1"
    [ -f "$path" ] || return 0
    init_cache
    local key
    key=$(hash_path "$path")
    local prev="$CACHE_DIR/${key}.prev"
    local curr="$CACHE_DIR/${key}.curr"
    local prev_json="$CACHE_DIR/${key}.prev.json"
    local curr_json="$CACHE_DIR/${key}.curr.json"
    local _sp_pid _spj_pid
    dump_plist "$path" "$curr" &
    _sp_pid=$!
    dump_plist_json "$path" "$curr_json" &
    _spj_pid=$!
    wait "$_sp_pid" "$_spj_pid" 2>/dev/null || true
    /bin/mv -f "$curr" "$prev" 2>/dev/null || /bin/cp -f "$curr" "$prev" 2>/dev/null || :
    /bin/mv -f "$curr_json" "$prev_json" 2>/dev/null || /bin/cp -f "$curr_json" "$prev_json" 2>/dev/null || :
  }

  # Baseline one prefs tree, 16 in parallel. Args: label, root path.
  _snapshot_tree() {
    local _label="$1" _root="$2" _snap_count=0 _snap_idx=0 _pid f dom
    local _snap_spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local -a _snap_pids=()
    local _max_parallel=16
    snapshot_notice "${_label} snapshot: scanning..."
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      dom=$(domain_from_plist_path "$f")
      if is_excluded_domain "$dom"; then
        continue
      fi
      _snap_count=$(( _snap_count + 1 ))
      _snap_idx=$(( _snap_count % ${#_snap_spinner[@]} ))
      printf "\r  ${_snap_spinner[$_snap_idx+1]} ${_label} snapshot: %d domains scanned..." "$_snap_count"
      snapshot_notice "${_label:u}: ${dom:-$f}" true
      _snapshot_one_plist "$f" &
      _snap_pids+=($!)
      if (( ${#_snap_pids[@]} >= _max_parallel )); then
        # zsh arrays are 1-based: [1] is the oldest pid. [0] is empty.
        wait "${_snap_pids[1]}" 2>/dev/null || true
        _snap_pids=("${_snap_pids[@]:1}")
      fi
    done < <(/usr/bin/find "$_root" -type f -name "*.plist" 2>/dev/null || true)
    for _pid in "${_snap_pids[@]}"; do wait "$_pid" 2>/dev/null || true; done
    printf "\r  ✓ ${_label} snapshot: %d domains scanned    \n" "$_snap_count"
    snapshot_notice "${_label} snapshot: completed ($_snap_count domains)"
    SNAPSHOT_READY="true"
    # From here a missing baseline means the file is new.
    typeset -g _BASELINE_DONE=true
  }

  snapshot_notice "Taking initial baseline. Please wait before making changes"

  if [ -d "$prefs_user" ]; then
    _snapshot_tree User "$prefs_user"
  fi

  if [ "$INCLUDE_SYSTEM" = "true" ] && [ -d "$prefs_system" ]; then
    _snapshot_tree System "$prefs_system"
  fi

  if [ "${SNAPSHOT_READY:-false}" = "true" ]; then
    snapshot_notice "Initial snapshots processed. You can now make your changes"
    # Built from the same _WATCHERS registry as the launch loop, so it cannot drift.
    local -a _watch_active=()
    local _w=""
    for _w in "${_WATCHERS[@]}"; do
      _watcher_parse "$_w"
      [ "$_W_SUMMARY" = y ] || continue
      if eval "$_W_GUARD"; then _watch_active+=("$_W_NAME"); fi
    done
    # --debug only: startup noise otherwise.
    if [ "${DEBUG_FILTER:-false}" = "true" ] && (( ${#_watch_active[@]} > 0 )); then
      log_line "Cmd: # Watchers active: ${(j:, :)_watch_active}"
    fi
    _emit_mdm_resolver_header
    log_line "Cmd: # NOTE: Changes may take a few seconds to appear. Wait between actions for reliable capture"
  fi

  # USER / SYSTEM (baselined), CONTAINER, OTHER. Separate for the harness.
  _fs_classify() {
    local _p="$1"
    case "$_p" in
      "$prefs_user"/*)   print -r -- USER ;;
      "$prefs_system"/*) print -r -- SYSTEM ;;
      */Library/Containers/*|*"/Library/Group Containers/"*) print -r -- CONTAINER ;;
      *)                 print -r -- OTHER ;;
    esac
  }

  # Real-time detector: plist writes via fs_usage.
  fs_watch() {
    # Debounce: cfprefsd fires several events per write; poll_watch catches misses.
    typeset -A _fs_last_seen=()
    local _FS_DEBOUNCE_S=0.3
    # script(1) gives fs_usage a pty so it line-buffers (no stdbuf on macOS).
    # Path resolved and its absence logged: a wrong path once killed it silently.
    local _fsu=""
    for _c in /usr/bin/fs_usage /usr/sbin/fs_usage /sbin/fs_usage; do
      [ -x "$_c" ] && { _fsu="$_c"; break; }
    done
    if [ -z "$_fsu" ]; then
      log_line "Cmd: # NOTE: fs_usage not found. Real-time detection off; polling covers the same ground"
      return 0
    fi
    # ktrace admits ONE client. No warning up front (`ktrace info` names routine
    # daemons on a healthy Mac); the post-mortem below asks who holds it.
    local _fsu_who=""
    local _fsu_err="${PREFWATCH_TMPDIR}/fs_usage.err"
    # `</dev/null`: script(1) dies on a socket stdin (Jamf). fs_usage runs under
    # `sh -c "exec … 2>>err"` so its stderr is kept and the tree stays flat.
    # `-f pathname`, not filesys: 510 MB against 8 GB under a reindex.
    # The watchdog kills only OUR fs_usage past FS_USAGE_RSS_LIMIT_MB (matched by
    # grandparent pid) and dies with the pipeline.
    local _fw_self="" _fw_watchdog=""
    [ "${HAVE_ZSH_SYSTEM:-false}" = true ] && _fw_self="${sysparams[pid]}"
    if [ -n "$_fw_self" ]; then
      ( local _fw_pid _fw_gp _fw_rss _fw_seen=false
        while /bin/sleep 10; do
          _fw_pid=$(/usr/bin/pgrep -x fs_usage 2>/dev/null | /usr/bin/head -1) || _fw_pid=""
          if [ -z "$_fw_pid" ]; then [ "$_fw_seen" = true ] && exit 0; continue; fi
          _fw_gp=$(/bin/ps -o ppid= -p "$(/bin/ps -o ppid= -p "$_fw_pid" 2>/dev/null | /usr/bin/tr -d ' ')" 2>/dev/null | /usr/bin/tr -d ' ') || _fw_gp=""
          [ "$_fw_gp" = "$_fw_self" ] || continue
          _fw_seen=true
          _fw_rss=$(/bin/ps -o rss= -p "$_fw_pid" 2>/dev/null | /usr/bin/tr -d ' ') || _fw_rss=""
          [ -n "$_fw_rss" ] || continue
          if (( _fw_rss / 1024 > FS_USAGE_RSS_LIMIT_MB )); then
            printf '%d' "$(( _fw_rss / 1024 ))" > "${PREFWATCH_TMPDIR}/fs_usage.rss" 2>/dev/null || true
            /bin/kill -TERM "$_fw_pid" 2>/dev/null || true
            exit 0
          fi
        done ) &
      _fw_watchdog=$!
    fi
    script -q /dev/null /bin/sh -c "exec ${(q)_fsu} -w -f pathname 2>>${(q)_fsu_err}" </dev/null 2>>"$_fsu_err" |
    # ONE sed, ON ONE LINE (fs-path-extract reads it back): 1. the plist path,
    # anchored on space + '/' (a greedy `.*` once dropped the /Users prefix);
    # 2. the 27 firmlink /System/Volumes/Data/Users → /Users; 3. only files IN a
    # Preferences directory. LC_ALL=C: one non-UTF-8 byte kills BSD sed.
    LC_ALL=C /usr/bin/sed -l -nE -e 's@.*[[:space:]](/([^[:space:]]*/)?Library/(Group Containers|Containers|Preferences)/.*\.plist).*@\1@' -e 's@^/System/Volumes/Data/@/@' -e '\@/Library/Preferences/(ByHost/)?[^/]+\.plist$@p' |
    while IFS= read -r plist; do
      [ -z "$plist" ] && continue
      cat_type=$(_fs_classify "$plist")
      if [ "$cat_type" = "SYSTEM" ] && [ "${INCLUDE_SYSTEM}" != "true" ]; then
        continue
      fi
      # Containers have no baseline: diffing would announce "a new domain". Dropped (--debug says so).
      if [ "$cat_type" = "CONTAINER" ]; then
        _dbg_filtered "$(domain_from_plist_path "$plist") (container prefs. Out of scope, see README)"
        continue
      fi
      # Other trees (root's ~, another user's, a volume): no baseline either.
      if [ "$cat_type" = "OTHER" ]; then
        _dbg_filtered "$(domain_from_plist_path "$plist") (outside the watched preference trees: $plist)"
        continue
      fi
      if [ "$HAVE_ZSH_STRFTIME" = "true" ]; then
        local _now="$EPOCHREALTIME" _last="${_fs_last_seen[$plist]:-0}"
        if (( _now - _last < _FS_DEBOUNCE_S )); then
          continue
        fi
        _fs_last_seen[$plist]="$_now"
      fi
      dom=$(domain_from_plist_path "$plist")
      if is_excluded_domain "$dom"; then
        continue
      fi
      if [ -n "$dom" ]; then
        /usr/bin/touch "$PREFWATCH_TMPDIR/active-domains/$dom" 2>/dev/null || true
        # Pre-flush cfprefsd so the first retry of show_plist_diff sees the change.
        if [[ "$plist" == *"/ByHost/"* ]]; then
          "${RUN_AS_USER[@]}" /usr/bin/defaults -currentHost read "$dom" >/dev/null 2>&1 &
        else
          "${RUN_AS_USER[@]}" /usr/bin/defaults read "$dom" >/dev/null 2>&1 &
        fi
      fi
      if [ "$cat_type" = "USER" ]; then
        log_user "FS change: $plist"; show_plist_diff USER "$plist"; [ -n "$dom" ] && show_domain_diff "$dom" true
      else
        log_system "FS change: $plist"; show_plist_diff SYSTEM "$plist"; [ -n "$dom" ] && show_domain_diff "$dom" true
      fi
    done
    # fs_usage exited: real-time detection is over; report what it said.
    [ -n "$_fw_watchdog" ] && { /bin/kill "$_fw_watchdog" 2>/dev/null || true; }
    local _why=""
    [ -s "$_fsu_err" ] && _why=$(/usr/bin/head -1 "$_fsu_err" 2>/dev/null)
    if [ -s "${PREFWATCH_TMPDIR}/fs_usage.rss" ]; then
      local _fw_hit=""; _fw_hit=$(/bin/cat "${PREFWATCH_TMPDIR}/fs_usage.rss" 2>/dev/null) || _fw_hit="?"
      _log_note_wrapped "" "real-time detection stopped by PrefWatch: fs_usage reached ${_fw_hit} MB (limit ${FS_USAGE_RSS_LIMIT_MB} MB). The machine's file activity outran it. Polling continues, at the same latency."
      return 0
    fi
    case "$_why" in
      *"Resource busy"*)
        # Name the ktrace holder ("Owning process is [N]", e.g. FlexNet); "Last
        # configured by" only as a labelled fallback. Guarded: fails without root.
        local _kt="" _own_pid=""
        if [ -x /usr/bin/ktrace ]; then
          _kt=$(/usr/bin/ktrace info 2>/dev/null) || _kt=""
          _own_pid=$(printf '%s\n' "$_kt" | /usr/bin/sed -nE 's/.*Owning process is \[([0-9]+)\].*/\1/p' | /usr/bin/head -1) || _own_pid=""
          if [ -n "$_own_pid" ]; then
            _fsu_who=$(/bin/ps -o comm= -p "$_own_pid" 2>/dev/null) || _fsu_who=""
            [ -n "$_fsu_who" ] && _fsu_who="held by $_fsu_who (pid $_own_pid)"
          fi
          if [ -z "$_fsu_who" ]; then
            _fsu_who=$(printf '%s\n' "$_kt" | /usr/bin/sed -nE "s/.*Last configured by '([^']+)'.*/\1/p" | /usr/bin/head -1) || _fsu_who=""
            [ -n "$_fsu_who" ] && _fsu_who="taken; last configured by '$_fsu_who', which may not be the holder"
          fi
        fi
        # Each branch supplies its full clause.
        log_line "Cmd: # NOTE: real-time detection OFF. Ktrace allows one client and it is ${_fsu_who:-taken}."
        # Measured: 0.47s with real-time, 0.49s without.
        log_line "Cmd: #       Polling covers the same ground at the same latency (measured)." ;;
      "")
        log_line "Cmd: # NOTE: real-time detection stopped (fs_usage exited without a message). Polling continues" ;;
      *)
        log_line "Cmd: # NOTE: real-time detection stopped. Fs_usage: $_why" ;;
    esac
  }

  # Fallback detector: periodic `find -newer` for writes fs_usage misses.
  poll_watch() {
    local marker_user marker_sys active_dir
    # Locals declared once: a re-`local` prints `foo=value`.
    local _hd _af _adom _p _watchdog
    local -a _pids _hotpaths
    local -A _st
    marker_user="$PREFWATCH_TMPDIR/poll.marker.user"
    marker_sys="$PREFWATCH_TMPDIR/poll.marker.sys"
    active_dir="$PREFWATCH_TMPDIR/active-domains"
    /bin/mkdir -p "$active_dir" 2>/dev/null || true
    # Hot-marker paths built once: one `touch` per cycle, not one per domain.
    _hotpaths=()
    (( ${#HOT_DOMAINS[@]} )) && _hotpaths=("$active_dir/"${^HOT_DOMAINS})
    [ -f "$marker_user" ] || /usr/bin/touch "$marker_user" 2>/dev/null || true
    [ -f "$marker_sys" ]  || /usr/bin/touch "$marker_sys" 2>/dev/null || true

    while true; do
      # Flush cfprefsd for domains active in the last 30s.
      if [ -d "$active_dir" ] && [ "$HAVE_ZSH_STAT" = "true" ]; then
        (( ${#_hotpaths[@]} )) && { /usr/bin/touch "${_hotpaths[@]}" 2>/dev/null || true; }
        _pids=()
        # (DN): a plain glob skips .GlobalPreferences, a HOT domain.
        for _af in "$active_dir"/*(DN); do
          [ -f "$_af" ] || continue
          zstat -H _st "$_af" 2>/dev/null || continue
          if (( EPOCHSECONDS - _st[mtime] > 30 )); then
            /bin/rm -f "$_af" 2>/dev/null || true
            continue
          fi
          _adom="${_af:t}"
          # Bare read only; ByHost is flushed by show_plist_diff/fs_watch.
          "${RUN_AS_USER[@]}" /usr/bin/defaults read "$_adom" >/dev/null 2>&1 &
          _pids+=($!)
        done
        # Watchdog: kill hung reads (TERM 1s / KILL 1.5s). A missed hint is harmless.
        if (( ${#_pids[@]} > 0 )); then
          (
            /bin/sleep 1
            for _p in "${_pids[@]}"; do /bin/kill -TERM "$_p" 2>/dev/null || :; done
            /bin/sleep 0.5
            for _p in "${_pids[@]}"; do /bin/kill -KILL "$_p" 2>/dev/null || :; done
          ) &
          _watchdog=$!
          for _p in "${_pids[@]}"; do wait "$_p" 2>/dev/null || true; done
          /bin/kill -TERM "$_watchdog" 2>/dev/null || true
          wait "$_watchdog" 2>/dev/null || true
        fi
      fi

      # Stamp the NEXT marker BEFORE scanning: advancing it afterwards loses
      # every plist written during the scan.
      /usr/bin/touch "$marker_user.next" 2>/dev/null || true
      if [ -d "$prefs_user" ]; then
        /usr/bin/find "$prefs_user" -type f -name "*.plist" -newer "$marker_user" 2>/dev/null | while IFS= read -r f; do
          [ -n "$f" ] || continue
          dom=$(domain_from_plist_path "$f")
          if is_excluded_domain "$dom"; then
            continue
          fi
          [ -n "$dom" ] && /usr/bin/touch "$active_dir/$dom" 2>/dev/null || true
          log_user "POLL change: $f"; show_plist_diff USER "$f"; [ -n "$dom" ] && show_domain_diff "$dom" true
        done
      fi
      if [ "${INCLUDE_SYSTEM}" = "true" ] && [ -d "$prefs_system" ] && [ "$(id -u)" -eq 0 ]; then
        /usr/bin/find "$prefs_system" -type f -name "*.plist" -newer "$marker_sys" 2>/dev/null | while IFS= read -r f; do
          [ -n "$f" ] || continue
          dom=$(domain_from_plist_path "$f")
          if is_excluded_domain "$dom"; then
            continue
          fi
          log_system "POLL change: $f"; show_plist_diff SYSTEM "$f"; [ -n "$dom" ] && show_domain_diff "$dom" true
        done
      fi
      /bin/mv -f "$marker_user.next" "$marker_user" 2>/dev/null || /usr/bin/touch "$marker_user" 2>/dev/null || true
      /usr/bin/touch -r "$marker_user" "$marker_sys" 2>/dev/null || true
      /bin/sleep 0.5 || true
    done
  }

  # Feature watchers live in the WATCHERS section; _WATCHERS launches them.

  /usr/bin/touch "$PREFWATCH_TMPDIR/poll.marker.user" 2>/dev/null || true
  /usr/bin/touch "$PREFWATCH_TMPDIR/poll.marker.sys" 2>/dev/null || true
  /bin/mkdir -p "$PREFWATCH_TMPDIR/active-domains" 2>/dev/null || true
  local _hd
  for _hd in "${HOT_DOMAINS[@]}"; do
    /usr/bin/touch "$PREFWATCH_TMPDIR/active-domains/$_hd" 2>/dev/null || true
  done

  # Launch every watcher whose guard passes (guard in an `if`: no set -e abort).
  # A new watcher is ONE registry entry.
  local _w=""
  for _w in "${_WATCHERS[@]}"; do
    _watcher_parse "$_w"
    if eval "$_W_GUARD"; then _spawn "$_W_FN"; fi
  done

  # The orphan watchdog survives a SIGKILL of main, which no trap catches.
  local _wt_self=""
  [ "${HAVE_ZSH_SYSTEM:-false}" = true ] && _wt_self="${sysparams[pid]}"
  if [ -n "$_wt_self" ]; then
    _orphan_watchdog "$_wt_self" &
    _WATCH_PIDS+=($!)
  fi

  # EXIT armed here: a trap inherited from main does not fire in a `&` job.
  trap '_watchers_teardown; exit 0' TERM INT
  trap '_watchers_teardown' EXIT
  wait
}

# ---------------------------------------
# WATCHERS
#
# One function per setting that lives outside the preference plists (or that
# a plist only mirrors). Each reads a source, keeps a snapshot, and reports
# the change as a command or a NOTE. Registered in _WATCHERS, launched by
# start_watch_all. In file order:
#   cups_sharing_watch, cups_watch, sharing_exec_watch, launchd_state_watch
#   pmset_watch, ard_privs_watch, sharepoints_watch, bluetooth_watch
#   useracct_watch, hostname_watch, default_apps_watch, wallpaper_watch
#   tcc_watch, nvram_watch, timezone_watch, security_watch
#   fw_apps_watch, touchid_watch, defprinter_watch, spotlight_watch
# ---------------------------------------

# Printer Sharing: reads the Browsing line of cupsd.conf. A missing cupsd.conf
# means off: the first toggle creates it.
cups_sharing_watch() {
  local cupsdconf="/etc/cups/cupsd.conf"
  local share_snap=""
  share_snap=$(/usr/bin/grep -iE "^Browsing[[:space:]]+" "$cupsdconf" 2>/dev/null | /usr/bin/head -1 | /usr/bin/awk '{print tolower($2)}' || true)
  [ -z "$share_snap" ] && share_snap="off"

  while true; do
    /bin/sleep 0.5 || true
    local share_curr=""
    share_curr=$(/usr/bin/grep -iE "^Browsing[[:space:]]+" "$cupsdconf" 2>/dev/null | /usr/bin/head -1 | /usr/bin/awk '{print tolower($2)}' || true)
    [ -z "$share_curr" ] && share_curr="off"
    if [ "$share_curr" != "$share_snap" ]; then
      case "$share_curr" in
        on|yes)
          log_line "Cmd: # CUPS: Printer Sharing enabled"
          log_line "Cmd: sudo /usr/sbin/cupsctl --share-printers"
          ;;
        *)
          log_line "Cmd: # CUPS: Printer Sharing disabled"
          log_line "Cmd: sudo /usr/sbin/cupsctl --no-share-printers"
          ;;
      esac
      share_snap="$share_curr"
    fi
  done
}

cups_watch() {
  local cups_snapshot cups_current
  cups_snapshot="$PREFWATCH_TMPDIR/cups.snap"
  cups_current="$PREFWATCH_TMPDIR/cups.curr"

  /usr/bin/lpstat -a 2>/dev/null | /usr/bin/awk '{print $1}' | /usr/bin/sort > "$cups_snapshot" 2>/dev/null || true

  # `|| true` on every sleep: TERM lands in the sleep and set -e would log an ABORT.
  while true; do
    /bin/sleep 1 || true
    /usr/bin/lpstat -a 2>/dev/null | /usr/bin/awk '{print $1}' | /usr/bin/sort > "$cups_current" 2>/dev/null || true

    # Changed: wait 5s and re-check (Bonjour glitches).
    if ! /usr/bin/cmp -s "$cups_snapshot" "$cups_current"; then
      /bin/sleep 5 || true
      /usr/bin/lpstat -a 2>/dev/null | /usr/bin/awk '{print $1}' | /usr/bin/sort > "$cups_current" 2>/dev/null || true
    fi

    /usr/bin/comm -13 "$cups_snapshot" "$cups_current" 2>/dev/null | while IFS= read -r printer; do
      [ -z "$printer" ] && continue
      log_line "Cmd: # CUPS: printer added. $printer"

      local uri=""
      # `lpstat -v` fails while cupsd reloads; unguarded, set -e killed the watcher.
      uri=$(/usr/bin/lpstat -v "$printer" 2>/dev/null | /usr/bin/sed -nE 's/.*:[[:space:]]+(.*)/\1/p') || uri=""

      local opts=""
      opts=$( { /usr/bin/lpoptions -p "$printer" 2>/dev/null | /usr/bin/tr ' ' '\n' | /usr/bin/grep -E '^(media|sides|print-color-mode|print-quality|printer-is-shared)=' | while IFS= read -r o; do printf " -o %s" "$o"; done; } || true)  # grep exits 1 if the printer has none of these → guard set -e

      # Escaped: a queue name allows $, backtick and parentheses, and the URI comes from mDNS.
      local cmd="sudo lpadmin -p \"$(_escape_dq "$printer")\""
      [ -n "$uri" ] && cmd="$cmd -v \"$(_escape_dq "$uri")\""
      cmd="$cmd -m everywhere -E${opts}"
      log_line "Cmd: $cmd"
    done

    /usr/bin/comm -23 "$cups_snapshot" "$cups_current" 2>/dev/null | while IFS= read -r printer; do
      [ -z "$printer" ] && continue
      log_line "Cmd: # CUPS: printer removed. $printer"
      log_line "Cmd: sudo lpadmin -x \"$(_escape_dq "$printer")\""
    done

    /bin/cp -f "$cups_current" "$cups_snapshot" 2>/dev/null || true
  done
}

# eslogger exec events for sharing CLIs, for UI toggles outside /Library/Preferences.
# Requires root + eslogger + Python3.
sharing_exec_watch() {
  if [ ! -x /usr/bin/eslogger ]; then
    log_line "Cmd: # sharing_exec_watch DISABLED: /usr/bin/eslogger not executable"
    return 0
  fi
  if [ -z "$PYTHON3_BIN" ]; then
    log_line "Cmd: # sharing_exec_watch DISABLED: Python3 unavailable"
    return 0
  fi
  /bin/mkdir -p "$PREFWATCH_TMPDIR/sharing_recent" 2>/dev/null || true

  # readline(), not `for line in stdin` (buffers); -u unbuffers. The trailing "
  # anchors each pattern on the executable-path field of eslogger.
  /usr/bin/eslogger exec 2>/dev/null \
    | /usr/bin/grep --line-buffered -F -e '/kickstart"' -e '/systemsetup"' -e '/sharing"' -e '/networksetup"' -e '/launchctl"' \
                                   -e '/scselect"' -e '/tmutil"' -e '/nvram"' -e '/AssetCacheManagerUtil"' \
    | "$PYTHON3_BIN" -u -c '
import json, sys, shlex, time
# basename -> its ONE allowed path: a `sharing` of any user elsewhere would
# otherwise land in a root-replayed log as `sudo /Users/eve/bin/sharing`.
CANONICAL_BINS = {
    "kickstart": "/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart",
    "systemsetup": "/usr/sbin/systemsetup",
    "sharing": "/usr/sbin/sharing",
    "networksetup": "/usr/sbin/networksetup",
    "scselect": "/usr/sbin/scselect",
    "nvram": "/usr/sbin/nvram",
    "tmutil": "/usr/bin/tmutil",
    "AssetCacheManagerUtil": "/usr/bin/AssetCacheManagerUtil",
}
DIRECT_BINS = tuple(CANONICAL_BINS)
# kickstart is Perl: resolve the script from args for interpreters only, not
# launchers like sudo (they re-exec as their own event).
SCRIPT_INTERPRETERS = ("perl", "python", "python3", "ruby", "bash", "sh", "zsh")
# launchctl: state-changing subcommands only.
LAUNCHCTL_SUBCMDS = {"load", "unload", "enable", "disable", "bootstrap", "bootout", "kickstart"}
# Apple sharing labels only (apps churn their own LaunchAgents). "/ssh.plist"
# keeps its slash: a bare "ssh.plist" matched a jamf startssh.plist.
SHARING_LABELS = ("com.apple.smbd", "com.apple.screensharing", "com.openssh.sshd",
                  "/ssh.plist", "com.apple.RemoteDesktop", "com.apple.ARDAgent")
# Daemons poll networksetup/systemsetup read-only, sometimes without the dash:
# strip dashes, drop queries.
READONLY_VERBS = ("get", "list", "print", "show")
# Tools PrefWatch emits are watched too, with a WHITELIST of write verbs.
WRITE_VERBS = {
    "tmutil": ("enable", "disable", "startbackup", "stopbackup", "addexclusion",
               "removeexclusion", "setdestination", "removedestination", "delete",
               "deletelocalsnapshots", "deleteinprogress", "inheritbackup",
               "associatedisk", "localsnapshot", "restore"),
    "AssetCacheManagerUtil": ("activate", "deactivate", "flushCache", "flushPersonalCache",
                              "flushSharedCache", "reloadSettings", "moveCacheTo",
                              "absorbCacheFrom"),
}
# A Time Machine exclusion on a temporary path is app housekeeping: dropped.
TRANSIENT_PREFIXES = ("/var/folders/", "/private/var/folders/", "/tmp/", "/private/tmp/")
def is_readonly(basename, args):
    rest = args[1:]
    if basename in WRITE_VERBS:
        subs = [a for a in rest if not a.startswith("-")]
        if basename == "tmutil" and subs and subs[0] in ("addexclusion", "removeexclusion") \
           and all(a.startswith(TRANSIENT_PREFIXES) for a in subs[1:]):
            return True
        return not (subs and subs[0] in WRITE_VERBS[basename])
    if basename == "nvram":
        # Write = name=value, -d or -c; anything else reads.
        return not any("=" in a for a in rest) and not any(a in ("-d", "-c") for a in rest)
    if basename == "scselect":
        # No location argument only lists; -n still switches (next boot).
        return not [a for a in rest if not a.startswith("-")]
    if basename not in ("networksetup", "systemsetup"):
        return False
    if len(args) < 2:
        return True
    sub = args[1].lstrip("-")
    return sub.startswith(READONLY_VERBS)
# Same exec fired twice back-to-back: skip identical commands within 1s.
DEDUP_WINDOW_S = 1.0
last_seen = {}
def emit(cmd):
    now = time.time()
    if cmd in last_seen and now - last_seen[cmd] < DEDUP_WINDOW_S:
        return
    last_seen[cmd] = now
    print(cmd, flush=True)
while True:
    line = sys.stdin.readline()
    if not line:
        break
    try:
        d = json.loads(line)
        ev = d.get("event", {}).get("exec", {})
        tgt = ev.get("target", {})
        exe = tgt.get("executable", {}).get("path", "")
        if not exe:
            continue
        basename = exe.rsplit("/", 1)[-1]
        args = ev.get("args", []) or []
        if basename in SCRIPT_INTERPRETERS:
            for i in range(1, len(args)):
                if args[i].rsplit("/", 1)[-1] in DIRECT_BINS:
                    exe, args, basename = args[i], args[i:], args[i].rsplit("/", 1)[-1]
                    break
        if basename in DIRECT_BINS:
            if exe != CANONICAL_BINS[basename]:
                continue
            if is_readonly(basename, args):
                continue
            # A newline in an argument would forge a second `Cmd:` line.
            if any("\n" in a for a in args):
                continue
            tail = " ".join(shlex.quote(a) for a in args[1:]) if len(args) > 1 else ""
            # Quote the PATH too: the binary of any user lands in a root-replayed line.
            emit((shlex.quote(exe) + " " + tail).rstrip())
        elif (basename == "launchctl" and exe == "/bin/launchctl"
              and len(args) > 1 and args[1] in LAUNCHCTL_SUBCMDS
              and not any("\n" in a for a in args)):
            # Sharing labels only.
            if not any(lbl in " ".join(args) for lbl in SHARING_LABELS):
                continue
            # launchd cycles socket-activated daemons itself; launchd_state_watch reports state.
            if args[1] in ("load", "unload") and any(
                n in a for n in ("com.apple.smbd", "com.apple.bootpd", "com.apple.dhcp6d")
                for a in args):
                pass
            else:
                tail = " ".join(shlex.quote(a) for a in args[1:])
                emit(shlex.quote(exe) + " " + tail)
    except Exception:
        pass
' 2>/dev/null \
    | while IFS= read -r cmd; do
        [ -n "$cmd" ] || continue
        # macOS writes the login-window keyboard to NVRAM on every input-source
        # change (27.0): say so, or it reads as something the admin did.
        case "$cmd" in
          */nvram\ prev-lang:kbd=*)
            _note_should_show __nvram_prevlang__ \
              && _log_note_wrapped "" "macOS wrote this itself when the input sources changed. It sets the keyboard layout and language of the login window." ;;
        esac
        # These CLIs all need root.
        log_line "Cmd: sudo $cmd"
        # Timestamped marker so launchd_state_watch can add its dedup NOTE.
        if [[ "$cmd" =~ launchctl[[:space:]]+(load|unload)[[:space:]]+-w[[:space:]]+[^[:space:]]+/([^/]+)\.plist ]]; then
          /usr/bin/touch "$PREFWATCH_TMPDIR/sharing_recent/${match[2]}" 2>/dev/null || true
        fi
      done
}

# Poll the launchd disabled.plist every 2s: Tahoe flips sharing services over XPC
# (no exec). Emit launchctl enable/disable. Requires root + Python3.
launchd_state_watch() {
  [ -n "$PYTHON3_BIN" ] || return 0
  local sys_plist="/var/db/com.apple.xpc.launchd/disabled.plist"
  local user_plist="" console_uid=""
  if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    console_uid=$(id -u "$CONSOLE_USER" 2>/dev/null) || console_uid=""
    [ -n "$console_uid" ] && user_plist="/var/db/com.apple.xpc.launchd/disabled.${console_uid}.plist"
  fi

  local sys_prev="$PREFWATCH_TMPDIR/launchd.sys.json"
  local user_prev="$PREFWATCH_TMPDIR/launchd.user.json"
  [ -f "$sys_plist" ] && /usr/bin/plutil -convert json -o "$sys_prev" "$sys_plist" >/dev/null 2>&1 || true
  [ -n "$user_plist" ] && [ -f "$user_plist" ] && /usr/bin/plutil -convert json -o "$user_prev" "$user_plist" >/dev/null 2>&1 || true

  _emit_launchd_diff() {
    local prev="$1" curr="$2" domain="$3"
    "$PYTHON3_BIN" - "$prev" "$curr" "$domain" 2>/dev/null <<'PY'
import json, sys, fnmatch, shlex
prev_path, curr_path, domain = sys.argv[1], sys.argv[2], sys.argv[3]
# VM / container helpers toggling their own launchd state.
NOISE_PATTERNS = (
    "codes.rambo.*",                  # VirtualBuddy
    "com.parallels.*",                # Parallels Desktop
    "com.vmware.*",                   # VMware Fusion
    "org.virtualbox.*",               # VirtualBox
    "com.docker.*",                   # Docker Desktop
    "com.fortinet.*",                 # FortiClient VPN/security agent. Re-bootstraps its daemons on wake
    "com.apple.ManagedClient*",       # MDM enrollagent auto-disable post-enrollment
    "com.apple.bootpd",               # DHCP/BOOTP server. Flaps with Internet Sharing/network
    "com.apple.dhcp6d",               # DHCPv6 server. Flaps automatically
    "com.apple.FolderActionsDispatcher",  # Folder Actions dispatcher. System auto-toggles it (enable+disable in one burst = net no-op flap)
)
def is_noisy(svc):
    return any(fnmatch.fnmatchcase(svc, p) for p in NOISE_PATTERNS)
def load(p):
    try:
        with open(p) as f: return json.load(f)
    except Exception:
        return {}
prev = load(prev_path)
curr = load(curr_path)
# gui/<uid> needs `launchctl asuser <uid>` for a root replay; system stays.
def _lc(verb, k):
    # `k` is user-settable and the line gets sudo: quote it.
    base = f"/bin/launchctl {verb} {shlex.quote(domain + '/' + k)}"
    return f"/bin/launchctl asuser {domain.split('/',1)[1]} {base}" if domain.startswith("gui/") else base
for k in sorted(set(prev) | set(curr)):
    if is_noisy(k):
        continue
    pv, cv = prev.get(k), curr.get(k)
    if pv == cv:
        continue
    if cv is False or cv is None:  # newly enabled, or removed from disabled list
        print(_lc("enable", k))
    elif cv is True:
        print(_lc("disable", k))
PY
  }

  # Label → LaunchDaemon plist (filename, else a Label grep). Unresolved → reboot NOTE.
  _resolve_launchd_plist() {
    local label="$1" d f
    for d in /System/Library/LaunchDaemons /Library/LaunchDaemons; do
      [ -f "$d/${label}.plist" ] && { printf '%s' "$d/${label}.plist"; return 0; }
    done
    local -a _lds _cands
    _lds=( /System/Library/LaunchDaemons/*.plist(N) /Library/LaunchDaemons/*.plist(N) )
    (( ${#_lds[@]} )) || return 1
    _cands=( ${(f)"$(/usr/bin/grep -lF "$label" "${_lds[@]}" 2>/dev/null)"} )
    for f in "${_cands[@]}"; do
      [ -n "$f" ] || continue
      [ "$(/usr/bin/plutil -extract Label raw -o - "$f" 2>/dev/null)" = "$label" ] && { printf '%s' "$f"; return 0; }
    done
    return 1
  }

  # enable/disable line, a dedup NOTE after a matching load/unload, and for the
  # system domain the bootstrap/bootout companion (enable only flips the flag).
  _emit_with_dup_note() {
    local cmd="$1" recent_dir="$PREFWATCH_TMPDIR/sharing_recent"
    [ -n "$cmd" ] || return 0
    local _verb="" _svc="" _ld_domain=""
    if [[ "$cmd" =~ launchctl[[:space:]]+(enable|disable)[[:space:]]+([^[:space:]]+)$ ]]; then
      _verb="${match[1]}"
      _svc="${match[2]##*/}"          # service label (after last '/')
      _ld_domain="${match[2]%/*}"     # 'system' or 'gui/<uid>'
      if [ -d "$recent_dir" ]; then
        local marker="$recent_dir/$_svc"
        if [ -f "$marker" ] && [ "$HAVE_ZSH_STAT" = "true" ]; then
          typeset -A _mst
          if zstat -H _mst "$marker" 2>/dev/null && (( EPOCHSECONDS - ${_mst[mtime]:-0} < 10 )); then
            log_line "Cmd: # NOTE: equivalent to the launchctl load/unload above"
            /bin/rm -f "$marker" 2>/dev/null || true
          fi
        fi
      fi
    fi
    log_line "Cmd: sudo $cmd"

    # System daemons only; gui agent paths vary (a reboot applies it).
    if [ "$_ld_domain" = "system" ] && [ -n "$_svc" ]; then
      local _companion=""
      if [ "$_verb" = "enable" ]; then
        local _ld_plist=""
        _ld_plist=$(_resolve_launchd_plist "$_svc") || _ld_plist=""
        [ -n "$_ld_plist" ] && _companion="sudo /bin/launchctl bootstrap system \"$_ld_plist\""
      else
        _companion="sudo /bin/launchctl bootout system/${_svc}"
      fi
    # Burst dedup; the bootstrap/bootout command itself is emitted every time.
      if _note_should_show __launchd_bootstrap__; then
        _log_note_wrapped "" "enable/disable only sets the persistent flag. A socket/on-demand service (smbd, ssh, screensharing) won't start/stop until launchd (re)loads it. Its UI toggle won't move either. bootstrap/bootout does the reload, or a reboot"
      fi
      [ -n "$_companion" ] && log_line "Cmd: $_companion"
    fi
  }

  while true; do
    /bin/sleep 2 || true
    if [ -f "$sys_plist" ]; then
      local sys_curr="$PREFWATCH_TMPDIR/launchd.sys.curr.json"
      /usr/bin/plutil -convert json -o "$sys_curr" "$sys_plist" >/dev/null 2>&1 || true
      if [ -s "$sys_curr" ] && ! /usr/bin/cmp -s "$sys_prev" "$sys_curr" 2>/dev/null; then
        _emit_launchd_diff "$sys_prev" "$sys_curr" "system" | while IFS= read -r cmd; do
          _emit_with_dup_note "$cmd"
        done
        /bin/mv -f "$sys_curr" "$sys_prev" 2>/dev/null || true
      else
        /bin/rm -f "$sys_curr" 2>/dev/null || true
      fi
    fi
    if [ -n "$user_plist" ] && [ -f "$user_plist" ]; then
      local user_curr="$PREFWATCH_TMPDIR/launchd.user.curr.json"
      /usr/bin/plutil -convert json -o "$user_curr" "$user_plist" >/dev/null 2>&1 || true
      if [ -s "$user_curr" ] && ! /usr/bin/cmp -s "$user_prev" "$user_curr" 2>/dev/null; then
        _emit_launchd_diff "$user_prev" "$user_curr" "gui/${console_uid}" | while IFS= read -r cmd; do
          _emit_with_dup_note "$cmd"
        done
        /bin/mv -f "$user_curr" "$user_prev" 2>/dev/null || true
      else
        /bin/rm -f "$user_curr" 2>/dev/null || true
      fi
    fi
  done
}

pmset_watch() {
  _pmset_label() {
    local key="$1" val="$2"
    case "$key" in
      powermode)
        case "$val" in
          0) printf 'Low Power' ;; 1) printf 'Automatic' ;; 2) printf 'High Performance' ;; *) printf '%s' "$val" ;;
        esac ;;
      hibernatemode)
        case "$val" in
          0) printf 'Off' ;; 3) printf 'Safe Sleep' ;; 25) printf 'Hibernate' ;; *) printf '%s' "$val" ;;
        esac ;;
      displaysleep|disksleep|sleep)
        if [ "$val" = "0" ]; then printf 'Never'
        elif [ "$val" = "1" ]; then printf '1 min'
        else printf '%s min' "$val"
        fi ;;
      "Sleep On Power Button"|womp|powernap|lessbright|standby|tcpkeepalive|networkoversleep|ttyskeepawake|proximitywake|acwake|lidwake|halfdim|autorestart|autopoweroff|ring|lowpowermode)
        case "$val" in
          0) printf 'Off' ;; 1) printf 'On' ;; *) printf '%s' "$val" ;;
        esac ;;
      standbydelayhigh|standbydelaylow|autopoweroffdelay)
        if [ "$val" = "0" ]; then printf 'Off'
        else printf '%s sec' "$val"
        fi ;;
      highstandbythreshold)
        printf '%s%%' "$val" ;;
      *) printf '%s' "$val" ;;
    esac
  }

  local pmset_snapshot pmset_current
  pmset_snapshot="$PREFWATCH_TMPDIR/pmset.snap"
  pmset_current="$PREFWATCH_TMPDIR/pmset.curr"

  /usr/bin/pmset -g custom > "$pmset_snapshot" 2>/dev/null || true

  while true; do
    /bin/sleep 2 || true
    /usr/bin/pmset -g custom > "$pmset_current" 2>/dev/null || true

    if ! /usr/bin/cmp -s "$pmset_snapshot" "$pmset_current"; then
      local snap_parsed="" curr_parsed=""  # init: re-`local` in this loop would print the vars
      snap_parsed=$(/usr/bin/awk '/^[A-Z]/{sec=$0; sub(/:$/,"",sec); next} NF>=2{val=$NF; key=""; for(i=1;i<NF;i++){if(i>1)key=key" "; key=key$i}; gsub(/^[[:space:]]+|[[:space:]]+$/,"",key); print sec "|" key "|" val}' "$pmset_snapshot")
      curr_parsed=$(/usr/bin/awk '/^[A-Z]/{sec=$0; sub(/:$/,"",sec); next} NF>=2{val=$NF; key=""; for(i=1;i<NF;i++){if(i>1)key=key" "; key=key$i}; gsub(/^[[:space:]]+|[[:space:]]+$/,"",key); print sec "|" key "|" val}' "$pmset_current")

      while IFS='|' read -r section key val; do
        [ -z "$key" ] && continue
        local old_val=""
        old_val=$(printf '%s\n' "$snap_parsed" | /usr/bin/grep "^${section}|${key}|" | /usr/bin/cut -d'|' -f3 || true)  # grep exits 1 on a new key → guard set -e
        [ "$old_val" = "$val" ] && continue

        local flag=""
        case "$section" in
          "Battery Power") flag="-b" ;;
          "AC Power")      flag="-c" ;;
          *)               flag="-a" ;;
        esac

        local old_label="" new_label=""
        new_label=$(_pmset_label "$key" "$val")
        if [ -n "$old_val" ]; then
          old_label=$(_pmset_label "$key" "$old_val")
          log_line "Cmd: # Energy: ${section}. ${key} changed: ${old_label} → ${new_label}"
        else
          log_line "Cmd: # Energy: ${section}. ${key} set to ${new_label}"
        fi
        # `pmset -g custom` prints display labels; accepted names are one token
        # (measured 26.6.2), so a space marks a label.
        case "$key" in
          *\ *)
            _note_should_show "__pmset_label__:$key" \
              && log_line "Cmd: #       (no pmset setting name for '$key'. Set it in System Settings > Battery)" ;;
          *)
            log_line "Cmd: sudo /usr/bin/pmset ${flag} ${key} ${val}" ;;
        esac
      done <<< "$curr_parsed"
    fi

    /bin/cp -f "$pmset_current" "$pmset_snapshot" 2>/dev/null || true
  done
}

# Remote Management per-user privileges: the `naprivs` bitmask in each user
# record, set over XPC. Poll `dscl . -list /Users naprivs`, emit the write.
ard_privs_watch() {
  local _ks=/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart
  _read_ardprivs() { /usr/bin/dscl . -list /Users naprivs 2>/dev/null | /usr/bin/sort; }
  _onchange_ardprivs() {
    local _snap="$1" _curr="$2" u v oldv _changed=false
    while IFS=$' \t' read -r u v; do
        [ -n "$u" ] || continue
        oldv=$(/usr/bin/awk -v k="$u" '$1==k{print $2}' "$_snap" 2>/dev/null)
        [ "$oldv" = "$v" ] && continue
        log_line "Cmd: # Remote Management: per-user ARD access for $u (naprivs bitmask)"
        log_line "Cmd: sudo /usr/bin/dscl . -create /Users/$u naprivs $v"
        _changed=true
    done < "$_curr"
    while IFS=$' \t' read -r u v; do
        [ -n "$u" ] || continue
        /usr/bin/awk -v k="$u" '$1==k{f=1} END{exit !f}' "$_curr" 2>/dev/null && continue
        log_line "Cmd: # Remote Management: ARD access removed for $u"
        log_line "Cmd: sudo /usr/bin/dscl . -delete /Users/$u naprivs"
        _changed=true
    done < "$_snap"
    # The dscl write only persists: the ARD agent must restart to apply it.
    if [ "$_changed" = "true" ] && [ -x "$_ks" ]; then
      if [ -z "${_ARD_RESTART_NOTED:-}" ]; then
        log_line "Cmd: # NOTE: dscl persists naprivs; restart the ARD agent to apply it (UI/live access won't move otherwise)"
        typeset -g _ARD_RESTART_NOTED=1
      fi
      log_line "Cmd: sudo $_ks -restart -agent"
    fi
    return 0
  }
  _snapshot_watch ard_privs 2 _read_ardprivs _onchange_ardprivs
}

# File Sharing share points live in OpenDirectory, not a plist. Read with
# `dscl -plist -readall` (present everywhere; `sharing -l -f json` is recent).
# `-s`/`-g` take three digits (afp, ftp, smb), so smb-only is `001` (26.6.2);
# afp and ftp are unsupported, the first two digits are always 0.
sharepoints_watch() {
  [ -x /usr/bin/dscl ] || return 0
  [ -n "$PYTHON3_BIN" ] || return 0
  _read_sharepoints() {
    /usr/bin/dscl -plist . -readall /SharePoints 2>/dev/null | "$PYTHON3_BIN" -c '
import plistlib, sys
def one(rec, key, default=""):
    v = rec.get("dsAttrTypeNative:" + key) or rec.get("dsAttrTypeStandard:" + key)
    if isinstance(v, list): v = v[0] if v else None
    return default if v in (None, "") else v
try:    recs = plistlib.loads(sys.stdin.buffer.read())
except Exception: sys.exit(0)
if not isinstance(recs, list): sys.exit(0)
rows = []
for rec in recs:
    if not isinstance(rec, dict): continue
    name = one(rec, "RecordName")
    if not name: continue
    # Only the seven fields `sharing` can set; per-machine UUIDs are not selected.
    rows.append((name, one(rec,"directory_path"), one(rec,"smb_shared","0"),
                 one(rec,"smb_guestaccess","0"), one(rec,"smb_readonly","0"),
                 one(rec,"smb_sealed","0"), one(rec,"smb_name", name)))
for row in sorted(rows):
    print("\t".join(str(x) for x in row))
' || true
  }
  # -R and -E only when set: an older macOS gets nothing unknown.
  _sp_flags_add() {   # <shared> <guest> <readonly> <sealed> <smb name>
    local _f
    _f=$(printf -- '-S "%s" -s 00%s -g 00%s' "$(_escape_dq "$5")" "$1" "$2")
    if [ "$3" = 1 ]; then _f="$_f -R 1"; fi
    if [ "$4" = 1 ]; then _f="$_f -E 1"; fi
    printf '%s' "$_f"
  }
  # Only the changed fields (26.6.2): `-S` with the current name is refused and
  # voids the edit; an omitted flag is preserved, so `-R 0` is spelled out.
  _sp_flags_edit() {  # <old shared guest ro sealed smbname> then <new …>
    local os="$1" og="$2" oro="$3" ose="$4" osn="$5"
    local ns="$6" ng="$7" nro="$8" nse="$9" nsn="${10}" _f=""
    if [ "$os" != "$ns" ];   then _f="$_f -s 00$ns"; fi
    if [ "$og" != "$ng" ];   then _f="$_f -g 00$ng"; fi
    if [ "$oro" != "$nro" ]; then _f="$_f -R $nro"; fi
    if [ "$ose" != "$nse" ]; then _f="$_f -E $nse"; fi
    if [ "$osn" != "$nsn" ]; then _f="$_f -S \"$(_escape_dq "$nsn")\""; fi
    printf '%s' "${_f# }"
  }
  _onchange_sharepoints() {
    local _snap="$1" _curr="$2"
    local n p sh gu ro se sn old
    while IFS=$'\t' read -r n p sh gu ro se sn; do
      [ -n "$n" ] || continue
      old=$(/usr/bin/awk -F'\t' -v k="$n" '$1==k{print; exit}' "$_snap" 2>/dev/null)
      if [ -z "$old" ]; then
        log_line "Cmd: # File Sharing: share point added. $n"
        log_line "Cmd: sudo /usr/sbin/sharing -a \"$(_escape_dq "$p")\" -n \"$(_escape_dq "$n")\" $(_sp_flags_add "$sh" "$gu" "$ro" "$se" "$sn")"
        if [ -z "${_SP_PATH_NOTED:-}" ]; then
          log_line "Cmd: # NOTE: the shared folder must already exist on the target. Sharing -a does not create it"
          typeset -g _SP_PATH_NOTED=1
        fi
      elif [ "$old" != "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$n" "$p" "$sh" "$gu" "$ro" "$se" "$sn")" ]; then
        local _on _op _osh _ogu _oro _ose _osn _ef
        IFS=$'\t' read -r _on _op _osh _ogu _oro _ose _osn <<< "$old"
        if [ "$_op" != "$p" ]; then
          # The folder moved: `sharing -e` cannot say that, so remove + create.
          log_line "Cmd: # File Sharing: share point now points elsewhere. $n"
          log_line "Cmd: sudo /usr/sbin/sharing -r \"$(_escape_dq "$n")\""
          log_line "Cmd: sudo /usr/sbin/sharing -a \"$(_escape_dq "$p")\" -n \"$(_escape_dq "$n")\" $(_sp_flags_add "$sh" "$gu" "$ro" "$se" "$sn")"
        else
          _ef=$(_sp_flags_edit "$_osh" "$_ogu" "$_oro" "$_ose" "$_osn" "$sh" "$gu" "$ro" "$se" "$sn")
          if [ -n "$_ef" ]; then
            log_line "Cmd: # File Sharing: share point changed. $n"
            log_line "Cmd: sudo /usr/sbin/sharing -e \"$(_escape_dq "$n")\" $_ef"
          fi
        fi
      fi
    done < "$_curr"
    while IFS=$'\t' read -r n p sh gu ro se sn; do
      [ -n "$n" ] || continue
      /usr/bin/awk -F'\t' -v k="$n" '$1==k{f=1} END{exit !f}' "$_curr" 2>/dev/null && continue
      log_line "Cmd: # File Sharing: share point removed. $n"
      log_line "Cmd: sudo /usr/sbin/sharing -r \"$(_escape_dq "$n")\""
    done < "$_snap"
    return 0
  }
  _snapshot_watch sharepoints 2 _read_sharepoints _onchange_sharepoints
}

# Bluetooth on/off writes no watched plist: poll `system_profiler
# SPBluetoothDataType` (moves within 1 s). Not `BlueTool -c power` (reads the
# power rail). No `defaults` reproduces it; the emitted line calls the public
# IOBluetoothPreferenceSetControllerPowerState via ctypes (survives a reboot).
bluetooth_watch() {
  [ -x /usr/sbin/system_profiler ] || return 0
  _read_bluetooth() {
    /usr/sbin/system_profiler SPBluetoothDataType 2>/dev/null \
      | /usr/bin/awk -F': *' '/State:/{print $2; exit}'
  }
  _onchange_bluetooth() {
    local _st _flag
    _st=$(/usr/bin/head -1 "$2" 2>/dev/null)
    case "$_st" in
      On)  _flag=1 ;;
      Off) _flag=0 ;;
      *)   return 0 ;;   # anything else is a failed read, not a change
    esac
    # Dedup keyed on the STATE: an off-then-on burst must not end on "Off".
    _note_should_show "__bluetooth__:$_st" || return 0
    # Single-quoted source so its double quotes survive into the log line.
    local _py='import ctypes; ctypes.cdll.LoadLibrary("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth").IOBluetoothPreferenceSetControllerPowerState('
    local _cmd="/usr/bin/python3 -c '${_py}${_flag})'"
    # blueutil first (runs on any Mac); the python3 line needs the CLT on the
    # target, where a bare /usr/bin/python3 only offers to install them.
    log_line "Cmd: # NOTE: Bluetooth turned $_st. Needs blueutil (github.com/toy/blueutil)"
    log_line "Cmd: blueutil -p $_flag"
    # Never deduplicated: the python3 line needs its intro.
    log_line "Cmd: #       Or, without blueutil, on a target that has the Command Line Tools:"
    log_line "Cmd: $_cmd"
    return 0
  }
  _snapshot_watch bluetooth 2 _read_bluetooth _onchange_bluetooth _guard_nonempty
}

# Local accounts (UID >= 501) live in OpenDirectory: a NOTE only. The
# deletedUsers churn is filtered so this is the single source.
useracct_watch() {
  _read_useracct() {
    /usr/bin/dscl . -list /Users UniqueID 2>/dev/null | /usr/bin/awk '$2 >= 501 {print $1}' | /usr/bin/sort || true
  }
  _onchange_useracct() {
    local _snap="$1" _curr="$2" u
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      _log_note_wrapped "" "user account '$u' added. The account itself (UID/home/password) is NOT reproducible via defaults; use sysadminctl/dscl or a config profile"
    done < <(/usr/bin/comm -13 "$_snap" "$_curr" 2>/dev/null)
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      log_line "Cmd: # NOTE: user account '$u' removed. Not reproducible via defaults; use sysadminctl/dscl"
    done < <(/usr/bin/comm -23 "$_snap" "$_curr" 2>/dev/null)
    return 0
  }
  # A failed dscl read must not report every user as removed.
  _snapshot_watch useracct 2 _read_useracct _onchange_useracct _guard_nonempty
}

# Hostnames: the configd file is unreliable to Set; emit `scutil --set`.
hostname_watch() {
  [ -x /usr/sbin/scutil ] || return 0
  _read_hostname() {
    local n v
    for n in LocalHostName ComputerName HostName; do
      v=$(/usr/sbin/scutil --get "$n" 2>/dev/null) || v=""
      printf '%s\t%s\n' "$n" "$v"
    done
  }
  # LocalHostName empty = scutil hiccup: skip.
  _guard_hostname() { /usr/bin/awk -F'\t' '$1=="LocalHostName" && $2!=""{ok=1} END{exit !ok}' "$1" 2>/dev/null; }
  _onchange_hostname() {
    local _snap="$1" _curr="$2" _n _oldv _newv
    while IFS=$'\t' read -r _n _newv; do
      [ -n "$_n" ] || continue
      _oldv=$(/usr/bin/awk -F'\t' -v k="$_n" '$1==k{print $2}' "$_snap" 2>/dev/null)
      [ "$_oldv" = "$_newv" ] && continue
      [ -n "$_newv" ] && log_line "Cmd: sudo /usr/sbin/scutil --set $_n \"$(_escape_dq "$_newv")\""
    done < "$_curr"
    return 0
  }
  _snapshot_watch hostname 2 _read_hostname _onchange_hostname _guard_hostname
}

# Default apps: launchservices.secure.plist is excluded; diff LSHandlers and
# emit `utiluti`, which sets the real default.
default_apps_watch() {
  [ -n "$PYTHON3_BIN" ] || return 0
  local secure="$TARGET_HOME/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist"
  _read_defapps() {
    [ -f "$secure" ] || return 0
    "$PYTHON3_BIN" - "$secure" <<'PY'
import sys, plistlib
try:
    with open(sys.argv[1], 'rb') as f: d = plistlib.load(f)
except Exception:
    sys.exit(0)
# http/https/public.html/web-browser are linked: one canonical "url http".
BROWSER_SCHEMES = {"http", "https"}
BROWSER_TYPES = {"public.html", "com.apple.default-app.web-browser"}
seen = set(); rows = []
for e in d.get("LSHandlers", []):
    app = e.get("LSHandlerRoleAll") or e.get("LSHandlerRoleViewer") or e.get("LSHandlerRoleEditor")
    if not app: continue
    scheme = e.get("LSHandlerURLScheme"); ctype = e.get("LSHandlerContentType")
    if scheme in BROWSER_SCHEMES or ctype in BROWSER_TYPES:
        key = "url\thttp"
    elif scheme:
        key = "url\t" + scheme
    elif ctype:
        key = "type\t" + ctype
    else:
        continue
    if key in seen: continue
    seen.add(key); rows.append(key + "\t" + app)
for r in sorted(rows): print(r)
PY
  }
  # New or re-pointed only; a removal is not a `set`.
  _onchange_defapps() {
    local _snap="$1" _curr="$2" _kind _what _app
    while IFS=$'\t' read -r _kind _what _app; do
      [ -n "$_kind" ] || continue
      _note_should_show __default_apps__ && log_line "Cmd: # NOTE: needs utiluti (github.com/scriptingosx/utiluti)"
      # Only the default browser pops a macOS confirmation.
      [ "$_kind" = url ] && [ "$_what" = http ] && _note_should_show __default_browser__ \
        && log_line "Cmd: # NOTE: changing the default browser prompts the user to confirm"
      # Both fields are user-writable: escaped. --mdm wraps it (per-user state).
      local _uu="utiluti $_kind set \"$(_escape_dq "$_what")\" \"$(_escape_dq "$_app")\""
      log_line "Cmd: $(_mdm_wrap "$_uu")"
    done < <(/usr/bin/comm -13 "$_snap" "$_curr" 2>/dev/null)
    return 0
  }
  # 1s: a discrete action the admin is watching for.
  _snapshot_watch default_apps 1 _read_defapps _onchange_defapps _guard_nonempty
}

# Wallpaper lives in the com.apple.wallpaper Store (Index.plist): reproducible
# with desktoppr. A dynamic wallpaper has no file; the NOTE says so.
wallpaper_watch() {
  [ -n "$PYTHON3_BIN" ] || return 0
  local index="$TARGET_HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
  _read_wallpaper() {
    [ -f "$index" ] || return 0
    "$PYTHON3_BIN" - "$index" <<'PY'
import sys, plistlib
try:
    with open(sys.argv[1], 'rb') as f: d = plistlib.load(f)
except Exception:
    sys.exit(0)
# Without LastSet/LastUse: rewritten on login with no real change.
def clean(o):
    if isinstance(o, dict):
        return {k: clean(v) for k, v in sorted(o.items()) if k not in ("LastSet", "LastUse")}
    if isinstance(o, list):
        return [clean(x) for x in o]
    if isinstance(o, bytes):
        return o.hex()
    return str(o)
print(clean(d))
PY
  }
  # `<kind>\t<location>\t<value>`: I image (`desktoppr "<path>"`), C the colour
  # BEHIND it (`desktoppr color <hex>`), N a solid system colour (a name only).
  # Lines, not values: disconnected displays keep old rows. SystemDefault skipped.
  # C is never the picked solid colour (measured), so never emitted as one.
  _wallpaper_paths() {
    [ -f "$index" ] || return 0
    "$PYTHON3_BIN" - "$index" <<'WP'
import plistlib, sys, urllib.parse
try:
    with open(sys.argv[1], 'rb') as handle:
        store = plistlib.load(handle)
except Exception:
    sys.exit(0)

rows = []

def hexcolor(components):
    try:
        r, g, b = (max(0, min(255, round(float(c) * 255))) for c in components[:3])
    except Exception:
        return ''
    return '%02X%02X%02X' % (r, g, b)

def option_color(encoded):
    try:
        node = plistlib.loads(encoded)['values']['color']
        while isinstance(node, dict) and 'components' not in node:
            node = next(iter(node.values()))
        return hexcolor(node['components'])
    except Exception:
        return ''

def walk(node, where, desktop=False, default=False):
    if not isinstance(node, dict):
        if isinstance(node, list):
            for i, item in enumerate(node):
                walk(item, '%s[%d]' % (where, i), desktop, default)
        return
    for key, value in node.items():
        spot = where + '/' + str(key)
        if key == 'Configuration' and isinstance(value, bytes) and value:
            if not desktop or default:
                continue
            try:
                inner = plistlib.loads(value)
            except Exception:
                continue
            url = (inner.get('url') or {}).get('relative') or ''
            if url.startswith('file://'):
                rows.append(('I', where, urllib.parse.unquote(url[len('file://'):])))
            elif inner.get('type') == 'systemColor':
                names = list((inner.get('systemColor') or {}).keys())
                rows.append(('N', where, names[0] if names else '?'))
        elif key == 'EncodedOptionValues' and isinstance(value, bytes) and value:
            if not desktop or default:
                continue
            hexv = option_color(value)
            if hexv:
                rows.append(('C', where, hexv))
        else:
            walk(value, spot, desktop or key == 'Desktop', default or key == 'SystemDefault')

walk(store, '')
for kind, where, value in rows:
    print('%s\t%s\t%s' % (kind, where, value))
WP
  }
  _wp_paths="$PREFWATCH_TMPDIR/wallpaper.paths"
  _wallpaper_paths | /usr/bin/sort -u > "$_wp_paths" 2>/dev/null || : > "$_wp_paths"
  # `cut -f3-`: a path may contain a tab.
  _wp_changed() { printf '%s\n' "$2" | /usr/bin/grep "^$1	" 2>/dev/null | /usr/bin/cut -f3- | /usr/bin/sort -u || true; }
  _onchange_wallpaper() {
    local _curr="$PREFWATCH_TMPDIR/wallpaper.paths.curr" _new _img _col _nam _ni _nc _p _head=false
    _wallpaper_paths | /usr/bin/sort -u > "$_curr" 2>/dev/null || : > "$_curr"
    _new=$(/usr/bin/comm -13 "$_wp_paths" "$_curr" 2>/dev/null) || _new=""
    # Rows under a NEW key (a Space, a display) carry the existing wallpaper: only
    # keys the baseline had count, including a row that vanished. Files by FILENAME
    # (NR==FNR swallows stdin when the first file is empty).
    local _gone _wp_known
    _wp_known='function key(p){ sub(/\/Desktop\/.*/, "", p); return p } FILENAME==P{ w[key($2)]=1; next } key($2) in w'
    _gone=$(/usr/bin/comm -23 "$_wp_paths" "$_curr" 2>/dev/null) || _gone=""
    _new=$(printf '%s\n' "$_new" | /usr/bin/awk -F'\t' -v P="$_wp_paths" "$_wp_known" "$_wp_paths" -) || _new=""
    _gone=$(printf '%s\n' "$_gone" | /usr/bin/awk -F'\t' -v P="$_curr" "$_wp_known" "$_curr" -) || _gone=""
    /bin/mv -f "$_curr" "$_wp_paths" 2>/dev/null || true
    [ -z "$_new" ] && [ -z "$_gone" ] && return 0
    # Switching TO a dynamic wallpaper only removes lines: still a NOTE.
    _img=$(_wp_changed I "$_new"); _col=$(_wp_changed C "$_new"); _nam=$(_wp_changed N "$_new")
    _ni=0; [ -n "$_img" ] && _ni=$(printf '%s\n' "$_img" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    _nc=0; [ -n "$_col" ] && _nc=$(printf '%s\n' "$_col" | /usr/bin/wc -l | /usr/bin/tr -d ' ')

    # Same dedup key as _note_desktoppr (separate processes).
    if [ "$_ni" = "1" ] && _note_should_show "__desktoppr__:$_img"; then
      _note_desktoppr_head; _head=true
      log_line "Cmd: $(_mdm_wrap "desktoppr \"$(_escape_dq "$_img")\"")"
    fi
    if [ "$_nc" = "1" ] && _note_should_show "__wpcolor__:$_col"; then
      [ "$_head" = "true" ] || { _note_desktoppr_head; _head=true; }
      log_line "Cmd: $(_mdm_wrap "desktoppr color $_col")"
    fi
    [ "$_head" = "true" ] && return 0

    _note_should_show __wallpaper__ || return 0
    if [ "$_ni" -gt 1 ] || [ "$_nc" -gt 1 ]; then
      # desktoppr addresses a screen by the screen index of this Mac: not deployable.
      _log_note_wrapped "" "desktop wallpaper changed. The screens did not all get the same thing, so no single command reproduces it. Deploy per screen with desktoppr (github.com/scriptingosx/desktoppr):"
      printf '%s\n' "$_img" | while IFS= read -r _p; do
        [ -n "$_p" ] && log_line "Cmd: #       desktoppr <screen> \"$(_escape_dq "$_p")\""
      done
      printf '%s\n' "$_col" | while IFS= read -r _p; do
        [ -n "$_p" ] && log_line "Cmd: #       desktoppr <screen> color $_p"
      done
    elif [ -n "$_nam" ]; then
      # desktoppr takes only hex; the Store records only the colour NAME.
      _log_note_wrapped "" "desktop wallpaper set to the solid system colour '$(printf '%s' "$_nam" | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')'. The Store records the name, not the shade, so the exact colour is not recoverable. desktoppr takes a hex value: desktoppr color <RRGGBB>"
    else
      _log_note_wrapped "" "desktop wallpaper changed, but no image or colour moved in the Store. A dynamic wallpaper, which neither defaults nor desktoppr reproduces; set it in System Settings > Wallpaper"
    fi
    return 0
  }
  _snapshot_watch wallpaper 2 _read_wallpaper _onchange_wallpaper _guard_nonempty
}

# Privacy permissions live in two SQLite databases. With Full Disk Access the
# change is named; without it mtime/size still move. Never a command (PPPC).
tcc_watch() {
  [ -x /usr/bin/sqlite3 ] || return 0
  local _tcc_sys="/Library/Application Support/com.apple.TCC/TCC.db"
  local _tcc_usr="$TARGET_HOME/Library/Application Support/com.apple.TCC/TCC.db"
  # macOS 27: the user database moved into a ProtectedSystem container. tccd
  # holds it open, so `lsof -p` names it (0.09s). stat works, the SQL read is
  # refused even with FDA (27.0): "changed", never which permission.
  if [ ! -f "$_tcc_usr" ]; then
    local _tcc_uid="" _tcc_pids="" _tcc_pid="" _tcc_found=""
    _tcc_uid=$(/usr/bin/id -u "${CONSOLE_USER:-$(/usr/bin/id -un)}" 2>/dev/null) || _tcc_uid=""
    if [ -n "$_tcc_uid" ]; then
      _tcc_pids=$(/usr/bin/pgrep -u "$_tcc_uid" -x tccd 2>/dev/null) || _tcc_pids=""
      for _tcc_pid in ${=_tcc_pids}; do
        # The NAME column holds spaces: anchor on the end of the path.
        _tcc_found=$(/usr/sbin/lsof -p "$_tcc_pid" 2>/dev/null \
          | /usr/bin/sed -nE 's#^.* (/.*/com\.apple\.TCC/TCC\.db)$#\1#p' \
          | /usr/bin/head -1) || _tcc_found=""
        [ -n "$_tcc_found" ] && break
      done
    fi
    if [ -n "$_tcc_found" ] && [ -f "$_tcc_found" ]; then
      _tcc_usr="$_tcc_found"
    else
      # Say so rather than watch half the surface quietly.
      log_line "Cmd: # NOTE: per-user TCC database not found (~/Library, tccd container). Only SYSTEM privacy permissions are watched"
    fi
  fi
  _read_tcc() {
    local _scope _db
    for _scope in system user; do
      [ "$_scope" = system ] && _db="$_tcc_sys" || _db="$_tcc_usr"
      [ -f "$_db" ] || continue
      # -readonly: never block tccd. Captured, not piped: a refused read must
      # not look like an empty success.
      local _rows=""
      if _rows=$(/usr/bin/sqlite3 -readonly -separator $'\t' "$_db" \
                   "select service, client, auth_value from access;" 2>/dev/null); then
        [ -n "$_rows" ] && printf '%s\n' "$_rows" | /usr/bin/sed "s/^/${_scope}\t/"
      else
        # No FDA: fall back to the file metadata.
        local _st=""
        _st=$(/usr/bin/stat -f '%m %z' "$_db" 2>/dev/null) || _st=""
        printf '%s\tUNREADABLE\t%s\n' "$_scope" "$_st"
      fi
    done
  }
  _onchange_tcc() {
    local _snap="$1" _curr="$2" _added _removed _scope _svc _cli _val _key _label
    _added=$(/usr/bin/comm -13 <(/usr/bin/sort "$_snap") <(/usr/bin/sort "$_curr") 2>/dev/null) || _added=""
    _removed=$(/usr/bin/comm -23 <(/usr/bin/sort "$_snap") <(/usr/bin/sort "$_curr") 2>/dev/null) || _removed=""
    _note_should_show __tcc__ || return 0
    _log_note_wrapped "" "privacy permission changed (System Settings > Privacy & Security). NOT reproducible by command: tccutil only RESETS a grant, it cannot create one. Deploy it as a PPPC (Privacy Preferences Policy Control) configuration profile."
    if printf '%s\n' "$_added$_removed" | /usr/bin/grep -q 'UNREADABLE'; then
      # On 27 granting FDA changes nothing: do not send the reader there.
      if printf '%s\n' "$_added$_removed" | /usr/bin/grep -q '^user.UNREADABLE' \
         && [ -n "${_tcc_usr:-}" ] && [ "${_tcc_usr#/private/var/containers/}" != "$_tcc_usr" ]; then
        log_line "Cmd: #       Which permission moved is not visible here. This macOS keeps the per-user TCC.db where no process may read."
      else
        log_line "Cmd: #       Which permission moved is not visible here. Reading TCC.db needs Full Disk Access."
      fi
      return 0
    fi

    # A CHANGED permission prints as one "before → after" line. Here-strings, not
    # a pipe (subshell). $'\t' does not expand in a subscript: separator built once.
    local -A _was _now
    local _T=$'\t'
    _label() {
      case "$1" in
        0) print -r -- "denied" ;;
        2) print -r -- "allowed" ;;
        *) print -r -- "auth_value $1" ;;
      esac
    }
    if [ -n "$_removed" ]; then
      while IFS=$'\t' read -r _scope _svc _cli _val; do
        [ -n "$_svc" ] && [ "$_svc" != "UNREADABLE" ] || continue
        _key="${_scope}${_T}${_svc}${_T}${_cli}"; _was[$_key]="$_val"
      done <<< "$_removed"
    fi
    if [ -n "$_added" ]; then
      while IFS=$'\t' read -r _scope _svc _cli _val; do
        [ -n "$_svc" ] && [ "$_svc" != "UNREADABLE" ] || continue
        _key="${_scope}${_T}${_svc}${_T}${_cli}"; _now[$_key]="$_val"
      done <<< "$_added"
    fi
    for _key in ${(k)_now}; do
      _scope="${_key%%${_T}*}"; _svc="${${_key#*${_T}}%%${_T}*}"; _cli="${_key##*${_T}}"
      if [ -n "${_was[$_key]+set}" ]; then
        log_line "Cmd: #       ${_scope}  ${_svc#kTCCService}  ${_cli}  $(_label "${_was[$_key]}") → $(_label "${_now[$_key]}")"
        unset "_was[$_key]"
      else
        log_line "Cmd: #       + ${_scope}  ${_svc#kTCCService}  ${_cli}  $(_label "${_now[$_key]}")"
      fi
    done
    for _key in ${(k)_was}; do
      _scope="${_key%%${_T}*}"; _svc="${${_key#*${_T}}%%${_T}*}"; _cli="${_key##*${_T}}"
      log_line "Cmd: #       - ${_scope}  ${_svc#kTCCService}  ${_cli}  $(_label "${_was[$_key]}")"
    done
    return 0
  }
  _snapshot_watch tcc 3 _read_tcc _onchange_tcc _guard_nonempty
}

# Startup sound and volume live in NVRAM; `nvram` accepts back its own %xx output.
nvram_watch() {
  [ -x /usr/sbin/nvram ] || return 0
  _read_nvram() {
    local _k _v
    for _k in StartupMute SystemAudioVolume; do
      _v=$(/usr/sbin/nvram "$_k" 2>/dev/null) || continue
      printf '%s\n' "${_v}"
    done
  }
  _onchange_nvram() {
    local _snap="$1" _curr="$2" _k _v _old
    while IFS=$'\t' read -r _k _v; do
      [ -n "$_k" ] || continue
      _old=$(/usr/bin/awk -F'\t' -v k="$_k" '$1==k{print $2}' "$_snap" 2>/dev/null)
      [ "$_old" = "$_v" ] && continue
      case "$_k" in
        StartupMute)
          log_line "Cmd: # NOTE: startup sound changed (Settings > Sound). It lives in NVRAM, not a plist." ;;
      esac
      log_line "Cmd: sudo /usr/sbin/nvram ${_k}=$(_escape_dq "$_v")"
    done < "$_curr"
    return 0
  }
  _snapshot_watch nvram 3 _read_nvram _onchange_nvram
}

# Time zone = the /etc/localtime symlink: poll it, emit `systemsetup -settimezone`.
timezone_watch() {
  [ -L /etc/localtime ] || return 0
  _read_tz() {
    local t; t=$(/usr/bin/readlink /etc/localtime 2>/dev/null) || return 0
    printf '%s' "${t#*/zoneinfo/}"      # /var/db/timezone/zoneinfo/Europe/Paris → Europe/Paris
  }
  # NTP server from /etc/ntp.conf (readable without root).
  _read_ntp() { /usr/bin/awk '/^server /{print $2; exit}' /etc/ntp.conf 2>/dev/null || true; }
  _read_timezone() { printf 'tz\t%s\nntp\t%s\n' "$(_read_tz)" "$(_read_ntp)"; }
  # Empty tz = transient readlink failure: skip.
  _guard_timezone() { /usr/bin/awk -F'\t' '$1=="tz" && $2!=""{ok=1} END{exit !ok}' "$1" 2>/dev/null; }
  _onchange_timezone() {
    local _snap="$1" _curr="$2" _k _v _oldv
    while IFS=$'\t' read -r _k _v; do
      [ -n "$_k" ] || continue
      [ -n "$_v" ] || continue
      _oldv=$(/usr/bin/awk -F'\t' -v k="$_k" '$1==k{print $2}' "$_snap" 2>/dev/null)
      [ "$_oldv" = "$_v" ] && continue
      case "$_k" in
        tz)
          # Automatic time zone can overwrite a manual set.
          [ "$(defaults read /Library/Preferences/com.apple.timezone.auto Active 2>/dev/null)" = "1" ] \
            && _log_note_wrapped "" "'Set time zone automatically' is ON (com.apple.timezone.auto). It can override a manual set; turn it off first (Settings > Date & Time)"
          log_line "Cmd: sudo /usr/sbin/systemsetup -settimezone \"$_v\"" ;;
        ntp)
          log_line "Cmd: sudo /usr/sbin/systemsetup -setnetworktimeserver \"$_v\"" ;;
      esac
    done < "$_curr"
    return 0
  }
  _snapshot_watch timezone 2 _read_timezone _onchange_timezone _guard_timezone
}

# FileVault, Gatekeeper, firewall live outside plists; all read without root.
# Emit the command, or a NOTE where none reproduces it.
security_watch() {
  local sfw=/usr/libexec/ApplicationFirewall/socketfilterfw
  _read_security() {
    local fv sip gk gkdev _gkv fw fws fwb fwsig
    # `|| true` INSIDE each $(): a grep with no match would abort under pipefail.
    fv=$(/usr/bin/fdesetup status 2>/dev/null | /usr/bin/grep -oE 'is (On|Off)' | /usr/bin/head -1 || true)
    # SIP: reported, never emitted (changing it takes Recovery).
    sip=$(/usr/bin/csrutil status 2>/dev/null | /usr/bin/grep -oE '(enabled|disabled)' | /usr/bin/head -1 || true)
    # `--verbose` adds "developer id <state>", the App Store-only sub-mode.
    _gkv=$(/usr/sbin/spctl --status --verbose 2>&1 || true)
    gk=$(printf '%s\n' "$_gkv" | /usr/bin/grep -oE 'assessments (enabled|disabled)' | /usr/bin/grep -oE '(enabled|disabled)' | /usr/bin/head -1 || true)
    gkdev=$(printf '%s\n' "$_gkv" | /usr/bin/grep -oE 'developer id (enabled|disabled)' | /usr/bin/grep -oE '(enabled|disabled)' | /usr/bin/head -1 || true)
    if [ -x "$sfw" ]; then
      fw=$("$sfw" --getglobalstate 2>/dev/null  | /usr/bin/grep -oE 'State = [0-9]' | /usr/bin/head -1 || true)
      fws=$("$sfw" --getstealthmode 2>/dev/null | /usr/bin/grep -oE '(on|off)' | /usr/bin/head -1 || true)
      fwb=$("$sfw" --getblockall 2>/dev/null    | /usr/bin/grep -oE '(enabled|disabled)' | /usr/bin/head -1 || true)
      fwsig=$("$sfw" --getallowsigned 2>/dev/null | /usr/bin/grep -oE '(ENABLED|DISABLED)' | /usr/bin/paste -sd, - || true)
    fi
    printf 'filevault\t%s\nsip\t%s\ngatekeeper\t%s\ngatekeeper-devid\t%s\nfirewall\t%s\nfw-stealth\t%s\nfw-blockall\t%s\nfw-signed\t%s\n' \
      "$fv" "$sip" "$gk" "$gkdev" "$fw" "$fws" "$fwb" "$fwsig"
  }
  _guard_security() { /usr/bin/awk -F'\t' '$1=="gatekeeper" && $2!=""{ok=1} END{exit !ok}' "$1" 2>/dev/null; }
  _onchange_security() {
    local _snap="$1" _curr="$2" _k _v _oldv
    while IFS=$'\t' read -r _k _v; do
        [ -n "$_k" ] || continue
        _oldv=$(/usr/bin/awk -F'\t' -v k="$_k" '$1==k{print $2}' "$_snap" 2>/dev/null)
        [ "$_oldv" = "$_v" ] && continue
        [ -n "$_v" ] || continue
        case "$_k" in
          sip)
            log_line "Cmd: # NOTE: System Integrity Protection is now $_v. It cannot be changed from a"
            log_line "Cmd: #       booted Mac, only from Recovery (Startup Security Utility, or csrutil there),"
            log_line "Cmd: #       so no command reproduces it. On a managed fleet, disabled SIP is a finding." ;;
          filevault)
            _log_note_wrapped "" "FileVault is now ${_v#is }. Not reproducible by one command; enable needs a recovery key (sudo fdesetup enable) or an MDM/config profile" ;;
          # `--master-*` are undocumented aliases on 26.6.2. `--global-enable` is
          # the documented enable; `--global-disable` is NOT its counterpart, so
          # disable keeps the old verb.
          gatekeeper)
            if [ "$_v" = enabled ]; then
              log_line "Cmd: sudo /usr/sbin/spctl --global-enable"
            else
              log_line "Cmd: sudo /usr/sbin/spctl --master-disable"
              log_line "Cmd: # NOTE: --master-disable is undocumented since macOS 26 (gone from --help and the man"
              log_line "Cmd: #       page) and may stop working. --global-disable is NOT a replacement: it only"
              log_line "Cmd: #       reveals the 'anywhere' option in the settings pane."
              log_line "Cmd: # NOTE: on macOS 15+ disabling Gatekeeper also needs confirming in Settings > Privacy & Security"
            fi ;;
          gatekeeper-devid)
            # No single spctl command sets the sub-mode.
            if [ "$_v" = disabled ]; then
              _log_note_wrapped "" "Gatekeeper set to 'App Store' only (identified developers disabled). No single spctl command reproduces this; set it in System Settings > Privacy & Security, or via an MDM Gatekeeper config profile"
            else
              _log_note_wrapped "" "Gatekeeper now allows 'App Store and identified developers'. Set in System Settings > Privacy & Security or an MDM config profile (no single spctl command)"
            fi ;;
          firewall)
            case "$_v" in
              *0) log_line "Cmd: sudo $sfw --setglobalstate off" ;;
              *1) log_line "Cmd: sudo $sfw --setglobalstate on" ;;
              *2) log_line "Cmd: sudo $sfw --setglobalstate on"; log_line "Cmd: sudo $sfw --setblockall on" ;;
            esac ;;
          fw-stealth)
            [ "$_v" = on ] && log_line "Cmd: sudo $sfw --setstealthmode on" || log_line "Cmd: sudo $sfw --setstealthmode off" ;;
          fw-blockall)
            [ "$_v" = enabled ] && log_line "Cmd: sudo $sfw --setblockall on" || log_line "Cmd: sudo $sfw --setblockall off" ;;
          fw-signed)
            [ "${_v%%,*}" = ENABLED ] && log_line "Cmd: sudo $sfw --setallowsigned on" || log_line "Cmd: sudo $sfw --setallowsigned off"
            [ "${_v#*,}" = ENABLED ] && log_line "Cmd: sudo $sfw --setallowsignedapp on" || log_line "Cmd: sudo $sfw --setallowsignedapp off" ;;
        esac
    done < "$_curr"
    return 0
  }
  _snapshot_watch security 3 _read_security _onchange_security _guard_security
}

# Per-app firewall rules: poll `socketfilterfw --listapps`, emit --add and
# --blockapp/--unblockapp, or --remove.
fw_apps_watch() {
  local sfw=/usr/libexec/ApplicationFirewall/socketfilterfw
  [ -x "$sfw" ] || return 0
  # "N : /path" + next line → "path<TAB>allow|block", sorted.
  _read_fwapps() {
    "$sfw" --listapps 2>/dev/null | /usr/bin/awk '
      /^[0-9]+ : \// { path=$0; sub(/^[0-9]+ : /,"",path); sub(/[[:space:]]+$/,"",path); next }
      /incoming connections/ { st=(/Block/)?"block":"allow"; if(path!="") print path "\t" st; path="" }
    ' | /usr/bin/sort || true
  }
  _onchange_fwapps() {
    local _snap="$1" _curr="$2" _path _state _oldstate
    while IFS=$'\t' read -r _path _state; do
      [ -n "$_path" ] || continue
      _oldstate=$(/usr/bin/awk -F'\t' -v p="$_path" '$1==p{print $2}' "$_snap" 2>/dev/null)
      [ "$_oldstate" = "$_state" ] && continue
      _note_should_show __fw_apps__ && log_line "Cmd: # NOTE: per-app firewall rule (Firewall > Options)"
      # The path is user-chosen and pasted as root: escaped.
      local _pq; _pq=$(_escape_dq "$_path")
      if [ -z "$_oldstate" ]; then log_line "Cmd: sudo $sfw --add \"$_pq\""; fi
      [ "$_state" = block ] && log_line "Cmd: sudo $sfw --blockapp \"$_pq\"" || log_line "Cmd: sudo $sfw --unblockapp \"$_pq\""
    done < "$_curr"
    while IFS=$'\t' read -r _path _state; do
      [ -n "$_path" ] || continue
      /usr/bin/awk -F'\t' -v p="$_path" '$1==p{f=1} END{exit !f}' "$_curr" 2>/dev/null && continue
      _note_should_show __fw_apps__ && log_line "Cmd: # NOTE: per-app firewall rule removed (Firewall > Options)"
      log_line "Cmd: sudo $sfw --remove \"$(_escape_dq "$_path")\""
    done < "$_snap"
    return 0
  }
  _snapshot_watch fw_apps 3 _read_fwapps _onchange_fwapps _guard_nonempty
}

# Touch ID via `bioutil`: `-r` reads the user scope (through RUN_AS_USER),
# `-r -s` the machine scope. "Effective biometrics" (the AND of both) is dropped.
# Labels are English on a French system (26.6.2), so keying on them is safe.
touchid_watch() {
  [ -x /usr/bin/bioutil ] || return 0
  _read_touchid() {
    local _scope
    for _scope in user system; do
      if [ "$_scope" = system ]; then
        /usr/bin/bioutil -r -s 2>/dev/null
      else
        "${RUN_AS_USER[@]}" /usr/bin/bioutil -r 2>/dev/null
      fi | /usr/bin/awk -v sc="$_scope" -F': *' '
        /^[[:space:]]+Effective/ { next }
        /^[[:space:]]+[A-Z].*: *[0-9]+[[:space:]]*$/ {
          key = $1; sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key)
          val = $2; sub(/[[:space:]]+$/, "", val)
          print sc "\t" key "\t" val
        }'
    done
  }
  # No system line = failed read: keep the last baseline.
  _guard_touchid() { /usr/bin/awk -F'\t' '$1=="system"{ok=1} END{exit !ok}' "$1" 2>/dev/null; }
  _onchange_touchid() {
    local _snap="$1" _curr="$2" _scope _key _val _old _cmd
    while IFS=$'\t' read -r _scope _key _val; do
      [ -n "$_key" ] || continue
      _old=$(/usr/bin/awk -F'\t' -v s="$_scope" -v k="$_key" '$1==s && $2==k{print $3}' "$_snap" 2>/dev/null)
      [ "$_old" = "$_val" ] && continue
      _cmd=""
      if [ "$_scope" = user ]; then
        case "$_key" in
          "Biometrics for unlock")   _cmd="/usr/bin/bioutil -w -u $_val" ;;
          "Biometrics for ApplePay") _cmd="/usr/bin/bioutil -w -a $_val" ;;
        esac
        # Per-user scope: wrapped like a user `defaults`. -a is user-scope only.
        if [ -n "$_cmd" ]; then
          log_line "Cmd: $(_mdm_wrap "$_cmd")"
          # A user-scope write always asks the password on stdin (26.6.2), and waits.
          _note_should_show __touchid_prompt__ \
            && log_line "Cmd: #       (asks the user for their password on stdin, so it cannot be deployed unattended)"
        fi
      else
        case "$_key" in
          "Biometrics functionality")          _cmd="/usr/bin/bioutil -w -s -f $_val" ;;
          "Biometrics for unlock")             _cmd="/usr/bin/bioutil -w -s -u $_val" ;;
          "Biometric timeout (in seconds)")    _cmd="/usr/bin/bioutil -w -s --btimeout $_val" ;;
          "Match timeout (in seconds)")        _cmd="/usr/bin/bioutil -w -s --mtimeout $_val" ;;
          "Passcode input timeout (in seconds)") _cmd="/usr/bin/bioutil -w -s --ptimeout $_val" ;;
        esac
        [ -n "$_cmd" ] && log_line "Cmd: sudo $_cmd"
      fi
      # An unknown label is reported, never guessed into a command.
      if [ -z "$_cmd" ] && _note_should_show "__touchid_label__:$_scope:$_key"; then
        log_line "Cmd: # NOTE: Touch ID ($_scope) '$_key' is now $_val. Bioutil has no write verb for it"
      fi
    done < "$_curr"
    return 0
  }
  _snapshot_watch touchid 3 _read_touchid _onchange_touchid _guard_touchid
}

# Default printer, from the lpoptions file: `lpstat -d` is localised even under
# LC_ALL=C. The emitted `lpoptions -d` is per-user, so wrapped for --mdm.
defprinter_watch() {
  [ -x /usr/bin/lpoptions ] || return 0
  _read_defprinter() {
    local _f _name=""
    # Per-user first: it wins for the logged-in user.
    for _f in "$TARGET_HOME/.cups/lpoptions" /etc/cups/lpoptions; do
      [ -f "$_f" ] || continue
      _name=$(/usr/bin/awk '$1=="Default"{print $2; exit}' "$_f" 2>/dev/null) || _name=""
      [ -n "$_name" ] && break
    done
    printf '%s' "$_name"
  }
  _onchange_defprinter() {
    local _name
    _name=$(/usr/bin/head -1 "$2" 2>/dev/null)
    # No default: no command exists for that.
    [ -n "$_name" ] || return 0
    # A default naming a removed queue is transient: emit only a replayable one.
    /usr/bin/lpstat -a 2>/dev/null | /usr/bin/awk -v q="$_name" '$1==q{f=1} END{exit !f}' || return 0
    _note_should_show "__defprinter__:$_name" || return 0
    log_line "Cmd: # Printers: default printer is now $_name"
    log_line "Cmd: $(_mdm_wrap "/usr/bin/lpoptions -d \"$(_escape_dq "$_name")\"")"
    return 0
  }
  _snapshot_watch defprinter 3 _read_defprinter _onchange_defprinter
}

# Spotlight indexing per volume via `mdutil -s -a`, emit `mdutil -i`. Not `-v`
# (its scan time moves at every probe).
spotlight_watch() {
  [ -x /usr/bin/mdutil ] || return 0
  # `<volume>\t<state>`. `|| true` inside: mdutil can exit non-zero.
  _read_spotlight() {
    /usr/bin/mdutil -s -a 2>/dev/null | /usr/bin/awk '
      /^\// && /:$/ { vol = substr($0, 1, length($0) - 1); next }
      vol != "" && /[Ii]ndexing/ {
        st = (/disabled/) ? "disabled" : (/enabled/ ? "enabled" : "")
        if (st != "") print vol "\t" st
        vol = ""
      }' || true
  }
  _onchange_spotlight() {
    local _snap="$1" _curr="$2" _vol _state _old
    while IFS=$'\t' read -r _vol _state; do
      [ -n "$_vol" ] || continue
      _old=$(/usr/bin/awk -F'\t' -v v="$_vol" '$1==v{print $2}' "$_snap" 2>/dev/null)
      # A volume absent from the snapshot was mounted (or, leaving, unmounted): no change.
      [ -n "$_old" ] || continue
      [ "$_old" = "$_state" ] && continue
      _note_should_show "__spotlight_vol__:$_vol:$_state" || continue
      [ "$_state" = enabled ] \
        && log_line "Cmd: sudo /usr/bin/mdutil -i on \"$(_escape_dq "$_vol")\"" \
        || log_line "Cmd: sudo /usr/bin/mdutil -i off \"$(_escape_dq "$_vol")\""
      # A /Volumes path is a disk named by whoever formatted it: same trap as the display UUID.
      case "$_vol" in
        /Volumes/*)
          log_line "Cmd: #       ('$_vol' is a mounted volume on THIS Mac. The path is not portable)" ;;
      esac
    done < "$_curr"
    return 0
  }
  _snapshot_watch spotlight 3 _read_spotlight _onchange_spotlight _guard_nonempty
}

# ============================================================================
# MAIN. Pre-flight, logging setup, launch
# ============================================================================

# Pre-flight banner. The y/n prompt appears only without Python3/CLT; non-
# interactive contexts auto-confirm and log it.
_pf_target="$DOMAIN"
if [ "$ALL_MODE" = "true" ]; then
  [ "$INCLUDE_SYSTEM" = "true" ] && _pf_target="ALL (user + system)" || _pf_target="ALL (user only)"
fi
printf "PrefWatch: %s → %s\n" "$_pf_target" "$LOGFILE"
if [ -z "$PYTHON3_BIN" ]; then
  # The prompt carries the warning (Jamf GUI users see no stdout). `||` keeps
  # set -e from exiting on 1 (declined) or 2 (no channel).
  _pf_rc=0
  prompt_yn "⚠ Python3 unavailable. Limited detection.

Run 'xcode-select --install' to enable full detection (array/dict diffs, PlistBuddy commands).

Start anyway?" || _pf_rc=$?
  case $_pf_rc in
    0) ;;
    1) printf "Aborted.\n"; exit 0 ;;
    2)
      printf "⚠ No TTY or GUI session available. Auto-continuing with limited detection\n"
      /usr/bin/logger -t "prefwatch[init]" -- "Python3 unavailable. Auto-continued (no prompt channel)"
      ;;
  esac
fi

LOGFILE="$(prepare_logfile "$LOGFILE")"

# Log path, version and macOS build, printed once even under ONLY_CMDS.
_os_ver="$(/usr/bin/sw_vers -productVersion 2>/dev/null || printf '?')"
_os_build="$(/usr/bin/sw_vers -buildVersion 2>/dev/null || printf '?')"
if [ "${ONLY_CMDS:-false}" = "true" ]; then
  { printf "[init] Log file: %s\n" "$LOGFILE"
    printf "[init] prefwatch %s on macOS %s (%s)\n" "${SCRIPT_VERSION:-?}" "$_os_ver" "$_os_build"
  } >> "$LOGFILE" 2>/dev/null || true
else
  { printf "[init] Log file: %s\n" "$LOGFILE"
    printf "[init] prefwatch %s on macOS %s (%s)\n" "${SCRIPT_VERSION:-?}" "$_os_ver" "$_os_build"
  } | /usr/bin/tee -a "$LOGFILE" 2>/dev/null || true
fi
/usr/bin/logger -t "prefwatch[init]" -- "Log file: $LOGFILE"

if [ "$ALL_MODE" = "true" ]; then
  log_line "Starting: monitoring ALL preferences"
else
  log_line "Starting monitoring on $DOMAIN"
fi

if [ -n "$PYTHON3_BIN" ]; then
  log_line "Python3: $PYTHON3_BIN (array change detection enabled)"
else
  printf "WARNING: Xcode Command Line Tools not installed. Python3 unavailable\n"         | tee -a "$LOGFILE" 2>/dev/null || true
  printf "Without Python3: array/dict changes and PlistBuddy commands will not be detected\n" | tee -a "$LOGFILE" 2>/dev/null || true
  /usr/bin/logger -t "prefwatch[init]" -- "Python3 unavailable. Limited detection"
fi

# ALL mode without root: say what root adds (no latency difference, measured).
if [ "$ALL_MODE" = "true" ] && [ "$(id -u)" -ne 0 ]; then
  local _ts; _ts="$(get_timestamp)"
  local _w1="[$_ts] NOTE: running without sudo. User preferences are fully covered"
  local _w2="[$_ts]   Not covered: /Library/Preferences (system), sharing commands, launchd state"
  local _w3="[$_ts]   For those, re-run with: sudo $0 ALL"
  printf "%s\n%s\n%s\n" "$_w1" "$_w2" "$_w3"
  printf "%s\n%s\n%s\n" "$_w1" "$_w2" "$_w3" >> "$LOGFILE" 2>/dev/null || true
  /usr/bin/logger -t "prefwatch[init]" -- "Running without sudo. System prefs and root-only watchers unavailable"
fi

if [ "$ALL_MODE" != "true" ] && is_excluded_domain "$DOMAIN"; then
  log_line "Cmd: # NOTE: $DOMAIN is normally excluded in ALL mode, but monitoring as explicitly requested"
fi

[ "$NO_CONSOLE" = "true" ] || launch_console

if [ "$ALL_MODE" = "true" ]; then
  start_watch_all &
else
  start_watch &
fi
WATCH_PID=$!

# A signal to the MAIN pid would skip the EXIT trap and orphan the watcher
# tree: tear it down leaves first.
trap '_shutdown_watcher; exit 143' TERM
trap '_shutdown_watcher; exit 130' INT
trap '_shutdown_watcher; exit 129' HUP
# EXIT on the same teardown (fires in the MAIN pid only, measured), so an
# ERR_EXIT abort no longer leaves the tree running as root.
trap '_shutdown_watcher' EXIT

if [ "$NO_CONSOLE" != "true" ] && is_console_running; then
  # Console-close by PID (`kill -0`, a builtin; pgrep every second cost ~50 s
  # CPU an hour). N consecutive misses before concluding. `|| true` on the
  # pgrep capture: a no-match would kill main by ERR_EXIT.
  _console_pid=$(/usr/bin/pgrep -x Console 2>/dev/null | /usr/bin/head -1) || true
  _console_misses=0
  while true; do
    if [ -n "$_console_pid" ] && kill -0 "$_console_pid" 2>/dev/null; then
      _console_misses=0
    else
      _console_pid=$(/usr/bin/pgrep -x Console 2>/dev/null | /usr/bin/head -1) || true
      if [ -n "$_console_pid" ]; then
        _console_misses=0
      else
        _console_misses=$(( _console_misses + 1 ))
        [ "$_console_misses" -ge 5 ] && break
      fi
    fi
    sleep 1 || true
  done
  log_line "Console.app closed. Stopping monitoring"
  # Reuse the teardown of the traps: a bare kill left eslogger and fs_usage running as root.
  _shutdown_watcher
  exit 0
else
  if [ "$NO_CONSOLE" = "true" ]; then
    log_line "Console disabled (--no-console). Monitoring until Ctrl+C / SIGTERM"
  else
    log_line "Console not detected. Continuing monitoring (Ctrl+C to stop)"
  fi
  wait "$WATCH_PID" 2>/dev/null || true
  exit 0
fi
