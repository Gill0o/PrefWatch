#!/bin/zsh
# ============================================================================
# Script: prefwatch.sh
# Version: 1.5.1
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
#     $12 = FS_USAGE (true/false). ALL mode as root: also run the fs_usage
#          real-time detector next to polling (measured to add nothing polling
#          does not; it takes the single ktrace slot). CLI: --fs-usage.
#          Default: false.
# ============================================================================

# ============================================================================
# CONFIGURATION
# ============================================================================

# Execution security (zsh)
set -e
set -u
set -o pipefail

# Self-diagnostic: on a `set -e` abort, record WHERE before the shell dies (the
# log runs in ONLY_CMDS and captures neither the abort nor stderr). TRAPZERR
# fires only where ERR_EXIT would, so it is silent in normal operation and does
# not prevent the exit. A SIGKILL (an EDR) cannot be trapped: nothing logged and
# still dead means a signal.
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
  --fs-usage            ALL mode as root: also run the fs_usage real-time
                        detector next to polling. Off by default. Measured, it
                        added nothing polling did not, and it takes the machine's
                        single ktrace slot

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
  # Check for help first
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_help
  fi

  # Default values
  DOMAIN="ALL"  # Default to ALL if no domain specified
  LOG_FILE_PARAM=""
  INCLUDE_SYSTEM_RAW="true"
  ONLY_CMDS_RAW="true"
  EXCLUDE_DOMAINS=""
  MDM_OUTPUT_RAW="false"
  DEBUG_FILTER_RAW="false"
  NO_CONSOLE_RAW="false"

  # If first arg doesn't start with -, it's the domain
  if [[ -n "${1:-}" && "${1}" != -* ]]; then
    DOMAIN="${1}"
    shift
  fi

  # Parse flags
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
        # Diagnostic: log `# FILTERED: <dom> <key> (reason)` when a detected change is
        # suppressed, answering "why didn't my change appear?".
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
        # Don't open Console.app and don't tie the watcher lifecycle to it.
        # run until Ctrl+C / SIGTERM. Useful for interactive/VM testing in a
        # Terminal, where closing Console would otherwise stop monitoring.
        NO_CONSOLE_RAW="true"
        shift
        ;;
      --fs-usage)
        # Opt-in since 1.5.0: measured three times, fs_usage added nothing polling did
        # not, at the same latency, and it holds the one ktrace slot and ran to 8 GB
        # under load. Kept for the tests that will decide whether 1.5.1 removes it.
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

# Detect if running via Jamf (parameters start at $4) or CLI (parameters start at $1)
# Jamf passes: $1=mount_point, $2=computer_name, $3=username, then user params at $4+
# CLI passes: user params directly at $1+
JAMF_MODE="false"
if [[ -n "${1:-}" && "${1}" == /* ]] && [[ -n "${2:-}" ]] && [[ -n "${3:-}" ]]; then
  # Looks like Jamf parameters (mount point, computer name, username)
  JAMF_MODE="true"
fi

# Read parameters based on mode
if [ "$JAMF_MODE" = "true" ]; then
  # Jamf mode: parameters start at $4 (positional)
  DOMAIN="${4:-ALL}"
  LOG_FILE_PARAM="${5:-}"
  INCLUDE_SYSTEM_RAW="${6:-true}"
  ONLY_CMDS_RAW="${7:-true}"
  EXCLUDE_DOMAINS="${8:-}"
  MDM_OUTPUT_RAW="${9:-false}"
  # Only set HOT_DOMAINS_RAW if $10 was explicitly provided (non-empty),
  # so the default HOT_DOMAINS array is preserved when $10 is omitted.
  [ -n "${10:-}" ] && HOT_DOMAINS_RAW="${10}"
  DEBUG_FILTER_RAW="${11:-false}"
  FS_USAGE_RAW="${12:-false}"
else
  # CLI mode: use flag-based parsing
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

# Make an emitted PlistBuddy path deployable (MDM mode only): the user home
# becomes /Users/$loggedInUser and a ByHost filename, named after THIS Mac's
# hardware UUID, becomes <domain>.$UUID.plist. `defaults -currentHost write`
# needs none of this.
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

# Literal replacement for the console user's home in MDM output. mdm_plist_path
# rewrites the plist FILE path; the emission code uses this to also rewrite home
# paths embedded in emitted VALUES (e.g. a dock _CFURLString, a path pref).
typeset -g _MDM_HOME_REPL='/Users/$loggedInUser'
# A PlistBuddy VALUE sits inside a single-quoted `-c '…'`, which would keep
# `$loggedInUser` literal: break out of the quotes around it
# (`…/Users/'$loggedInUser'/…`). _MDM_LIU is the token, _MDM_LIU_QB its
# quote-broken form.
typeset -g _MDM_LIU='$loggedInUser'
typeset -g _MDM_LIU_QB="'${_MDM_LIU}'"

# Disable shell trace so -v/--verbose only toggles our own logging.
unsetopt xtrace verbose 2>/dev/null || true

# ---------------------------------------
# CONFIGURATION. Real-time detector ceiling
# ---------------------------------------

# fs_usage keeps every event it has not written out yet: 8 GB and climbing five
# minutes into a post-upgrade Spotlight reindex (measured). Past this resident
# size fs_watch kills it and says so; polling carries on at the same latency.
# Override via PREFWATCH_FS_USAGE_RSS_LIMIT_MB.
typeset -gi FS_USAGE_RSS_LIMIT_MB="${PREFWATCH_FS_USAGE_RSS_LIMIT_MB:-1024}"

# ---------------------------------------
# CONFIGURATION. Hot domains
# ---------------------------------------

# "Hot" domains get a cfprefsd flush (`defaults read`) every poll cycle, so a
# first change surfaces in 1-2s where a cold domain waits on cfprefsd's own
# flush, ~10s. Override via --hot-domains / Jamf $10; "NONE" disables. The
# OPPOSITE of an exclusion: those live in DEFAULT_EXCLUSIONS below.
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
  # NOT hot: sound/systemsettings/touchbar are no-ops here (empty or absent),
  # wallpaper lives in a Store outside Preferences; ncprefs/bluetooth/windowserver
  # are daemon-churned; energy/sharing/network have their own watchers.
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

# Default exclusion patterns for noisy/irrelevant domains
# These domains change frequently but are rarely useful for preference monitoring
# You can override with --exclude flag or $8 parameter in Jamf mode
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

  # Clock/Timer daemon: live timer *instances*, not preferences. Fresh UUIDs
  # (MTTimerID), timestamps and a decrementing MTTimerTimeInterval. Creating a
  # timer is a runtime action; nothing here is a reproducible setting.
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
  # Note: com.apple.security* narrowed. Catch only known noisy sub-domains,
  # not "com.apple.security.authorization" or similar which may have real prefs
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

  # Backup internals (constant state updates)
  # Note: com.apple.TimeMachine removed. Contains real prefs (AutoBackup, ExcludedPaths)
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
  "com.apple.appleintelligencereporting"
  # Apple's analytics agent. Sync timestamps / usage counters only (AppUsageSyncTime)
  "com.apple.analyticsagent"
  "com.apple.GenerativeFunctions*"

  # MetricKit daemon (per-app diagnostic bookkeeping, MX* keys touched on every
  # MetricKit query. Outlook, Teams, Edge, etc. trigger writes)
  "com.apple.metrickitd"

  # ML rate limiter (token bucket counters/timestamps for embedding processing)
  "TokenBucketRateLimiter"

  # Emoji search cache (auto-generated locale emoji lists)
  "com.apple.EmojiCache"

  # Calculator currency cache (auto-updated exchange rates)
  "com.apple.calculateframework"

  # Note: com.apple.SoftwareUpdate removed from exclusions. Contains real prefs
  # (AutomaticDownload, AutomaticallyInstallMacOSUpdates, AutomaticCheckEnabled)
  # Cache noise should be filtered at key level instead

  # Power management internals (constant battery updates)
  "com.apple.PowerManagement*"
  "com.apple.BackgroundTaskManagement*"  # zsh globs are case-sensitive
  "com.apple.backgroundtaskmanagement*"

  # Audio internals (device routing state)
  "com.apple.audio.SystemSettings"

  # User activity tracking (Handoff/Continuity state)
  "com.apple.coreservices.useractivityd*"

  # System internals
  # loginwindow NOT excluded. System file holds real policies (GuestEnabled,
  # LoginwindowText, autoLoginUser, …); churn filtered in is_noisy_key.
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


  # Directory Utility app UI state (toolbar layout, last-browsed perHost node).
  # real directory bindings (AD/LDAP) live in OpenDirectory / config profiles,
  # NOT this user plist, so nothing here is deployable.
  "com.apple.DirectoryUtility"

  # Calendar internals (account UUIDs, UI state)
  "com.apple.iCal"

  # Messages preview rendering internals (screen scale, dimensions)
  "com.apple.MobileSMSPreview"

  # Notification Center internal state (app path tracking, binary blobs)
  "com.apple.ncprefs"

  # Account existence tracking
  "com.apple.accounts.exists"

  # iCloud account services (MobileMeAccounts): the Services array is positional
  # and indices shift between macOS releases, and PlistBuddy addresses arrays by
  # index only, so no portable command exists for these toggles.
  "MobileMeAccounts"

  # Find My device daemon (APS tokens, internal state)
  "com.apple.icloud.fmfd"

  # Telephony framework internals (camera/call state)
  "com.apple.TelephonyUtilities"

  "com.apple.itunescloud"
  "com.apple.itunescloudd"
  # Media library daemon: only migration flags, persistent IDs, daemon-written
  # store capability flags and an update counter. No user prefs. (Capital AMP;
  # the com.apple.amp* glob is case-sensitive and misses it.)
  "com.apple.AMPLibraryAgent"

  # ShazamKit: CloudKit account cache, boot tasks and an access token only. No
  # user preferences (the SHLibrary…UserID churn is internal iCloud identity state)
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
  # Siri/Spotlight suggestions backend daemon. Server-driven resource-download
  # URL cache (version-stamped CDN links), upload headers, internal version; no
  # user prefs (the actual toggles live in com.apple.suggestions/sirisuggestions)
  "com.apple.parsecd"

  # Siri voice-services daemon: subscribedAssets/subscribedPreviousAssets = which
  # TTS/dictation voices are downloaded (bookkeeping under an empty-string key).
  # Downloading a voice is an action, not a reproducible `defaults` pref.
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

  # Adobe Genuine Service (licensing/consent daemon. Consent strings contain
  # French apostrophes that break PlistBuddy single-quote escaping anyway)
  "com.adobe.AdobeGenuineService"

  # Spotlight knowledge daemon (internal sync counters, timestamps)
  "com.apple.spotlightknowledged.pipeline"

  # TeamViewer internals (AI nudge, license, version, UI phases)
  "com.teamviewer*"

  # IPv6 DHCP daemon (interface changes on device connect)
  "com.apple.dhcp6d"

  # QuickLook daemon (plugin modification timestamps)
  "com.apple.QuickLookDaemon"

  # Squirrel updater helpers (`<bundle-id>.ShipIt`, the Electron auto-update
  # framework): SQRL* keys are written when an install starts and deleted when it
  # ends, a write plus two spurious deletes per update. Ten such domains on one
  # Mac, every one empty at rest.
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

  # Siri assistant daemon/backup churn. com.apple.assistant.support is NOT
  # excluded: the real Siri prefs live there (Assistant Enabled, dictation).
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
  # xctest's scratch domain: UserDefaults.standard inside a test run lands here,
  # so every `swift test` writes and deletes the suite's own keys. Never a setting.
  "com.apple.dt.xctest.tool"

  # Filtered per KEY in is_noisy_key, not excluded, so real prefs survive: dock,
  # finder, Safari, systemsettings, Mail, Messages, Music, TV, AddressBook,
  # sharingd, and amp.mediasharingd (every key filtered; _note_mediasharing
  # speaks for it).
)

# Merge user-provided exclusions with defaults
if [ -n "${EXCLUDE_DOMAINS:-}" ]; then
  # User provided custom exclusions, use only those
  EXCLUDE_DOMAINS_RAW="$EXCLUDE_DOMAINS"
else
  # Use defaults
  EXCLUDE_DOMAINS_RAW="${(j:,:)DEFAULT_EXCLUSIONS}"
fi

# Parse exclusion patterns into array
typeset -a EXCLUDE_PATTERNS _raw_excl
IFS=',' read -rA _raw_excl <<< "$EXCLUDE_DOMAINS_RAW"
EXCLUDE_PATTERNS=()
for p in "${_raw_excl[@]}"; do
  # Trim in zsh, not `printf | sed`: that was a CAPTURED PIPE under set -e +
  # pipefail, and sed exits 1 on an invalid UTF-8 byte, which an --exclude value
  # may contain, killing the script before LOGFILE exists. Also 322 forks saved.
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  [ -n "$p" ] && EXCLUDE_PATTERNS+=("$p")
done

# ALL mode if domain is 'ALL' or '*'
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

# Console user detection (to target active user preferences)
get_console_user() {
  /usr/bin/stat -f %Su /dev/console 2>/dev/null || /usr/bin/id -un
}
CONSOLE_USER="${CONSOLE_USER:-$(get_console_user)}"

# Execution prefix as console user if script runs as root
RUN_AS_USER=()
if [ "$(id -u)" -eq 0 ] && [ "$CONSOLE_USER" != "root" ]; then
  RUN_AS_USER=(/usr/bin/sudo -u "$CONSOLE_USER" -H)
fi

# Target home directory for plist lookups. When running as root via Jamf/MDM,
# $HOME is /var/root but user prefs live in the console user's home. Resolve
# via dscl, with /Users/<user> as a fallback. In CLI mode $HOME is correct.
TARGET_HOME="$HOME"
if [ "$(id -u)" -eq 0 ] && [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
  _resolved_home=$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}') || true
  if [ -n "$_resolved_home" ]; then
    TARGET_HOME="$_resolved_home"
  elif [ -d "/Users/$CONSOLE_USER" ]; then
    TARGET_HOME="/Users/$CONSOLE_USER"
  fi
fi

# Binary availability checks (optimization to avoid repeated lookups)
HAVE_BIN_DATE="false"
[ -x /bin/date ] && HAVE_BIN_DATE="true"

# Python3 detection & validation (used for JSON processing if available)
# On macOS, /usr/bin/python3 is a stub that triggers Xcode CLT install dialog.
# Check CLT presence first to avoid the popup.
PYTHON3_BIN=""
_python3_validate() {
  local candidate="$1"
  # Actually run python3 to verify it works (not just that binary exists)
  if "$candidate" -c 'import json; print("ok")' >/dev/null 2>&1; then
    PYTHON3_BIN="$candidate"
    return 0
  fi
  return 1
}

# Check if Xcode CLT is installed before touching /usr/bin/python3
_clt_installed=false
if /usr/bin/xcode-select -p >/dev/null 2>&1; then
  _clt_installed=true
fi

if [ "$_clt_installed" = "true" ] && [ -x /usr/bin/python3 ] && _python3_validate /usr/bin/python3; then
  : # validated via CLT python3
elif command -v python3 >/dev/null 2>&1; then
  # Try non-system python3 (Homebrew, pyenv, etc.). Safe to run without CLT
  _candidate="$(command -v python3)"
  if [ "$_candidate" != "/usr/bin/python3" ] && _python3_validate "$_candidate"; then
    : # validated via alternative python3
  fi
fi

# Temp directory + EXIT trap. Covers every MAIN exit path (sub-shells
# still arm their own TERM/INT traps to kill workers before EXIT fires).
PREFWATCH_TMPDIR=$(/usr/bin/mktemp -d "/tmp/prefwatch.${$}.XXXXXX") || PREFWATCH_TMPDIR="/tmp/prefwatch.${$}"
/bin/mkdir -p "$PREFWATCH_TMPDIR" 2>/dev/null || true
trap '/bin/rm -rf "$PREFWATCH_TMPDIR" 2>/dev/null || true' EXIT

# Reclaim tmpdirs from crashed prior runs (kill -0 → PID gone).
for _stale in /tmp/prefwatch.[0-9]*(N/); do
  _stale_pid="${${_stale:t}#prefwatch.}"
  _stale_pid="${_stale_pid%%.*}"
  [ "$_stale_pid" = "$$" ] && continue
  /bin/kill -0 "$_stale_pid" 2>/dev/null && continue
  /bin/rm -rf "$_stale" 2>/dev/null || true
done
unset _stale _stale_pid

# Cache initialization
typeset -A _EXCLUSION_CACHE  # Cache for domain exclusion checks
CACHE_DIR=""                  # Cache directory for plist diffs (WATCH_ALL mode)

# Domain tag for logging
DOMAIN_TAG="$DOMAIN"
[ "$ALL_MODE" = "true" ] && DOMAIN_TAG="all"

# Extract script version from header
SCRIPT_VERSION=$(head -20 "$0" 2>/dev/null | /usr/bin/grep "^# Version:" | /usr/bin/sed -E 's/^# Version: //' | head -1) || true
[ -z "$SCRIPT_VERSION" ] && SCRIPT_VERSION="unknown"

# Log file configuration
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

# Fork-free strftime + stat (zsh built-in modules)
zmodload zsh/datetime 2>/dev/null && HAVE_ZSH_STRFTIME=true || HAVE_ZSH_STRFTIME=false
zmodload zsh/stat 2>/dev/null && HAVE_ZSH_STAT=true || HAVE_ZSH_STAT=false
zmodload zsh/system 2>/dev/null && HAVE_ZSH_SYSTEM=true || HAVE_ZSH_SYSTEM=false

# Helper function for optimized timestamp
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

# Helper function to determine plist path from domain
get_plist_path() {
  local domain="$1"
  if [[ "$domain" =~ ^/ ]]; then
    printf '%s' "$domain"
  elif [ "${_EMIT_SYS:-false}" = "true" ]; then
    # System-level pref: root-owned file under /Library/Preferences, at its real
    # path when show_plist_diff recorded one (subdirectories exist there).
    printf '%s' "${_EMIT_SYS_DOM:+${_EMIT_SYS_DOM}.plist}"
    [ -n "${_EMIT_SYS_DOM:-}" ] || printf '%s' "/Library/Preferences/${domain}.plist"
  else
    # $TARGET_HOME: console user's home when root (Jamf), $HOME otherwise
    printf '%s' "$TARGET_HOME/Library/Preferences/${domain}.plist"
  fi
}

# Derive a "defaults" domain from a .plist path, fork-free: this runs once per
# plist at snapshot and on every event. `${p:t}` is basename; the ByHost UUID
# suffix is stripped by `${dom%.*}`, since a trailing 8+ hex/dash segment never
# itself contains a '.'.
domain_from_plist_path() {
  local p="$1" base dom
  base="${p:t}"
  dom="${base%.plist}"
  [[ "$dom" =~ '\.[0-9A-Fa-f-]{8,}$' ]] && dom="${dom%.*}"
  printf '%s\n' "$dom"
}

# Hash a path for cache file naming (cached to avoid repeated md5 forks)
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
    # The /tmp fallback is a predictable name in a world-writable directory: another
    # user can pre-create it as a symlink to a file of theirs, which the truncate
    # would destroy (`>|` follows it too). Only a plain file we own is accepted.
    # `-L` FIRST and alone: `[ -e ]` follows the link, so a dangling symlink would
    # answer "absent" and the truncate would CREATE the attacker's target.
    if [ -L "$path" ] || { [ -e "$path" ] && { [ ! -f "$path" ] || [ ! -O "$path" ]; }; }; then
      path="${path%.log}.$$.log"
    fi
    : > "$path" 2>/dev/null || true
  fi
  # The log carries the TCC table, network config, share paths and account
  # names: owner-only, never fatal if the chmod cannot apply.
  /bin/chmod 600 "$path" 2>/dev/null || true
  # Owner-only cut Console.app off under sudo (root's file, Console runs as the
  # console user: "Impossible de lire le fichier"). Hand the file to the console
  # user; 0600 still keeps every other user out. /usr/bin/id, never bare `id`:
  # this function's `local path` shadows zsh's $path (tied to PATH), so a bare
  # command here is "not found", and this branch was a silent no-op.
  if [ "$(/usr/bin/id -u)" -eq 0 ] && [ -n "${CONSOLE_USER:-}" ] && [ "$CONSOLE_USER" != "root" ]; then
    /usr/sbin/chown "$CONSOLE_USER" "$path" 2>/dev/null || true
  fi
  echo "$path"
}

# Interactive y/n prompt. Exit 0 yes, 1 no, 2 no channel or dialog timed out.
# Tries stdin (TTY), then /dev/tty (probed: a bare open can set -e-exit under
# Jamf Self Service), then an osascript dialog as the console user (5-min
# timeout → 2, so a policy never hangs).
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

  # GUI fallback. Only when a real console user is logged in.
  # `on run argv` passes $prompt as a native argument, so embedded newlines
  # render correctly and no shell/AppleScript escaping is needed.
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

# Check if a domain is excluded (with cache)
is_excluded_domain() {
  local d="$1"

  if [ -n "${_EXCLUSION_CACHE[$d]+isset}" ]; then
    return ${_EXCLUSION_CACHE[$d]}
  fi

  # Compute and cache result
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

# Intelligent key filtering - filters noisy keys while keeping useful preferences
# This allows monitoring domains like com.apple.dock without the noise
is_noisy_key() {
  local domain="$1" keyname="$2"

  # ========================================================================
  # GLOBAL NOISY PATTERNS (apply to all domains)
  # ========================================================================

  case "$keyname" in
    # Keep: NSTableViewDefaultSizeMode is the sidebar icon size (real pref),
    # NOT table-view UI state. Must precede the NSTableView* noise glob below
    NSTableViewDefaultSizeMode) return 1 ;;
    # Window positions & UI state. NSStatusItem* is GLOBAL here and covers Control
    # Center, Spotlight and every third-party menu-bar app (it also swallows
    # `NSStatusItem VisibleCC <Module>`, a deliberate trade-off: do not narrow it
    # without measuring what a System Settings toggle really writes).
    NSWindow\ Frame*|NSNavPanel*|NSSplitView*|NSTableView*|NSStatusItem*|*ItemPreferredPositions*|*WindowBounds*|*WindowState*|*WindowFrame*|*WindowOriginFrame*|*WindowLocation|WindowLeft|WindowTop|*PreferencesWindow*|*.column.*.width|*.column.*.width.*|*_frame|NSOSPLastRootDirectory|NSNavLastRootDirectory|recentlyPlayed*|*SidebarWidth*)
      return 0 ;;

    # App-controlled macOS menu item overrides (set by app, not user)
    NSDisabledCharacterPaletteMenuItem|NSFullScreenMenuItemEverywhere)
      return 0 ;;

    # NSToolbar Configuration <UUID>. A per-instance toolbar layout an app dumps
    # on first window open (e.g. Console). The UUID is regenerated per instance,
    # so the command isn't portable. NAMED configs (NSToolbar Configuration
    # Browser) ARE reproducible and are kept. The pattern requires a UUID
    # (8-4-4-4-12 hex) right after the name, which "Browser" etc. never match.
    NSToolbar\ Configuration\ [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f]*)
      return 0 ;;

    # Sparkle updater internals (auto-update framework state)
    # Note: SUSendProfileInfo kept. It's a user-toggleable opt-in for stats
    SUUpdateGroupIdentifier|SULastCheckTime|SUHasLaunchedBefore|SUSkippedVersion|SUUpdateRelaunchingMarker)
      return 0 ;;

    # Timestamps & dates (metadata, not preferences) - UNIVERSAL
    # Matches: lastRetryTimestamp, LastUpdate, last-seen, updateTimestamp, CKStartupTime, lastCheckTime, etc.
    *timestamp*|*Timestamp*|*TimeStamp*|*-timestamp|*LastUpdate*|*LastSeen*|*-last-seen|*-last-update|*-last-modified|*LastRetry*|*LastSync*|*lastRetry*|*lastSync*|*StartupTime*|*StartTime*|*CheckTime|lastCheckTime|*LastSuccess*|*lastSuccess*|*LastKnown*|*lastKnown*|*LastLoadedOn*|*lastProcessed*|*LastProcessed*|*LastBackup*|*lastBackup*|*lastAppUpdateCheck*|*LastAppUpdateCheck*|*last*Date|*Last*Date)
      return 0 ;;

    # bare *Date is too broad (masks ExpirationDate/StartDate); anchored *last*Date
    # above is safe. "last…Date" is always a timestamp (e.g. lastCoolOffDate).

    # HockeyApp / App Center SDK session lifecycle timestamps (BIT* prefix,
    # epoch floats rewritten on every foreground/background transition)
    BIT*Time)
      return 0 ;;

    # Error states & sync errors (transient)
    *Error|*Errors|*error|*errors|*ErrorCode*|*ErrorDomain*|*ErrorUserInfo*|IMCloudKitSyncErrors|IMSerializedError*)
      return 0 ;;

    # Rollout configs & A/B testing (system telemetry)
    rollouts|rolloutId|deploymentId|*RolloutId|*DeploymentId)
      return 0 ;;

    # Analytics & telemetry counters    # Note: keeps opt-in toggles like AnalyticsEnabled, SendAnalytics, TelemetryEnabled
    # *-analytics-stamp: daemon-written analytics timestamp (dock, screencapture, systemuiserver, …)
    *AnalyticsQueue*|*AnalyticsSession*|*AnalyticsEvent*|*TelemetryEvent*|*TelemetrySession*|*TelemetryQueue*|*BootstrapTime*|*lastBootstrap*|*HeartbeatDate*|*SKPurchaseIntent*|*-analytics-stamp)
      return 0 ;;

    # Device/Library/Session IDs (change per device)
    *-library-id|*-persistent-id|*-session-id|*-device-id|shared-library-id|devices-persistent-id|SessionId|SessionVersion|SessionLongBuildNumber|CampaignManagerVersionKey)
      return 0 ;;

    # System-managed localization (auto-generated from language settings)
    preferredLocalizations)
      return 0 ;;

    # UUIDs (transient notification/state identifiers)
    # Matches: uuid, UUID, *UUID, *uuid (e.g., sessionUUID, updatedSinceBootUUID)
    # Note: removed exact `flags`. Too generic, apps can use it as a real pref
    uuid|UUID|*UUID|*uuid)
      return 0 ;;

    # VoiceOver internal state (Braille defaults, display text timestamps)
    SCRC*|SCRDisplay*)
      return 0 ;;

    # Feature flags (internal state)
    # Exception: com.apple.universalaccess feature.* are real accessibility settings
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

    # Note: `last-selection` is NOT global (too generic). Filtered domain-specific
    # for com.apple.screencapture below.

    # Recent items & history
    # Note: keeps real prefs like HistoryAgeInDaysLimit, EnableHistory
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

    # App launch counters & donation reminders (internal state)
    # Note: removed `uses` exact and `*donate*`. Too generic, could mask real prefs
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

    # Declarative Device Management persisted state (DDMPersistedErrorKey,
    # DDMPersistedStateKey, etc.. Daemon-managed across many domains)
    DDMPersisted*)
      return 0 ;;

    # WebKit internal state (set when opening Settings panels that use WebKit views)
    WebKitUseSystemAppearance)
      return 0 ;;

    # Cache & temporary data
    # Note: keeps real prefs like CacheSize, EnableCache, ColorTemperature, Template*
    *-cache|*CacheData*|*CachedBy*|*CacheVersion*|*CacheKey*|*CacheEntry*|*FlushThumbnailCache|*-temp|*-tmp|*TempFile*|*TempPath*)
      return 0 ;;

    # View state (scroll positions, selected items, etc.)
    # Note: *ViewOptionsFrame/Window only. Keeps Finder StandardViewOptions etc.
    *ScrollPosition*|*scrollPosition*|*SelectedItem*|*ViewOptionsFrame*|*ViewOptionsWindow*)
      return 0 ;;

    # Playback & connection state (transient states across all apps)
    # Note: removed *ConnectionState*. Too broad, could mask real connection prefs
    *PlaybackStatus*|*Playback*Status*|*lastNowPlayedTime*|*LastConnected*)
      return 0 ;;

    # Note: removed state|status|State|Status. Too generic, apps may use these as real prefs
  esac

  # Hash keys (session IDs, cache keys) - long hex strings (zsh built-in regex, no fork)
  # Examples: bc4a9925ba8a1ebc964af5dbb213795013950b6b8b234aacf7fb20f5a791e5d7 (SHA256)
  if [[ "$keyname" =~ ^[0-9a-fA-F]{32,}$ ]]; then
    return 0
  fi

  # UUID keys (internal identifiers used as key names)
  # Examples: 3A4B5C6D-1234-5678-9ABC-DEF012345678 (com.apple.prodisplaylibrary, etc.)
  if [[ "$keyname" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    return 0
  fi

  # Note: removed ALL_CAPS regex. Too broad, could mask real prefs like SHOW_HIDDEN_FILES, ENABLE_DEBUG
  # Known noisy ALL_CAPS keys should be filtered per-domain instead

  # ========================================================================
  # DOMAIN-SPECIFIC NOISY KEYS
  # ========================================================================

  case "$domain" in
    # Accessibility Keyboard: Filter window position
    com.apple.AssistiveControl.virtualKeyboard)
      case "$keyname" in
        PanelFrame|SCLaunchedAsSlave) return 0 ;;
        # Keep: DesiredPanelWindowPosition, etc.
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
        # Note: bundle-identifier, _CFURLString, file-label are useful in PlistBuddy output
        # (identify the app); suppressed as flat defaults write by _skip_keys
        # Keep: orientation, autohide, tilesize, magnification, persistent-apps, etc.
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
        # Preview-pane geometry: the Finder writes the default width (240) as a side
        # effect of showing the pane, alongside the real FXPreferredViewStyle change.
        # Scoped to the width keys so ShowPreviewPane (⌘⇧P) and PreviewPaneSettings
        # survive.
        PreviewPane*Width)
          return 0 ;;
        # Keep: ShowPathbar, AppleShowAllFiles, FXPreferredViewStyle, etc.
      esac
      ;;

    # System Settings: Filter timestamps. Also covers com.apple.systemsettingsagent,
    # one `lastIndexed_<deep link>` stamp per pane (build:locale:UUID:n) that
    # Spotlight's re-index rewrites; that plist holds nothing else today.
    com.apple.systemsettings*)
      case "$keyname" in
        # Noisy: last seen timestamps, navigation state, indexing timestamps, extension state
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

    # Passwords: iCloud Private Relay availability is observed network state (it flips
    # on its own as the network changes, and Traffic is a byte counter), plus content
    # refresh stamps. Keep: ShowServiceNamesInPasswords, showMenuBarExtra.
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

    # loginwindow: drop per-session/login churn, keep admin policies (see Keep below).
    com.apple.loginwindow)
      case "$keyname" in
        # Noisy: who logged in last / recently, first-login bookkeeping, build stamp
        lastUser|lastUserName|RecentUsers|AccountInfo|OptimizerPreviousBuild|UseVoiceOverLegacyMigrated)
          return 0 ;;
        # Noisy: session-restore (TAL* = apps-to-relaunch / logout state) + onboarding churn
        TAL*|MiniBuddy*|oneTimeSSMigrationComplete)
          return 0 ;;
        # Keep: GuestEnabled, HideUserAvatarAndName, LoginwindowText, RetriesUntilHint,
        # AdminHostInfo, autoLoginUser*, Disable*, Clock* (login-screen clock font)
      esac
      ;;

    # SoftwareUpdate: drop daemon-written check results, keep the policy toggles
    com.apple.SoftwareUpdate)
      case "$keyname" in
        LastResultCode|LastAttempt*|LastRecommendedUpdatesAvailable|LastUpdatesAvailable|RecommendedUpdates|LastSessionSuccessful|FirstOfferDateDictionary|AvailableUpdatesNotification*)
          return 0 ;;
        # Beta program: the seed catalog URL comes and goes with enrollment, and
        # LastCatalogChangeDate stamps it. _note_seed_enrollment speaks in their
        # place; a raw CatalogURL write enrolls nothing.
        CatalogURL|LastCatalogChangeDate) return 0 ;;
        # Keep: AutomaticCheckEnabled, AutomaticDownload, AutomaticallyInstall*, etc.
      esac
      ;;

    # SMB server: NetBIOSName is auto-derived from the host name (smbd rewrites
    # it on start). Keep ServerDescription, AllowGuestAccess, etc.
    com.apple.smb.server)
      case "$keyname" in
        NetBIOSName) return 0 ;;
      esac
      ;;

    # Universal Access: Filter internal change history
    com.apple.universalaccess)
      case "$keyname" in
        # hudNotifiedConstrast (sic): internal contrast-HUD state, not a setting.
        # value type even varies by machine (float here, bool elsewhere)
        History|com.apple.custommenu.apps|displaysLastCursorLocation|hudNotifiedConstrast) return 0 ;;
      esac
      ;;

    # Activity Monitor: column widths are geometry (a dict here, so the global
    # `*.column.*.width` rule does not see it) and SelectedTab is the last tab
    # shown. Keep ShowCategory (All / My processes…), UpdatePeriod, the columns.
    com.apple.ActivityMonitor)
      case "$keyname" in
        Column\ Width|SelectedTab) return 0 ;;
      esac
      ;;

    # Game controllers: `controllers` and `devices` are the paired-hardware
    # inventory (positional entries per controller: profile, hidden flag, form
    # fitting), rewritten when the pane opens or a pad connects; settingsVersion
    # and showGCPrefsPane are pane state. Keep the thumbstick scrolling settings,
    # the Bluetooth long-press action, and the games/profiles remaps.
    com.apple.GameController)
      case "$keyname" in
        controllers|devices|settingsVersion|showGCPrefsPane) return 0 ;;
      esac
      ;;

    # Menu bar agent (macOS 27): telemetry counters rewritten whenever an item
    # appears or leaves (the trailing count flipped all day on an idle Mac).
    # Reject list, so a real setting appearing here still surfaces.
    com.apple.MenuBarAgent)
      case "$keyname" in
        MenuBarAnalytics.*) return 0 ;;
      esac
      ;;

    # Shortcuts: the markers its indexer and sync rewrite on their own. The tool
    # database UUID changed with no hand on the app. Reject list: the plist holds
    # no setting today, but one appearing must still surface.
    com.apple.siri.shortcuts)
      case "$keyname" in
        WFSpotlightIndexed*|SpotlightDomainVersion|SpotlightSchemaVersionHash|WFLastSyncedFlagsHash) return 0 ;;
      esac
      ;;

    # Messages nickname sync: version counters that climb with every exchange
    # (four keys, eleven writes in a morning), plus the daemon's own flags.
    # Kept: MeCardSharingEnabled and MeCardSharingAudience, the "Share Name and
    # Photo" setting and its audience.
    com.apple.messages.nicknames)
      case "$keyname" in
        *Version|IMDNickname*|Nickname*|MeCardSharingImageForkedFromMeCard) return 0 ;;
      esac
      ;;

    # Bonjour: genCount is the DNS-SD generation counter, bumped whenever the
    # advertised services change (seen on 27.0 next to a printer-sharing toggle,
    # whose real command is the cupsctl line). The domain holds nothing else.
    com.apple.network.ServiceDiscovery)
      case "$keyname" in
        genCount) return 0 ;;
      esac
      ;;

    # GlobalPreferences: Filter Keyboard panel first-open artifacts
    .GlobalPreferences)
      case "$keyname" in
        KB_SpellingLanguage|KB_SpellingLanguageIsAutomatic) return 0 ;;
        # Beta program: set in the SYSTEM .GlobalPreferences on enroll, deleted
        # on unenroll. The NOTE comes from the SoftwareUpdate side; this rides along.
        NSShowFeedbackMenu) return 0 ;;
        # Time-zone picker breadcrumbs (the last-clicked city, its AppleMapID and
        # coordinates): none of them SET the time zone, which timezone_watch emits as
        # `systemsetup -settimezone`.
        com.apple.TimeZonePref.*|com.apple.preferences.timezone.*|com.apple.AppleModemSettingTool.LastCountryCode) return 0 ;;
        # Keep: KB_DoubleQuoteOption, KB_SingleQuoteOption, NSUserQuotesArray (quote style)
      esac
      ;;

    # Spotlight: Filter UI state and counters
    # Siri: internal stash of the menu-bar icon visibility, set on disable and
    # deleted on enable. State preservation, not a pref (StatusMenuVisible is the
    # real one; VoiceTriggerUserEnabled stays too).
    com.apple.Siri)
      case "$keyname" in
        SiriPrefStashedStatusMenuVisible) return 0 ;;
      esac
      ;;

    # Siri setup wizard (macOS 27): which onboarding panes were last shown, at what
    # version; the opt-ins it produces live in com.apple.assistant.support and stay.
    com.apple.siri.setup)
      case "$keyname" in
        lastShownCoordinatorVersion*) return 0 ;;
      esac
      ;;

    # 'Offline Dictation Status' is per-locale model-download state the daemon
    # writes (Installed, High Quality…), keyed by every locale; `defaults write
    # …Installed true` fakes the flag, it installs nothing. The real prefs
    # (Assistant Enabled, Dictation Auto Punctuation Enabled) are siblings and stay.
    com.apple.assistant.support)
      case "$keyname" in
        Offline\ Dictation\ Status) return 0 ;;
      esac
      ;;

    # Voice Trigger ("Hey Siri"): keep the real toggles, drop internal state that
    # the daemon writes as a side-effect of enabling Siri. 'Remote Darwin
    # VoiceTrigger Enabled' is inter-device routing state (no UI toggle);
    # 'Accessory <Alarm|Media|Timer> Playback Status' is accessory runtime state.
    # Keep: 'VoiceTrigger Enabled' (Listen for "Hey Siri"), UserPreferredVoiceTriggerPhraseType.
    com.apple.voicetrigger)
      case "$keyname" in
        Remote\ Darwin\ VoiceTrigger\ Enabled|Accessory\ *\ Playback\ Status) return 0 ;;
      esac
      ;;

    # com.apple.campo (macOS 27) carries the same Spotlight usage counters
    # (engagement counts and dates, launch time, first-run reset) next to the
    # menu bar item flag the global filter already drops.
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

    # Campo: per-target engagement counters (telemetry), e.g.
    # engagementCountForDate-com.apple.Spotlight. A usage tally, not a setting.
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
        # VisibleNetworkSRLocaleIdentifiers: internal dictation-locale visibility
        # tracking, rewritten as a side-effect of adding a keyboard/language
        DictationIMTargetApplications|CACPersistentSleepState|VisibleNetworkSRLocaleIdentifiers) return 0 ;;
        # Keep: DictationIMUseOnlyOfflineDictation, CACUserHintsFeatures, etc.
      esac
      ;;

    # CUPS printing prefs: Filter printer history
    org.cups.PrintingPrefs)
      case "$keyname" in
        Network|PrinterID) return 0 ;;
      esac
      ;;

    # Print presets: drop the driver internals and the last job's traces, keep
    # everything else. See _PRINT_PRESET_NOISE for why this is a reject list.
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
        # Keep: LastKeyboardPreset (user keyboard shortcut preset)
        # Keep: StartupScriptsShouldLoad (user preference to enable/disable startup scripts)
        # Keep: QuickActionsPanelCategory (Quick Actions panel visibility)
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
        # Noisy: per-build attempt counters (Updates:Attempts:N) + last-seen build/version (Status:Build:Last, Status:Version:Last)
        Updates|Status) return 0 ;;
      esac
      ;;

    # Messages (iMessage): Filter analytics/telemetry
    com.apple.MobileSMS)
      case "$keyname" in
        # Noisy: internal analytics (contact scrutiny, background report counters)
        # and the iMessage app-browser "seen" dictionary (one entry per extension,
        # rewritten as the drawer is opened).
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

    # Content Caching daemon: Filter cache size/details (runtime counters),
    # keep Activated (the user-toggleable enable flag)
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

    # Remote Desktop: Filter daemon-set initialization values (rewritten on
    # every Remote Management activation; values don't reflect user intent)
    com.apple.RemoteDesktop)
      case "$keyname" in
        RSAKeySize|DOCAllowRemoteConnections) return 0 ;;
      esac
      ;;

    com.trendmicro.ztnasase)
      # Trend Micro ZTNA/SASE agent: filter the agent STATE (all-"0" versions, the
      # per-device DeviceId, validity flags, the live swgConnectStatus, UserName
      # which is the signed-in e-mail), keep the reproducible prefs
      # (dontShowSignInPopupAgain, requireAuth*, LoginURL/SwgServer/pacUrl, CompanyId,
      # *IsEnable). Pending confirmation: swgUnprotectFlag, thirdPartyVPNExisted.
      case "$keyname" in
        *Version|DeviceId|connectorInfoList|systemExtensionExistFlag|swgIsInvalid|ztnaIsInvalid|UserName|swgConnectStatus)
          return 0 ;;
      esac
      ;;

    # Extensis: last_sent_* are telemetry stamps (the instant diagnostics or metrics
    # last shipped), snake_case with no time word, so the CamelCase timestamp
    # patterns miss them. Per KEY: SUAutomaticallyUpdate and vault.path are real.
    com.extensis.*)
      case "$keyname" in
        last_sent_*) return 0 ;;
      esac
      ;;

    # Setapp writes short-lived job markers it deletes when the job ends, each one
    # a spurious write + Delete: *ActiveRefreshSession* (a fresh UUID glued to the
    # END of the key, which the whole-key UUID rule misses), UpdatingSearchIndexItem-*
    # and Core Data's ManagedObjectContext_*_dieInfo save marker. Per KEY: the
    # plist also holds ~89 real settings (SUAutomaticallyUpdate, soundEffects…).
    com.setapp.*)
      case "$keyname" in
        *ActiveRefreshSession*|UpdatingSearchIndexItem-*|ManagedObjectContext_*) return 0 ;;
      esac
      ;;

    # Office apps: UAE* is Unexpected Application Exit bookkeeping (a marker set at
    # launch, cleared on a clean quit), never a setting. Same family in
    # SharePoint-mac on 27.0: the crash-reporting SDK switch, App Center
    # bookkeeping, the session record and the OS stamp.
    com.microsoft.*)
      case "$keyname" in
        UAE*|kAppBootTimeForUAE|AppExitGraceful|UseMERPCrashReportingSdk|MSAppCenter*|\
        SessionId|SessionVersion|SessionLongBuildNumber|OSVersion|OSLocale) return 0 ;;
      esac
      ;;

    # Monotype Fonts agent: MFEPProcessId is the helper's live PID, MFEPExecutablePath
    # its install location, both daemon state. Named explicitly, not an MFEP* glob.
    com.monotype.fonts)
      case "$keyname" in
        MFEPProcessId|MFEPExecutablePath) return 0 ;;
      esac
      ;;

    # Battery charge limit: `…prior.limit` is UI state, the real limit is SMC-managed
    # and a `defaults write` does not apply it. _note_charge_limit says so.
    com.apple.batteryui.charging.mac)
      case "$keyname" in
        *prior.limit) return 0 ;;
      esac
      ;;

    # AirDrop discoverability. The domain used to be excluded whole for its Auto
    # Unlock and AirDrop hash bookkeeping (29 of 30 keys), which dropped the one
    # real setting. A drop list, so a future setting still surfaces.
    com.apple.sharingd)
      case "$keyname" in
        AirDropRandomHashUUIDKey*|AutoUnlock*|HashManager-*|SDAirDrop*|\
        SFCollaborationUserDefaults*|AUIconTransferStore|\
        AfterFirstUseExpirationDate|OneTimeAirDropReset*) return 0 ;;
        # ByHost session tokens (12 hex) and an Apple ID blob the daemon writes
        # and deletes on its own; a write and a Delete per AirDrop session.
        AirDropID|StreamID|AppleIDAgentMetaInfo) return 0 ;;
      esac
      ;;

    # Media Sharing: every key is filtered and the domain is still watched, since
    # no command reproduces it. Measured on 26.6.2: the write survives, survives a
    # kickstart of mediasharingd, and the Sharing pane never follows. These keys
    # mirror state the daemon writes and does not read; _note_mediasharing says so.
    com.apple.amp.mediasharingd)
      return 0
      ;;

    # Music, TV and Contacts used to be excluded WHOLE for their window geometry,
    # which also dropped the real settings (crossfade, EQ, import encoder, Contacts
    # text size and default account): Music 49 keys → 8, TV 38 → 1, Contacts 12 → 3.
    # Never blanket-exclude a domain that holds real prefs.
    com.apple.Music|com.apple.TV)
      case "$keyname" in
        # Window, column and sidebar geometry; per-library view state.
        "NSSplitView"*|"NSWindow Frame"*|"NSNavPanel"*|NSApplicationCrashOnExceptions|\
        PPr4:*|PLGD:*|RDoc:*|rprf:*|gnot:*|\
        sidebar-hidden|sidebar-shown|sidebarItemInfo|bwui) return 0 ;;
        # Store/account caches, bookmarks and one-shot UI milestones.
        *-bookmark|*-url|*Bookmark|*CacheKey|store*|Store*|doesStoreSupport*|\
        debugAssert*|checkedHLSKeysTime|refreshedHLSKeysTime|_MPC*|IRTokenAudio|tokenData|\
        JetEngine*|*WelcomeScreenState|whatsNewLevel|updateLevel|jsVersion|\
        Kettle*|hasSeen*|hasRegisterd*|kAOSUI*|ImageProxy*|RetryOn*|VUIAssetCacheKey|\
        last*|controllableInterfaceGUID|haveRadioState|notifications-warming*|\
        eqPrefsVersion|com.apple.amp.*|didSetLyricsByDefaultOnNowPlaying|firstLaunch*) return 0 ;;
      esac
      ;;
    com.apple.AddressBook)
      case "$keyname" in
        "NSSplitView"*|"NSWindow Frame"*|ABCleanWindowController*|ABDatumColumnWidth|\
        ABMetaDataChangeCount|ABMetadataLastOilChange|ABVersion|ABLastImportShown) return 0 ;;
      esac
      ;;

    # Time Machine: backupd owns this file and `tmutil` is the documented way in.
    # AutoBackup and SkipPaths are filtered and _note_timemachine emits the tmutil
    # lines; the rest of the domain has no tmutil verb and is left as it was.
    com.apple.TimeMachine)
      case "$keyname" in
        AutoBackup|SkipPaths) return 0 ;;
      esac
      ;;

    # CurrentSet is a TOP-LEVEL string, so a location change also reaches the
    # scalar path as `defaults write … CurrentSet "/Sets/<UUID>"` (seen on 27.0);
    # show_plist_diff emits `scselect "<name>"` in its place.
    preferences)
      case "$keyname" in
        CurrentSet) return 0 ;;
      esac
      ;;

    # Wi-Fi on/off. airportd owns this file, so writing PowerEnabled back only
    # forges the record. `networksetup -setairportpower` is what actually moves
    # the radio, and _note_wifi_power emits it in place of the misleading write.
    com.apple.airport.preferences)
      case "$keyname" in
        PowerEnabled) return 0 ;;
      esac
      ;;

    # desktoppr's own record of the image it last applied. Writing the key back
    # sets no wallpaper. It only forges that record on the target. Filter the
    # misleading command; _note_desktoppr emits the command that DOES apply it.
    com.scriptingosx.desktoppr)
      case "$keyname" in
        lastPath) return 0 ;;
      esac
      ;;

  esac

  return 1
}

# Edge-case safety net for defaults commands that bypass key-level filtering
# (invalid plutil output artifacts and float-encoded window positions)
is_noisy_command() {
  local cmd="$1"

  # Filter invalid commands with <type> <value>
  if [[ "$cmd" == *'<type> <value>'* ]]; then
    return 0
  fi

  # Filter float window/scroll positions that slip through key-level filtering
  case "$cmd" in
    *"-float"*NSWindow*|*"-float"*Scroll*|*"-float"*Position*)
      return 0
      ;;
  esac

  # ARD Computer Info fields (Text1-4) initialised EMPTY when Remote Management
  # is enabled. Side-effect of the toggle. Keep them when they carry a value.
  case "$cmd" in
    *com.apple.RemoteDesktop*'"Text'[1-4]'" -string ""')
      return 0
      ;;
  esac

  return 1
}

# Element-level noise (_ELEMENT_NOISE_MARKERS, below): an array element is churn
# when a marker value appears anywhere in its dict, and the whole element is
# skipped. The shell filters one emitted line at a time and, on a deletion, never
# sees the values at all, so the list lives here and is handed to the Python
# workers as data. Format domain|array|marker, scoped to ONE array on purpose:
# CharacterPaletteIM is churn in AppleSelectedInputSources (the Character Viewer
# adds and removes itself) and a deployable setting in AppleEnabledInputSources.
#
# Print presets (_PRINT_PRESET_NOISE): the one noise list for
# com.apple.print.custompresets*, a REJECT list matched as globs on both sides
# (zsh `case`, Python fnmatchcase). The former whitelist named keys no machine
# has and dropped the preset's own name, colour model and paper size; the
# worker's copy used the same strings as prefixes, where a leading `*` matches
# nothing. One list, one meaning.
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

# Filter noisy key paths in PlistBuddy commands
# Extracts top-level key and delegates to is_noisy_key(), then checks sub-key patterns
# Args: $1 = domain, $2 = PlistBuddy command (e.g., "Add :persistent-apps:0:tile-data dict")
is_noisy_pbcmd() {
  local domain="$1" pb_cmd="$2"

  # Binary data is never useful
  [[ "$pb_cmd" == *"<data:"* ]] && return 0

  # Extract top-level key from PBCMD path
  # Format: "Add :TopKey:SubKey type value" or "Set :TopKey value" or "Delete :TopKey"
  # Spaces in key names are escaped as '\ ' by Python
  local _raw="${pb_cmd#* :}"                    # strip verb + ":"
  local _safe="${_raw//\\ /__PBSP__}"           # protect escaped spaces
  local _top="${_safe%%:*}"                      # first segment (before next ":")
  _top="${_top%% *}"                             # strip trailing type/value if no sub-key
  # Handle top-level-only: "Add :key dict" → _top may end with placeholder+type
  local _t
  for _t in dict array string integer real bool; do
    [[ "$_top" == *"__PBSP__${_t}" ]] && _top="${_top%__PBSP__${_t}}"
  done
  _top="${_top//__PBSP__/ }"                    # restore spaces

  # Delegate to is_noisy_key for top-level key filtering
  [ -n "$_top" ] && is_noisy_key "$domain" "$_top" && return 0

  # Sub-key patterns (nested paths, not checkable via is_noisy_key)
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

  # NetworkExtension VPN internal keychain markers (__NEVPNKeychainDomain, …):
  # VPN clients (e.g. FortiClient) re-register their network service on wake,
  # re-adding these internal refs. Not user VPN config (server/auth have no __ prefix).
  case "$pb_cmd" in
    *":__NEVPN"*) return 0 ;;
  esac

  # Domain-specific sub-key patterns (need full path matching)
  case "$domain" in
    com.apple.finder|com.apple.Finder)
      case "$pb_cmd" in
        # Column widths (resize noise).
        *":columns:"*":width "*)
          return 0 ;;
        # axTextSize is derived: the Finder recomputes it in every view dict from
        # `universalaccess FontSizeCategory`, whose command reproduces the change, and
        # one text-size change would otherwise flood ~18 Set lines. Cmd+J's
        # textSize/iconSize/FontSize stay real.
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
      # 'deletedUsers' is a bookkeeping record of removed accounts. Replaying
      # the Add commands just creates a phantom entry, it does NOT delete a
      # user. useracct_watch reports the real add/remove via a NOTE instead.
      case "$pb_cmd" in
        *":deletedUsers"*) return 0 ;;
      esac
      ;;
    preferences)
      # SystemConfiguration/preferences.plist is configd's: a raw PlistBuddy Set on it
      # is unreliable, and its network tree is keyed by service UUIDs minted on THIS
      # Mac (a VPN client re-adding its service on wake mints a new one and rewrote
      # ~65 lines for an identical config). Hostnames → hostname_watch emits
      # `scutil --set`; :NetworkServices/:Sets → _note_network_service emits the
      # networksetup lines or one NOTE; :CurrentSet → _note_network_location emits
      # `scselect <name>`.
      case "$pb_cmd" in
        *":System:Network:HostNames:"*|*":System:System:ComputerName"*|\
        *":NetworkServices:"*|*":Sets:"*":Network:"*|*":CurrentSet"*) return 0 ;;
      esac
      ;;
    com.apple.TimeMachine)
      # Noisy: disk space metrics (change on every backup), snapshot counters,
      # filesystem state detection. Keeps: ID, Kind, QuotaGB, Name (user config)
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
      # The Character Palette adds and removes itself on open/close, but ONLY in
      # AppleSelectedInputSources: in AppleEnabledInputSources (Settings > Keyboard)
      # enabling it is a deployable setting. A bare *CharacterPaletteIM* silenced both.
      case "$pb_cmd" in
        *":AppleSelectedInputSources:"*"CharacterPaletteIM"*)
          return 0 ;;
      esac
      ;;
    com.apple.MobileSMS)
      # Noisy: Scrutiny analytics (contact tracking, timestamps), app-browser
      # "seen" entries (a Delete per extension the drawer stops listing)
      case "$pb_cmd" in
        *":Scrutiny:"*|*":Scrutiny "*|*":kCKBrowserSelectionControllerSeenDictionaryKey:"*)
          return 0 ;;
      esac
      ;;
    com.apple.iPod)
      # Per-device sync bookkeeping under Devices:<hex-id>: (Connected timestamp, Use
      # Count), rewritten on every connect; nested, so only matched here.
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

# Core log function. All log_* wrappers delegate here
# Usage: _log <syslog_tag> <message>
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
      # Only ALL mode may drop an excluded domain: named explicitly, a domain is
      # watched (without this guard the run promised to monitor, then swallowed
      # every `defaults write`).
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

# Log wrappers (thin delegates to _log with appropriate syslog tag)
log_line()   { _log "$DOMAIN_TAG" "$1"; }
log_user()   { _log "user" "$1"; }
log_system() { _log "system" "$1"; }

# Snapshot log. Verbose: all lines, ONLY_CMDS: start/complete only
snapshot_notice() {
  local msg="$1" verbose_only="${2:-false}"
  local ts
  ts="$(get_timestamp)"
  local line="[$ts] [snapshot] $msg"
  if [ "$verbose_only" = "true" ] && [ "${ONLY_CMDS:-false}" = "true" ]; then
    # In ONLY_CMDS mode, skip entirely (no terminal, no log, no syslog)
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

# Stable text output of a plist
dump_plist() {
  local src="$1" out="$2"
  # Try plutil -p (single call), fall back to raw copy on failure
  if ! /usr/bin/plutil -p "$src" > "$out" 2>/dev/null; then
    /bin/cat "$src" > "$out" 2>/dev/null || :
  fi
}

# JSON output of a plist
dump_plist_json() {
  local src="$1" out="$2"
  if [ ! -f "$src" ]; then
    : > "$out" 2>/dev/null || true
    return
  fi
  # plistlib first, plutil as a fallback: `plutil -convert json` writes an
  # integral float as `2`, which reads back as an int and would emit `integer 2`
  # for a real (caught by the array-float case); json.dump writes 2.0. plutil
  # already fails on <data> and <date>, so this is what the engine saw for those.
  # ~38ms vs ~5ms, paid only when a plist changes, never during the snapshot.
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
  # Fallback when python3 is absent or plistlib chokes: plutil, lossy on integral
  # floats but better than no JSON at all (the array/dict diff engine needs it).
  if /usr/bin/plutil -convert json -o "$out" "$src" >/dev/null 2>&1; then
    [ -s "$out" ] && return
  fi
  : > "$out" 2>/dev/null || true
}

# Extract type and value of a key with plutil
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

# Convert a `defaults … delete …` command to PlistBuddy. $2 = the real plist
# path: the `-currentHost` flag does not survive the conversion (the regex
# discards it and get_plist_path has no ByHost branch), so a ByHost deletion
# used to target ~/Library/Preferences/<dom>.plist instead of the ByHost file.
convert_delete_to_plistbuddy() {
  # $3 = OPTIONAL domain, passed straight from the caller. Re-deriving it by
  # regex over a command string this very file just built is fragile by
  # construction, and it broke the moment the domain gained its (necessary)
  # quotes: the pattern captured `"com.foo"` WITH them, and get_plist_path then
  # produced a path containing literal quote characters. Callers know the domain
  # - hand it over instead of parsing it back out. The regex stays as a fallback
  # so an outside caller passing only a command string still works.
  local cmd="$1" path_override="${2:-}" domain_override="${3:-}"

  local domain target
  if [ -n "$domain_override" ]; then
    domain="$domain_override"
  else
    domain=$(printf '%s' "$cmd" | /usr/bin/sed -nE 's/.*defaults([[:space:]]+-[^[:space:]]+)*[[:space:]]+delete[[:space:]]+"?([^"[:space:]]+)"?.*/\2/p')
  fi
  # The target is the LAST quoted field. Anchoring on the end survives a domain
  # that itself contains a space (15 such domains on one ordinary Mac).
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
    # The "# WARNING: array deletes" prefix is a DEDUP KEY matched by _emit_cmd and
    # emit_array_deletions (this runs in a $() subshell, so a flag here would be
    # lost). Change the wording and both `case` patterns together.
    printf '# WARNING: array deletes shift indexes. Run these in the order shown\n'
  fi
  local _mdm_path=$(mdm_plist_path "$plist_path")
  # Escape single quotes in the key path so a key containing ' doesn't break the
  # single-quoted PlistBuddy -c 'Delete …' expression (each ' → '\'').
  local _target_esc
  _target_esc=$(printf '%s' "$target" | /usr/bin/sed "s/'/'\\\\''/g")
  # The path sits inside double quotes but was never escaped. And it carries the
  # same attacker-chosen filename as the domain. Escape AFTER templatizing so the
  # deliberate $loggedInUser / $UUID tokens keep working (see mdm_plist_path).
  printf '/usr/libexec/PlistBuddy -c '\''Delete %s'\'' "%s"\n' "$_target_esc" "$(_escape_pb_path "$_mdm_path")"
  return 0
}

# ---------------------------------------
# Command Emission
# ---------------------------------------
# Builds the `defaults`/PlistBuddy commands and routes them through the
# filters/logging. The bridge between the diff engine and the log output.

# Single quote and its shell-escaped form ('\''), assembled character by
# character: spelled inline in a ${var//…/…} replacement it silently yields
# the wrong string (verified).
typeset -g _SQ="'"
typeset -g _SQ_ESC="${_SQ}\\${_SQ}${_SQ}"

# Escape a plist PATH for a double-quoted shell string (backslash, ", $ and
# backtick, like _escape_dq) while PRESERVING the two tokens mdm_plist_path
# injects on purpose ($loggedInUser, $UUID), which must expand at replay time.
_escape_pb_path() {
  local _p _liu_esc _uid_esc _uid_tok
  _p=$(_escape_dq "$1")
  # Derive the tokens' escaped forms with the SAME escaper rather than spelling
  # `\$loggedInUser` inline: written literally, zsh expands it in THIS shell,
  # where it is unset, and `set -u` aborts.
  _uid_tok='$UUID'
  _liu_esc=$(_escape_dq "$_MDM_LIU")
  _uid_esc=$(_escape_dq "$_uid_tok")
  _p="${_p//"$_liu_esc"/"$_MDM_LIU"}"
  _p="${_p//"$_uid_esc"/"$_uid_tok"}"
  printf '%s' "$_p"
}

_escape_dq() { printf '%s' "$1" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g; s/`/\\`/g'; }

# Build `defaults write …` for dom/keyname/trimmed via type cascade.
# Stdout = command, or empty for array/dict (not flat-writable).
# Args: dom keyname trimmed hostflag plist_path
_build_defaults_write_cmd() {
  local dom="$1" keyname="$2" trimmed="$3" hostflag="$4" plist_path="$5"
  local actual_type="" type_val noquotes str cmd=""
  local plutil_result plutil_type plutil_value

  # Harden the KEY like a value (_escape_dq): inside a double-quoted shell string
  # a " or $ or backtick would break the command, or run a substitution when the
  # line is pasted. The probe below keeps the RAW key, passed as an argv word.
  local _kn; _kn=$(_escape_dq "$keyname")

  # System-level pref: emit (and type-probe) the root-owned /Library/Preferences
  # file by full path. `defaults` accepts a path in place of a bare domain and
  # appends .plist. A bare domain would replay into the console user's ~ copy.
  [ "${_EMIT_SYS:-false}" = "true" ] && [[ "$dom" != /* ]] && dom="${_EMIT_SYS_DOM:-/Library/Preferences/${dom}}"

  # The DOMAIN is a plist FILENAME, free text, and gets the same treatment as the
  # key. Correctness: 15 domains on one Mac contain a space ("com.topazlabs.Topaz
  # Photo AI"), and unquoted the write lands in the wrong domain. Security: any
  # process running as the user can create com.x$(curl…|sh).plist, and this line
  # is replayed by an admin in a root shell (verified end to end).
  local _dm; _dm=$(_escape_dq "$dom")

  # Probe the type as the CONSOLE USER: as root a bare `defaults read-type` reads
  # ROOT's domain, fails, and the 0/1 heuristic below then emitted `-bool` for an
  # `-int 0` (proven on wvous-tr-modifier). System prefs are a path: root reads.
  # The space stays OUTSIDE the braces: `${hostflag:+$hostflag }read-type` is ONE
  # word in zsh, which `defaults` rejects, and every ByHost scalar then fell
  # through to the heuristic. Empty $hostflag still collapses to nothing.
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

# Build `defaults [hostflag] delete dom "target"`. Target is :array:idx
# when array_name is set, else keyname. Args: dom keyname array_name array_idx hostflag
_build_defaults_delete_cmd() {
  local dom="$1" keyname="$2" array_name="$3" array_idx="$4" hostflag="$5"
  local target
  if [ -n "$array_name" ]; then
    target=":${array_name}:${array_idx}"
  else
    target="$keyname"
  fi
  # Same hardening as the write emitter: the target lands inside a double-quoted
  # shell string, so " / $ / backtick in a key must not break (or execute in) the
  # emitted command. Array targets are digits+name and unaffected in practice.
  target=$(_escape_dq "$target")
  # Same as the write builder: the domain is a filename, so quote AND escape it.
  local _dm; _dm=$(_escape_dq "$dom")
  if [ -n "$hostflag" ]; then
    printf 'defaults %s delete "%s" "%s"' "$hostflag" "$_dm" "$target"
  else
    printf 'defaults delete "%s" "%s"' "$_dm" "$target"
  fi
}

# A NOTE laid out for Console: "# NOTE: " on the first line, "#       " on the
# others, one sentence or clause per line (split after ". " and "; "), a
# sentence over 110 characters folded on a space. Console wraps at the window
# edge with no "#" on the wrapped part, which reads as a command. $1 kind
# (USER/SYSTEM/"" for log_line), $2 the text.
_log_note_wrapped() {
  local _kind="$1" _t="$2" _first=true _l _s _m=$'\x1e'
  local -a _parts
  # Mark sentence ends, then split there. \x1e never occurs in a note.
  _t="${_t//. /.$_m}"; _t="${_t//; /;$_m}"
  _parts=("${(@ps:\x1e:)_t}")
  for _s in "${_parts[@]}"; do
    [ -n "$_s" ] || continue
    while IFS= read -r _l; do
      _l="${_l%% }"
      [ -n "$_l" ] || continue
      if [ "$_first" = true ]; then _log_kind "$_kind" "Cmd: # NOTE: $_l"; _first=false
      else _log_kind "$_kind" "Cmd: #       $_l"; fi
    done < <(printf '%s\n' "$_s" | /usr/bin/fold -s -w 110)
  done
}

_log_kind() {
  # A deferred "new domain" NOTE (see _process_diff_lines) goes out just before
  # the first line this domain actually produces, and never on its own.
  if [ -n "${_PENDING_NEWDOM_NOTE:-}" ] && [[ "$2" == "Cmd: "* ]]; then
    local _ndn="$_PENDING_NEWDOM_NOTE"
    typeset -g _PENDING_NEWDOM_NOTE=""
    _log_kind "$1" "$_ndn"
  fi
  case "$1" in
    USER)   log_user   "$2" ;;
    SYSTEM) log_system "$2" ;;
    *)      log_line   "$2" ;;
  esac
}


# One-per-burst NOTE for a ColorSync command targeting a monitor by its
# CoreGraphics UUID (`Device.mntr.<UUID>`): that UUID differs per display AND
# per Mac (two identical monitors → different UUIDs), so mdm_plist_path cannot
# templatize it and the NOTE points at the runtime `defaults -currentHost read`
# lookup. Scoped to `Device.mntr.`: a bare "any UUID" match also fired on
# NSToolbar Configuration and account UUIDs, where the advice is wrong.
_note_device_uuid() {
  local kind="$1" key="$2"
  [[ "$key" == *"Device.mntr."[0-9A-Fa-f]* ]] || return 0
  _note_should_show __device_uuid__ || return 0
  # Two lines, not three: the display list command rides on the sentence that
  # calls for it. The "--mdm can't templatize it" half is only meaningful to
  # someone who asked for deployable output.
  _log_kind "$kind" "Cmd: # NOTE: Device.mntr.<UUID> is the DISPLAY's own UUID, per-monitor and different on every Mac."
  if [ "$MDM_OUTPUT" = "true" ]; then
    _log_kind "$kind" "Cmd: #       --mdm cannot templatize it. On the target: defaults -currentHost read -g com.apple.ColorSync.Devices"
  else
    _log_kind "$kind" "Cmd: #       To replay elsewhere, list the displays there: defaults -currentHost read -g com.apple.ColorSync.Devices"
  fi
}

# Network service order (System Settings > Network > Set Service Order).
# ServiceOrder lists UUIDs minted here, but `networksetup -ordernetworkservices`
# takes the services' NAMES, so the priority transplants. Returns 1 (caller
# emits the generic NOTE) when the set is not CurrentSet (networksetup only
# reorders the current location), a service has no name, or two share one. The
# names are user text pasted into a root shell: escaped like a value (\ " $ `).
_note_network_order() {
  local kind="$1" cmd="$2" path="${3:-}" set_uuid names
  [ -n "$PYTHON3_BIN" ] || return 1
  # The diffed file itself when we were handed it; the canonical path otherwise
  # (show_domain_diff resolves domain `preferences` to a ~/Library path that does
  # not exist. Reading it would silently produce no command).
  [ -r "$path" ] || path="/Library/Preferences/SystemConfiguration/preferences.plist"
  [ -r "$path" ] || return 1
  set_uuid="${cmd#*:Sets:}"; set_uuid="${set_uuid%%:*}"
  [ -n "$set_uuid" ] || return 1
  # `-ordernetworkservices` takes exactly the services networksetup itself
  # lists, and that list can be SHORTER than the plist's ServiceOrder: a VM on
  # 27.0 had two services in the set, both active, both interfaces up, and
  # networksetup listed one. So the order is intersected with
  # `-listallnetworkservices` (read on this Mac, the `*` of a disabled service
  # stripped) and the NOTE names what was left out.
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
    # CurrentSet is a path, e.g. /Sets/<UUID>
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

# Switching network location rewrites :CurrentSet, a /Sets/<UUID> path that
# means nothing on another Mac. `scselect` takes the location NAME and applies
# it immediately, so that is emitted. Returns 1 (caller emits the generic NOTE)
# when the current set has no name or two locations share one.
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
    # scselect matches on the name, so a shared name is ambiguous.
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

# DNS, search domains, proxies, the TCP/IP method and the service on/off switch:
# every `networksetup` verb here addresses the service BY NAME (UserDefinedName),
# so the UUID-keyed subtree still yields a portable command. Only the group of
# keys that changed is emitted, never the whole service. The verbs are those
# `networksetup -help` lists on 26.6.2: no -setftpproxy, -setgopherproxy,
# -setstreamingproxy, -setpassiveftp, whose keys fall through to the generic
# NOTE. Returns 1 (caller emits that NOTE) for an unmapped key, an unnamed
# service, two services sharing a name, or an enabled proxy with no host.
_note_network_svc_setting() {
  local kind="$1" cmd="$2" path="${3:-}" uuid group out line
  [ -n "$PYTHON3_BIN" ] || return 1
  [ -r "$path" ] || path="/Library/Preferences/SystemConfiguration/preferences.plist"
  [ -r "$path" ] || return 1
  uuid="${cmd#*:NetworkServices:}"; uuid="${uuid%%:*}"
  [ -n "$uuid" ] || return 1
  # Disabling a service writes __INACTIVE__ right under the service: test it
  # FIRST, on the segment after the UUID (the same key lives under DNS with
  # another meaning, and the main case ends in a `return 1`).
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
    # networksetup addresses the CURRENT location's services, and names need only
    # be unique there: a real Mac carries stale services from other locations
    # (two named "Wi-Fi" here), and a global uniqueness test refused every command.
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
    # The command addresses a service BY NAME, so a name shared inside the
    # current location is ambiguous and would configure the wrong one.
    if [(services.get(u) or {}).get('UserDefinedName') for u in order].count(name) != 1:
        sys.exit(1)

    who = quoted(name)
    dns = service.get('DNS') or {}
    proxies = service.get('Proxies') or {}
    NS = 'sudo /usr/sbin/networksetup'
    lines = []

    def listing(values):
        # networksetup clears a list with the literal word Empty.
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
        # Only the configuration methods with a documented one-to-one verb, each
        # refusing unless the values it needs are there; a shape that does not match
        # produces the generic NOTE, never a guessed command. INFORM and PPP fall
        # through on purpose.
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

# One-per-burst NOTE for the rest of the filtered network tree: a service is
# keyed by a UUID minted on THIS Mac (and re-minted when a VPN agent re-adds
# its service on wake, ~65 lines for an identical config), so the path replays
# nowhere. Say what changed and name the real reproducers.
_note_network_service() {
  local kind="$1" dom="$2" cmd="$3" path="${4:-}"
  [ "$dom" = preferences ] || return 0
  case "$cmd" in
    # An order change IS reproducible: emit the command instead of a NOTE that
    # says it wasn't. Fall through to that NOTE only when it can't be built.
    *":CurrentSet"*)
      if _note_network_location "$kind" "$path"; then return 0; fi
      ;;
    *":Network:Global:IPv4:ServiceOrder"*)
      if _note_network_order "$kind" "$cmd" "$path"; then return 0; fi
      ;;
    # DNS, proxies, the TCP/IP method and the service's own on/off switch are
    # reproducible too. Same fall-through rule as the order.
    *":NetworkServices:"*":DNS:"*|*":NetworkServices:"*":Proxies:"*|\
    *":NetworkServices:"*":IPv4:"*|*":NetworkServices:"*":IPv6:"*|\
    *":NetworkServices:"*":__INACTIVE__"*)
      if _note_network_svc_setting "$kind" "$cmd" "$path"; then return 0; fi
      ;;
    *":NetworkServices:"*|*":Sets:"*":Network:"*) ;;
    *) return 0 ;;
  esac
  _note_should_show __network_service__ || return 0
  _log_note_wrapped "$kind" "network service configuration changed (VPN / proxies / DNS / service order). Not emitted: configd owns this file and each service is keyed by a UUID minted on this Mac (a VPN client recreating its service mints a new one). Reproduce with networksetup where it has a verb for the setting, or a configuration profile for a VPN (a 'com.apple.payload' subtree means the service is already profile-managed, so deploy the profile, not this file)."
}

_note_byhost_uuid() {
  local kind="$1" path="$2" key="${3:-}"
  # A Device.mntr.<UUID> key carries the DISPLAY's own UUID that --mdm can't
  # templatize. _note_device_uuid says exactly that, and this note's "re-run with
  # --mdm for a deployable form" would contradict it. Let the device note own it.
  [[ "$key" == *"Device.mntr."[0-9A-Fa-f]* ]] && return 0
  case "$path" in
    # MDM mode: the path is templatized to $UUID + $loggedInUser, whose resolvers are
    # emitted ONCE at startup (see MAIN). So a templatized ByHost path adds nothing here.
    # (Return early so it doesn't fall through to the non-mdm */ByHost/* note below.)
    *'$UUID'*)
      return 0
      ;;
    # Normal mode: the literal UUID is correct for replay HERE, and useless
    # anywhere else. Say so, and point at the flag that makes it deployable.
    */ByHost/*)
      _note_should_show __byhost_uuid__ || return 0
      _log_note_wrapped "$kind" "this ByHost filename holds THIS Mac's hardware UUID. The path is valid on this Mac only; re-run with --mdm for a deployable form"
      ;;
  esac
}

# --debug: log a diagnostic when a DETECTED change is dropped by a filter,
# so "why didn't my change appear?" has an answer. Silent unless --debug.
_dbg_filtered() { [ "${DEBUG_FILTER:-false}" = "true" ] && log_line "Cmd: # FILTERED: $1"; return 0; }  # ALWAYS return 0: called standalone in then-blocks under set -e, so a non-zero (debug OFF → the [ ] fails, && short-circuits) would ABORT the shell

# --mdm: prefix a USER-domain command with `runAsUser` (defined in the --mdm
# header): replayed by a root Jamf policy it would otherwise write ROOT's prefs
# or reparent the user's plist to root:wheel. System-level commands (_EMIT_SYS)
# stay plain root. No-op outside --mdm; only real command lines are passed in.
_mdm_wrap() {
  if [ "${_EMIT_SYS:-false}" = "true" ]; then
    # System-level pref (root-owned file under /Library/Preferences): `sudo`, like
    # every tool command here. Under --mdm the policy is already root and sudo is a
    # no-op, so one form serves both.
    printf 'sudo %s' "$1"
  elif [ "$MDM_OUTPUT" = "true" ]; then
    printf 'runAsUser %s' "$1"
  else
    printf '%s' "$1"
  fi
}

# A `# dockutil …` comment is a command an admin copies out, editing the
# logged-in user's Dock, so under --mdm it gets the same runAsUser; the `#`
# stays leading. `# Dock: <label>` is left alone.
_mdm_wrap_comment() {
  case "$1" in
    "# dockutil "*) printf '# %s' "$(_mdm_wrap "${1#"# "}")" ;;
    *)             printf '%s' "$1" ;;
  esac
}

# Emit a built defaults cmd via _log_kind, applying filters/NOTE/gate.
# Deletes go through convert_delete_to_plistbuddy.
# Args: kind cmd note_dom is_delete
_emit_cmd() {
  # $5 = OPTIONAL real plist path, forwarded to convert_delete_to_plistbuddy so a
  # ByHost deletion targets the ByHost file (see that function's comment).
  local kind="$1" cmd="$2" note_dom="$3" is_delete="$4" emit_plist_path="${5:-}"

  [ -n "$cmd" ] || return 0
  if is_noisy_command "$cmd"; then _dbg_filtered "${note_dom:-?} (noise/invalid command)"; return 0; fi

  # In ALL mode the DOMAIN pass is redundant: the per-plist diff already emitted
  # every change it sees (with ONLY_CMDS in the condition, `--verbose` printed
  # each command twice). BEFORE the contextual note: the duplicate used to feed
  # the bulk counter and print the "writes every default" note over nothing.
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
    if pb_delete=$(convert_delete_to_plistbuddy "$cmd" "$emit_plist_path" "$note_dom" 2>/dev/null); then
      while IFS= read -r pb_line; do
        [ -n "$pb_line" ] || continue
        case "$pb_line" in
          # "Cmd: " prefix on comment lines too, else ONLY_CMDS (Jamf) drops them.
          "# WARNING: array deletes"*)
            _note_should_show __array_del_warning__ && _log_kind "$kind" "Cmd: $pb_line" ;;
          "#"*) _log_kind "$kind" "Cmd: $pb_line" ;;
          *)    _note_byhost_uuid "$kind" "$pb_line" "${${pb_line#*-c \'}%%\'*}"
                # Key expression only. Strip the trailing file path, whose ByHost
                # UUID is the Mac's and is a different concern.
                _note_device_uuid "$kind" "${${pb_line#*-c \'}%%\'*}"
                _log_kind "$kind" "Cmd: $(_mdm_wrap "$pb_line")" ;;
        esac
      done <<< "$pb_delete"
    else
      _log_kind "$kind" "Cmd: $(_mdm_wrap "$cmd")"
    fi
  else
    # MDM: templatize a user-home path embedded in a string VALUE the same way
    # (mdm_plist_path only touches the plist file path, not values like a path pref).
    if [ "$MDM_OUTPUT" = "true" ] && [[ "$cmd" == *"$TARGET_HOME"* ]]; then
      cmd="${cmd//"$TARGET_HOME"/$_MDM_HOME_REPL}"
    fi
    _log_kind "$kind" "Cmd: $(_mdm_wrap "$cmd")"
  fi
}

# Consume the tab-separated stream of the Python workers: PBCMD lines → emit
# via _log_kind; metadata lines → the global _SKIP_KEYS (an empty plist_path
# skips the PBCMDs but still fills _SKIP_KEYS). Args: kind dom meta_raw plist_path.
_process_py_meta() {
  local kind="$1" dom="$2" meta_raw="$3" plist_path="$4"
  [ -n "$meta_raw" ] || return 0

  local _domain_note_emitted=false _last_array_base=""
  local -a _pending_comments=()
  local _array_base _array_idx _array_keys _pb_cmd _pc _k _mdm_path _pb_esc pb_full
  local -a _array_key_list

  while IFS=$'\t' read -r _array_base _array_idx _array_keys; do
    [ -n "$_array_base" ] || continue
    if [ "$_array_base" = "PBCMD" ]; then
      _pb_cmd="$_array_idx"
      # Buffer comments until a real command makes it through filtering
      if [[ "$_pb_cmd" == "#"* ]]; then
        _pending_comments+=("$_pb_cmd")
        continue
      fi
      [ -n "$plist_path" ] || continue
      if is_noisy_pbcmd "$dom" "$_pb_cmd"; then
        # A filtered SystemConfiguration network path still deserves an answer.
        # emit the NOTE naming the real reproducer in place of the dropped command.
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
      # $_pb_cmd = the key expression only; never the file path (whose ByHost UUID
      # is the Mac's, a different thing handled by _note_byhost_uuid above).
      _note_device_uuid "$kind" "$_pb_cmd"
      # MDM: mdm_plist_path templatized the FILE path; also rewrite the capture user's
      # home inside the VALUE (a dock _CFURLString / login-item path in ~ would otherwise
      # leak the capture user). Quote the pattern so it matches literally, not as a glob.
      local _mdm_home_hit=false
      if [ "$MDM_OUTPUT" = "true" ] && [[ "$_pb_cmd" == *"$TARGET_HOME"* ]]; then
        _pb_cmd="${_pb_cmd//"$TARGET_HOME"/$_MDM_HOME_REPL}"
        _mdm_home_hit=true
      fi
      # Escape single quotes in the PBCMD (each ' → '\'') for the single-quoted -c
      # wrapper, with a builtin; the replacement is built character by character,
      # since '\'' written inline in a substitution silently yields the wrong string.
      _pb_esc="${_pb_cmd//$_SQ/$_SQ_ESC}"
      # …then break out of those single quotes around the templatized $loggedInUser
      # so the shell actually expands it at run time (single quotes would keep it literal).
      [ "$_mdm_home_hit" = true ] && _pb_esc="${_pb_esc//"$_MDM_LIU"/$_MDM_LIU_QB}"
      pb_full="/usr/libexec/PlistBuddy -c '${_pb_esc}' \"$(_escape_pb_path "$_mdm_path")\""
      _log_kind "$kind" "Cmd: $(_mdm_wrap "$pb_full")"
      continue
    fi
    # Metadata line. Populate _SKIP_KEYS at every level the Python
    # workers may have produced (top key, top:sub, base:idx:sub, etc.)
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
  # Flush the buffered comments: a NOTE can be the only output (_note_empty_key
  # fires INSTEAD of the commands it skips). Except the two that INTRODUCE
  # commands ("array index :N is positional", "new key tree"): when every PBCMD of
  # the batch was filtered they would print over nothing (seen on 27.0, a Finder
  # window adding a recent folder).
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

# Walk the unified diff(prev,curr) and emit write/delete via _emit_cmd
# for each key not pre-handled by _SKIP_KEYS / is_noisy_key. type_src is
# the plist used by _build_defaults_write_cmd for plutil-fallback;
# diff_label tags the "Diff <label>:" log lines.
# Args: kind dom hostflag prev curr type_src diff_label
# Reads: _SKIP_KEYS, _HAS_ARRAY_ADDITIONS.
_process_diff_lines() {
  # $8 = OPTIONAL real plist path for delete emission. Deliberately NOT type_src:
  # show_plist_diff passes the real file there, but show_domain_diff passes a
  # CACHE file ($tmpplist). Reusing it would point PlistBuddy at the cache.
  # Domain mode passes empty and keeps the get_plist_path fallback.
  local kind="$1" dom="$2" hostflag="$3" prev="$4" curr="$5" type_src="$6" diff_label="$7" emit_plist_path="${8:-}"

  # No baseline. Emit or stay silent, by caller: show_plist_diff (USER/SYSTEM)
  # had a baseline for every plist that existed at startup, so a missing one is a
  # domain born since, and its first write is its configuration. show_domain_diff
  # (DOMAIN) in ALL mode writes its baseline lazily, so "missing" only means "not
  # seen yet" and emitting would dump every domain that ever changes: keep the
  # guard there. In single-domain mode start_watch baselines first, so a domain
  # appearing later is reportable.
  if [ ! -s "$prev" ]; then
    [ "${_BASELINE_DONE:-false}" = "true" ] || return 0
    [ "$kind" = "DOMAIN" ] && [ "${ALL_MODE:-false}" = "true" ] && return 0
    # An EXISTING but empty baseline is a FAILED snapshot (cfprefsd unlinked and
    # recreated the plist mid-scan; a genuinely empty plist dumps as "{\n}"), never
    # a new domain: treating it as novelty dumped a 3-key domain whole. Adopt the
    # current state as the baseline and stay silent.
    if [ -e "$prev" ]; then
      /bin/cp -f "$curr" "$prev" 2>/dev/null || :
      return 0
    fi
    # `prev` does not EXIST. And `diff -u <missing> curr` fails outright, printing
    # nothing. Lifting the guard alone therefore emitted the note and no commands at
    # all. Materialise an empty baseline so every key shows up as an addition.
    : > "$prev" 2>/dev/null || return 0
    # DEFERRED: "the commands below" must be followed by a line, and a domain whose
    # every key is filtered printed it over nothing. _log_kind flushes it before
    # this domain's first line; cleared at the end of this pass.
    if _note_should_show "__newdom__:${dom}"; then
      typeset -g _PENDING_NEWDOM_NOTE="Cmd: # NOTE: '$dom' is a new domain. The commands below are its full configuration, not a single change"
    fi
  fi

  typeset -A _added_keys
  _added_keys=()
  local _aline
  while IFS= read -r _aline; do
    # Builtin regex. Was a sed fork per ADDED diff line. Wrapped in `if` (not
    # `[[ … ]] && …`): a non-matching line would make the loop body's last command
    # return 1, which is exactly the shape that can trip ERR_EXIT under `set -e`.
    if [[ "$_aline" =~ '^\+[[:space:]]*"([^"]+)"' ]]; then _added_keys["$match[1]"]=1; fi
  done < <(/usr/bin/diff -u "$prev" "$curr" 2>/dev/null | /usr/bin/awk 'NR>2 && $0 ~ /^\+/ && $0 !~ /^\+\+\+/' || true)  # diff exits 1 when files differ (always, here) → pipefail fires ZERR/set -e; guard it

  local dline kv keyname val snippet pretty_key array_meta array_name array_idx trimmed cmd delete_cmd
  while IFS= read -r dline; do
    [ -n "$dline" ] || continue

    _log_kind "$kind" "Diff $diff_label: $dline"

    array_meta="" array_name="" array_idx=""
    # Builtin regex instead of a sed fork per diff line. $match yields the key and
    # the value directly, so they no longer round-trip through a `key|value` string.
    [[ "$dline" =~ '^[+-][[:space:]]*"([^"]+)"[[:space:]]*=>[[:space:]]*(.*)$' ]] || continue
    keyname="$match[1]"
    val="$match[2]"

    [ -n "${_SKIP_KEYS[$keyname]:-}" ] && continue

    # Secondary filter: PBCMD-driven runs may leak sub-keys of dict
    # additions into the top-level diff text. Detect & drop them.
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

    # Newlines to spaces, truncated to 160 with an ellipsis. Builtin (was tr+awk).
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
        # Verify key is truly gone (not just value-changed) by re-scanning $curr
        if [ -z "$array_name" ] && /usr/bin/grep -qF "\"$keyname\" =>" "$curr" 2>/dev/null; then
          continue
        fi
        delete_cmd=$(_build_defaults_delete_cmd "$dom" "$keyname" "$array_name" "$array_idx" "$hostflag")
        _emit_cmd "$kind" "$delete_cmd" "$dom" true "$emit_plist_path"
        ;;
    esac
  done < <(/usr/bin/diff -u "$prev" "$curr" 2>/dev/null | /usr/bin/awk 'NR>2 && ($0 ~ /^\+/ || $0 ~ /^-/) && $0 !~ /^\+\+\+|^---/' || true)  # diff exits 1 when files differ (always, here) → pipefail fires ZERR/set -e; guard it
  # Nothing came out for this new domain: the NOTE stays unsaid, and must not
  # ride in front of the next domain's first line.
  typeset -g _PENDING_NEWDOM_NOTE=""
}

# ---------------------------------------
# Diff Engine
# ---------------------------------------

# Parse an array index key (:AppleEnabledInputSources:3 -> AppleEnabledInputSources 3)
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

# Detect and emit commands for array additions
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

# Element-level noise rules from the shell (_ELEMENT_NOISE_MARKERS),
# domain|array|marker triplets: an element carrying the marker is skipped
# WHOLE, since filtering line by line leaves a half-built dict.
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

# SHARED BLOCK, repeated verbatim in the three Python workers so each heredoc
# stays self-contained. EDIT ALL THREE TOGETHER. Volatile metadata rewritten on
# every plist save is stripped before comparing elements.
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
        # Pre-compute stable fingerprints (ignoring volatile metadata)
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
        # PlistBuddy strips a leading regular space from an unquoted value; quote
        # values with leading/trailing whitespace (escaping any internal ") so
        # they round-trip. Values without edge whitespace stay unquoted as before.
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
                    # nested list-in-list left as an empty array (vanishingly rare)
            else:
                tv = pb_type_value(v)
                if tv:
                    cmds.append(f"PBCMD\tAdd :{array_name}:{index}:{key_path} {tv[0]} {tv[1]}")
    return cmds

diff(prev, curr, [])

_array_add_noted = False
for prefix, index, item in results:
    if len(prefix) != 1:
        continue
    arr_name = prefix[0]
    # Whole-element noise (the Character Viewer re-adding itself): skip before
    # anything is printed, so neither the Add lines nor the positional NOTE go out.
    if is_noise_element(arr_name, item):
        continue
    # Skip reorders: if array length is the same, elements just moved (not added)
    if arr_name in prev and arr_name in curr and isinstance(prev[arr_name], list) and isinstance(curr[arr_name], list) and len(prev[arr_name]) == len(curr[arr_name]):
        continue
    # New top-level arrays handled entirely by emit_nested_dict_changes (with NOTE)
    if arr_name not in prev:
        continue
    # Adding to an EXISTING array: the index is positional. Warn once. A target
    # whose array has a different length won't get the element at the same spot.
    if not _array_add_noted:
        print("PBCMD\t# NOTE: array index :N is positional. May land elsewhere if the target's array differs")
        _array_add_noted = True
    if isinstance(item, dict):
        keys = ','.join(sorted(all_keys_recursive(item)))
        # Output metadata line (for _skip_keys in shell)
        print(f"{prefix[0]}\t{index}\t{keys}\t")
        # Dock: emit app name comment + dockutil INFO comment for readability
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
                # dockutil equivalent (INFO comment only. The PlistBuddy Add
                # commands below already reproduce it; dockutil is the
                # deploy-friendly alternative if the admin has it installed).
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
                        # dockutil keyword is 'auto' (NOT 'automatic'); README --view [grid|fan|list|auto]
                        _view = {0: "auto", 1: "fan", 2: "grid", 3: "list"}.get(_i(td.get("showas")), "auto")
                        _disp = {0: "stack", 1: "folder"}.get(_i(td.get("displayas")), "stack")
                        _sort = {1: "name", 2: "dateadded", 3: "datemodified", 4: "datecreated", 5: "kind"}.get(_i(td.get("arrangement")), "name")
                        _du += f" --view {_view} --display {_disp} --sort {_sort}"
                    print(f"PBCMD\t{_du}")
        # Output PlistBuddy commands: first create the array entry, then sub-keys
        print(f"PBCMD\tAdd :{prefix[0]}:{index} dict")
        for pb_line in emit_plistbuddy(prefix[0], index, item):
            print(pb_line)
    else:
        # Scalar array elements (string, int, float, bool)
        tv = pb_type_value(item)
        if tv:
            print(f"{prefix[0]}\t{index}\t\t")
            print(f"PBCMD\tAdd :{prefix[0]}:{index} {tv[0]} {tv[1]}")
PY
) || return 0
  fi

  [ -n "$py_output" ] || return 0

  # PBCMD lines handled by caller (this runs inside $() so log_* would be captured)
  printf '%s\n' "$py_output"
}

# Per-burst notice dedup: _NOTED_DOMAIN[key] holds the last-emit time of a
# NOTE or WARNING, which re-appears only after _NOTE_BURST_GAP seconds of quiet.
typeset -gA _NOTED_DOMAIN=()
typeset -g _NOTE_BURST_GAP=15   # seconds of quiet between bursts; tune to taste

# Return 0 to SHOW the notice keyed by $1, 1 to suppress. The timestamp updates
# on EVERY call, so a notice re-shows only after a quiet gap, never mid-burst.
_note_should_show() {
  local _last=${_NOTED_DOMAIN[$1]:-0}
  _NOTED_DOMAIN[$1]=$EPOCHSECONDS
  (( EPOCHSECONDS - _last < _NOTE_BURST_GAP )) && return 1
  return 0
}

# One-per-burst NOTE before a `# dockutil …` comment: the dockutil line and the
# PlistBuddy commands do the SAME thing, and an admin copying the block would
# run both. Says pick one, and that dockutil needs installing.
_note_dockutil_alt() {
  _note_should_show __dockutil_alt__ || return 0
  # One line: seven lines of preamble for one Dock removal was too much to read.
  _log_kind "$1" "Cmd: # NOTE: dockutil (github.com/kcrawford/dockutil) is an ALTERNATIVE to the PlistBuddy line(s): run one or the other"
}

# Emit contextual notes for domains that need extra steps
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
    # Both fire on every emission from their domain, a single deliberate toggle
    # included, so the condition lives in the sentence: the reader can see whether
    # many keys came at once.
    com.apple.WindowManager)
      _note="opening Desktop & Dock settings writes every default at once. Most of these are not changes you made"; _bulk_only=true ;;
    com.apple.universalaccess)
      _note="opening Accessibility settings writes every default at once. Most of these are not changes you made"; _bulk_only=true ;;
    # AirDrop discoverability: the write is faithful but INERT until sharingd
    # restarts (verified on 26.6.2: Control Center kept the old value until
    # `killall sharingd`). Without this the admin concludes the command is wrong.
    # One reportable key remains, so the note is attached to the domain.
    com.apple.sharingd)
      _note="Run 'killall sharingd' to apply. The write alone is inert, Control Center keeps the previous value" ;;
    com.apple.prodisplaylibrary)
      _note="'defaults write' alone does not apply display presets. Alternative third-party tools exist" ;;
    # Spotlight categories: the write is faithful but INERT until something
    # re-reads the plist. Verified live: reopening the Settings pane applies it;
    # `killall Spotlight` alone did not. Without this the admin deploys a correct
    # command, sees no change, and concludes the command is wrong.
    com.apple.Spotlight)
      case "$array_base" in
        EnabledPreferenceRules|DisabledUTTypes)
          _note="Spotlight re-reads this only when its Settings pane is reopened (killall Spotlight is not enough, a logout is the fallback). And despite its name, EnabledPreferenceRules lists the DISABLED categories" ;;
      esac ;;
  esac
  # Match on array_base for cross-domain keys (e.g. ColorSync in ByHost GlobalPreferences)
  case "$array_base" in
    com.apple.ColorSync.Devices)
      _note="Color profile changes require logout/login to take effect" ;;
    # AppKit toolbar config: the first window open dumps the whole item list. NOT
    # filtered, a customized toolbar being a real preference; annotated instead.
    # Both spellings: the top-level key or the nested array name.
    NSToolbar\ Configuration*|TB\ Item\ Identifiers*)
      _note="opening this window writes the full toolbar layout at once. If the whole layout is here, most of it is not a customization; 'TB Is Shown' is also rewritten by the app on window open/close" ;;
  esac
  [ -n "$_note" ] || return 0

  # A "first open writes everything" note is only true when a lot arrives at
  # once, and it is emitted BEFORE the commands. So count them as they go and
  # print once past the threshold; a lone toggle gets no note.
  if [ "${_bulk_only:-false}" = true ]; then
    local _now=$EPOCHSECONDS
    (( _now - ${_BULK_SEEN_AT[$dom]:-0} > _NOTE_BURST_GAP )) && _BULK_N[$dom]=0
    _BULK_SEEN_AT[$dom]=$_now
    _BULK_N[$dom]=$(( ${_BULK_N[$dom]:-0} + 1 ))
    (( ${_BULK_N[$dom]} >= 4 )) || return 0
  fi

  # Dedup per burst (sliding window): show once, re-show only after quiet
  _note_should_show "${dom}:${_note}" || return 0
  _log_note_wrapped "" "$_note"
}

# Raw Python runner for array deletions. Prints py_output to stdout so the
# caller can prefetch it in parallel before emit_array_deletions consumes it.
_py_deletions_raw() {
  local dom="$1" prev_json="$2" curr_json="$3"
  [ -n "$PYTHON3_BIN" ] || return 0
  [ -s "$curr_json" ] || return 0
  [ -s "$prev_json" ] || return 0
  "$PYTHON3_BIN" - "$dom" "$prev_json" "$curr_json" "${(j:,:)_ELEMENT_NOISE_MARKERS}" <<'PY'
import json, sys, os

domain, prev_path, curr_path = sys.argv[1], sys.argv[2], sys.argv[3]

# Element-level noise rules (_ELEMENT_NOISE_MARKERS): on a deletion the shell
# only sees the element's key names, so the marker is judged here.
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

# SHARED BLOCK, repeated verbatim in the three Python workers so each heredoc
# stays self-contained. EDIT ALL THREE TOGETHER. Volatile metadata rewritten on
# every plist save is stripped before comparing elements.
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
        # Pre-compute stable fingerprints (ignoring volatile metadata)
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

# Emit highest index first: deleting a lower index shifts everything above it,
# so the Delete commands must run highest-to-lowest to stay correct. Emitting
# them in that order lets the admin run them as-is (matches the WARNING).
results.sort(key=lambda r: r[1], reverse=True)

for path_tuple, index, item in results:
    if not path_tuple:
        continue
    # Only handle top-level arrays (len 1), skip nested arrays
    if len(path_tuple) != 1:
        continue
    array_name = path_tuple[-1] if path_tuple else ""
    # Whole-element noise. The half the shell can never see (it gets key names, not values).
    if is_noise_element(array_name, item):
        continue
    # Skip reorders: if array length is the same, elements just moved (not deleted)
    if array_name in prev and array_name in curr and isinstance(prev[array_name], list) and isinstance(curr[array_name], list) and len(prev[array_name]) == len(curr[array_name]):
        continue
    # Dock: extract app name for deletion comment
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
    # 5th field: the element's VALUE, when targeting it by value is safe. An
    # index-addressed Delete replayed on a target whose array differs removes
    # whatever sits at that index, silently (measured: a Spotlight re-enable removed
    # the target's Siri entry). Only a string occurring EXACTLY ONCE in the array;
    # anything else keeps the positional form.
    value = ""
    if isinstance(item, str) and isinstance(prev.get(array_name), list):
        if sum(1 for e in prev[array_name] if e == item) == 1 and "\t" not in item and "\n" not in item:
            value = item
    # 6th field: the whole array rewritten without the element, as `defaults write
    # … -array …`. The only python3-free way to remove one element (PlistBuddy is
    # positional), and the target usually has no Command Line Tools. Narrow on
    # purpose, `-array` being lossy: it STRINGIFIES (`-array 42` writes "42"), so
    # only all-string arrays qualify; a value carrying " or \ needs a second quoting
    # layer and falls back. $ and ` are escaped, being ordinary in a path.
    # %EMPTY% marks the last element removed: `defaults write d k -array` with no
    # values writes [] (measured on 27.0), the shell emits a bare `-array`.
    rewrite = ""
    if value:
        elements = prev[array_name]
        if all(isinstance(e, str) for e in elements):
            remaining = [e for e in elements if e != item]
            if not remaining:
                rewrite = "%EMPTY%"
            elif not any(any(c in e for c in '"\\\n\t') for e in remaining):
                rewrite = ' '.join(
                    '"%s"' % e.replace('$', '\\$').replace('`', '\\`') for e in remaining)
    # \x1f (unit separator), NOT tab: tab is IFS whitespace, so zsh collapses a run
    # of them into ONE delimiter, and with `keys` and `app_label` empty the value
    # landed three variables early (measured: the emitter silently kept the
    # positional form). A non-whitespace separator keeps one field per column.
    print(f"{array_name}\x1f{index}\x1f{keys}\x1f{app_label}\x1f{value}\x1f{rewrite}")
PY
}

# Remove ONE element of a top-level array by VALUE (`defaults` cannot, and
# PlistBuddy is positional), through python3 via `defaults export`/`import`:
# cfprefsd owns the file and would overwrite a direct write. Returns empty when
# a quote in any field would break the single-quoted shell string, so the
# caller keeps the positional form.
_build_array_value_delete() {
  local dom="$1" key="$2" val="$3"
  case "$dom$key$val" in *\'*|*\\*) return 1 ;; esac
  printf "/usr/bin/python3 -c 'import subprocess as s, plistlib; d=\"%s\"; k=\"%s\"; v=\"%s\"; p=plistlib.loads(s.run([\"/usr/bin/defaults\",\"export\",d,\"-\"],capture_output=True).stdout); p[k]=[x for x in p.get(k,[]) if x!=v]; s.run([\"/usr/bin/defaults\",\"import\",d,\"-\"],input=plistlib.dumps(p))'" \
    "$(_escape_dq "$dom")" "$(_escape_dq "$key")" "$(_escape_dq "$val")"
}

emit_array_deletions() {
  # $6 = OPTIONAL real plist path. The delete_cmd built below carries no host
  # flag at all, so without this a ByHost array deletion targeted the any-host
  # file. _run_py_diff_workers already holds the path and forwards it.
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

    # Skip noisy arrays
    if is_noisy_key "$dom" "$base"; then _dbg_filtered "$dom $base (noise-array)"; continue; fi

    # Emit contextual note once per array
    if [ -z "${_noted_del_arrays[$base]:-}" ]; then
      _emit_contextual_note "$dom" "$base"
      _noted_del_arrays[$base]=1
    fi

    # Dock: the dockutil line (`--remove` by label, robust where a positional index
    # shifts) names the app; the PlistBuddy Delete below reproduces it on its own.
    if [ -n "$app_label" ]; then
      _note_dockutil_alt "$kind"
      _log_kind "$kind" "Cmd: # dockutil --remove '$app_label'"
    fi

    # $base is an array key name straight out of the plist, and $dom is the
    # filename-derived domain. Both were interpolated raw here while the very
    # same construction in _build_defaults_delete_cmd escapes its target.
    local delete_cmd="defaults delete \"$(_escape_dq "$dom")\" \":$(_escape_dq "$base"):${idx}\""

    local _val_cmd="" _rw_cmd=""
    # Prefer the python3-FREE form when the worker judged it faithful: it runs on
    # any Mac, where the python3 one needs the Command Line Tools on the target.
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
      # Rewriting the whole array has no index to shift, so the "order shown" warning
      # does not apply. It replaces the target's list, it does not merge.
      _note_should_show "__arrayrw__:$dom:$base" \
        && _log_kind "$kind" "Cmd: #       (rewrites the whole '$base' list. Reproduces it, does not merge)"
      _log_kind "$kind" "Cmd: $(_mdm_wrap "$_rw_cmd")"
    elif [ -n "$_val_cmd" ]; then
      # Value-targeted: no index to shift, so the "run these in the order shown"
      # warning does not apply and is not emitted for this line.
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
          # Comments pass through as-is; only the real PlistBuddy command is
          # --mdm-wrapped so a root Jamf replay runs it in the user's context.
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

# Detect and emit PlistBuddy commands for changes inside nested dicts
# Handles cases like symbolichotkeys where values change deep inside dicts
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

# SHARED BLOCK, repeated verbatim in the three Python workers so each heredoc
# stays self-contained. EDIT ALL THREE TOGETHER. Volatile metadata rewritten on
# every plist save is stripped before comparing elements.
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
        # PlistBuddy strips a leading regular space from an unquoted value; quote
        # values with leading/trailing whitespace (escaping any internal ") so
        # they round-trip. Values without edge whitespace stay unquoted as before.
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
        # Compare array elements by index (positional)
        for i in range(min(len(prev_obj), len(curr_obj))):
            c, a, d = find_leaf_changes(prev_obj[i], curr_obj[i], path_parts + [str(i)])
            changes.extend(c)
            additions.extend(a)
            deletions.extend(d)
        # Added elements (array grew)
        for i in range(len(prev_obj), len(curr_obj)):
            additions.append((path_parts + [str(i)], curr_obj[i]))
        # Removed elements (array shrank). Delete highest index first
        for i in reversed(range(len(curr_obj), len(prev_obj))):
            deletions.append((path_parts + [str(i)],))
    else:
        # Leaf value changed (or type changed)
        tv = pb_type_value(curr_obj)
        if tv:
            changes.append((path_parts, tv))
    return changes, additions, deletions

# An empty-string key ('') makes the ':'.join path a bare '::', which PlistBuddy
# collapses. The value lands one level too high (verified by round-trip). No CLI
# addresses it, so skip the whole subtree from that key down and note it once.
_empty_key_noted = [False]
def _note_empty_key():
    if not _empty_key_noted[0]:
        print("PBCMD\t# NOTE: a key path has an empty-string key (''). PlistBuddy can't address it, so that subtree is skipped (not reproducible)")
        _empty_key_noted[0] = True

# Recursively emit PlistBuddy Add commands for an entire dict/value tree
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

# Print preset noise, handed in by the shell (_PRINT_PRESET_NOISE) and matched
# with fnmatchcase, the same glob semantics as the zsh `case`.
import fnmatch
_PRINT_PRESET_NOISE = [g for g in (sys.argv[4] if len(sys.argv) > 4 else '').split(',') if g]

def filter_print_preset_settings(settings_dict):
    """Drop the driver internals and last-job traces; keep everything else."""
    if not isinstance(settings_dict, dict):
        return settings_dict
    return {k: v for k, v in settings_dict.items()
            if not any(fnmatch.fnmatchcase(k, g) for g in _PRINT_PRESET_NOISE)}

is_print_preset = domain.startswith('com.apple.print.custompresets')

# Process top-level keys that are dicts or lists
changed_top_keys = set()
_first_create_noted = False
for top_key in sorted(curr.keys()):
    if not isinstance(curr[top_key], (dict, list)):
        continue
    if top_key not in prev:
        # New top-level dict/list: emit Add commands for entire tree
        if not _first_create_noted:
            # The "mostly defaults" warning lives here, not in a per-domain table: a whole
            # tree appearing IS the first-open-a-pane case (observed: fourteen Add lines,
            # thirteen of them defaults), for every pane. The "If" keeps it from
            # over-claiming on a small deliberate tree.
            print("PBCMD\t# NOTE: new key tree. The Add commands build it top-down; later changes to it emit Set.")
            print("PBCMD\t#       If this came from first opening a settings pane, most of these values are untouched defaults, not your choices.")
            _first_create_noted = True
        changed_top_keys.add(top_key)
        sub_keys = set()
        def collect_keys(obj, parts):
            if isinstance(obj, dict):
                for k in obj:
                    sub_keys.add(k)
                    collect_keys(obj[k], parts + [k])
        # Print presets: filter noisy driver defaults from settings dict
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
    # Top-level arrays: Add/Delete handled by emit_array_additions/deletions
    # Set only valid for in-place changes (not index shifts from insert/delete)
    if isinstance(curr[top_key], list):
        additions = []
        deletions = []
        if len(prev[top_key]) != len(curr[top_key]):
            changes = []
        elif changes:
            # Same-length array: drop positional Set diffs for elements that merely moved,
            # so reordering an order-insensitive list (Spotlight EnabledPreferenceRules)
            # emits no per-index Sets.
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
    # Collect all sub-keys touched for _skip_keys metadata
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
    # Emit metadata line (same format as array additions)
    print(f"{top_key}\t\t{','.join(sorted(sub_keys))}")
    # Emit PlistBuddy Delete commands first (must precede Add for array replacements)
    for (path_parts,) in deletions:
        if any(p == '' for p in path_parts):
            _note_empty_key(); continue
        full_path = ':'.join(p.replace(' ', '\\ ') for p in path_parts)
        print(f"PBCMD\tDelete :{full_path}")
    # Emit PlistBuddy Add commands for new sub-keys and replaced arrays
    for path_parts, obj in additions:
        emit_add_tree(path_parts, obj)
    # Emit PlistBuddy Set commands for changed values
    for path_parts, (ptype, pvalue) in changes:
        # Print presets: filter noisy driver keys in settings dict
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

  # Pass through all Python output (metadata + PBCMD lines)
  printf '%s\n' "$py_output"
}

# Run the 3 Python diff workers in parallel and fold their output into the
# GLOBALS _SKIP_KEYS / _HAS_ARRAY_ADDITIONS (do not declare them local here).
# Shared by show_plist_diff and show_domain_diff; order: additions/sets, then
# deletions. Args: kind dom prev_json curr_json pb_plist_path key.
_run_py_diff_workers() {
  local kind="$1" dom="$2" prev_json="$3" curr_json="$4" pb_plist_path="$5" key="$6"
  local _py_add="$CACHE_DIR/${key}.py.add" _py_del="$CACHE_DIR/${key}.py.del" _py_nest="$CACHE_DIR/${key}.py.nest"
  # Wait on THESE three by pid, never a bare `wait`, which would also wait on
  # the cfprefsd flush hint fs_watch backgrounds (see show_plist_diff).
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

# Menu bar item positions (`NSStatusItem Preferred Position <Item>`) are pixel
# offsets, filtered as churn, so a Cmd+drag reorder emits nothing: surface a
# NOTE. Only on a VALUE change of an existing key (added/removed = shown/hidden,
# whose real command is emitted). A display connect can move them too, so the
# NOTE says "positions changed", not "reorder".
_note_menubar_positions() {
  local kind="$1" prev="$2" curr="$3" dom="${4:-}" _k _pat
  [ -s "$prev" ] && [ -s "$curr" ] || return 0
  # Every app stores its own `NSStatusItem Preferred Position <Item>`; macOS 27
  # also had them in com.apple.MenuBarAgent as `*ItemPreferredPositions` with
  # `module:<id>` / `status:<bundleid>::<item>` keys, matched there.
  _pat='"NSStatusItem Preferred Position'
  [ "$dom" = "com.apple.MenuBarAgent" ] && _pat='"(module|status):'
  # `|| true` INSIDE the $(). Diff exits 1 when the files differ, and pipefail
  # propagates that, which an outer `|| _k=""` would use to wipe the captured key
  # (the bug that kept this NOTE from ever firing). Keep the stdout, drop the status.
  _k=$(/usr/bin/diff "$prev" "$curr" 2>/dev/null \
        | /usr/bin/grep -E "^[<>].*$_pat" \
        | /usr/bin/sed -E 's/^[<>][[:space:]]*//; s/[[:space:]]*=.*//' \
        | /usr/bin/sort | /usr/bin/uniq -d | /usr/bin/head -1 || true)
  [ -n "$_k" ] || return 0
  _note_should_show __menubar_pos__ || return 0
  _log_note_wrapped "$kind" "menu bar layout changed. Item positions are pixel offsets, not portable, so not emitted. A reorder OR a display connect/disconnect triggers this."
}

# A pure Dock reorder: the same apps in a different order, whose positional
# churn is filtered, so it would emit nothing. A NOTE; reproducing the order
# needs a full persistent-apps rewrite.
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

# Time Machine: the two settings `tmutil` reproduces. AutoBackup is `tmutil
# enable`/`disable`, SkipPaths is `addexclusion`/`removeexclusion`; both raw
# writes are filtered since backupd owns the file. SkipPaths is read from the
# `plutil -p` dumps: this is a diff, only the paths that moved become a command.
_tm_skippaths() {
  [ -s "$1" ] || return 0
  # `plutil -p` escapes nothing inside a string (measured: `0 => "/x/Mon Dossier
  # "test""`), so the value runs from `=> "` to the end of the line minus the
  # closing quote. A path ENDING in a quote loses it; plutil cannot express it.
  /usr/bin/awk '
    /"SkipPaths" => \[/ { inside = 1; next }
    inside && /^[[:space:]]*\]/ { inside = 0 }
    inside && match($0, /=> "/) {
      line = substr($0, RSTART + 4)
      sub(/"[[:space:]]*$/, "", line)
      print line
    }' "$1" 2>/dev/null
}
# Did AutoBackup change? AutoBackupInterval rides on it (measured on 27.0:
# disabling removes the key, enabling writes 3600 back), so show_plist_diff
# skips it then; an interval changed on its own still surfaces.
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

# Media Sharing. Every key of com.apple.amp.mediasharingd is filtered (see
# is_noisy_key) because they mirror state the daemon never reads back. So the
# domain would otherwise report a change with no command at all behind it.
_note_mediasharing() {
  local kind="$1"
  _note_should_show __mediasharing__ || return 0
  _log_note_wrapped "$kind" "Media Sharing changed, not reproducible via defaults: these keys mirror state the daemon writes and never reads back (measured: the write survives a restart of mediasharingd and the pane never follows). Set it in System Settings > General > Sharing."
}

# Print presets: three facts an admin needs before deploying one. It applies
# after a logout/login. The DOMAIN carries the CUPS queue name
# (…custompresets.forprinter.EPSON_WF_C579R_Series), whatever the printer was
# added as, so the path matches only where the queue has that name. The
# top-level KEY is the preset's display name, and macOS's own presets are
# LOCALISED ('Réglages par défaut' here), so their path finds nothing on a Mac
# in another language; a preset the admin named travels.
_note_print_preset() {
  local kind="$1" dom="$2"
  case "$dom" in com.apple.print.custompresets*) ;; *) return 0 ;; esac
  _note_should_show "__print_preset__:$dom" || return 0
  local _pp="print preset changed. It takes effect after a logout/login."
  case "$dom" in
    *.forprinter.*) _pp="$_pp This domain names the print queue ('${dom##*.forprinter.}'), which is whatever the printer was added as; the path matches only where the queue has that name." ;;
  esac
  _log_note_wrapped "$kind" "$_pp The top-level key is the preset's NAME; macOS's own entries are localised ('Réglages par défaut' here), so their path finds nothing on a Mac in another language. A preset you named yourself carries the name you chose, and travels."
}

# Wi-Fi radio on/off: PowerEnabled in com.apple.airport.preferences, a file
# airportd owns, so the raw write is inert. `networksetup -setairportpower`
# takes a BSD device name, resolved here; the NOTE says it belongs to this Mac.
_note_wifi_power() {
  local kind="$1" prev="$2" curr="$3" _p _c _dev
  [ -s "$prev" ] && [ -s "$curr" ] || return 0
  _p=$(/usr/bin/sed -n 's/^[[:space:]]*"PowerEnabled" => \(.*\)$/\1/p' "$prev" 2>/dev/null | /usr/bin/head -1) || _p=""
  _c=$(/usr/bin/sed -n 's/^[[:space:]]*"PowerEnabled" => \(.*\)$/\1/p' "$curr" 2>/dev/null | /usr/bin/head -1) || _c=""
  [ -n "$_c" ] && [ "$_p" != "$_c" ] || return 0
  _note_should_show "__wifi_power__:$_c" || return 0
  # `-listallhardwareports` prints "Hardware Port: Wi-Fi" then "Device: enN".
  _dev=$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null \
           | /usr/bin/awk '/^Hardware Port: Wi-Fi$/{getline; print $2; exit}') || _dev=""
  [ -n "$_dev" ] || _dev="en0"
  case "$_c" in
    1|true|TRUE) _log_kind "$kind" "Cmd: sudo /usr/sbin/networksetup -setairportpower $_dev on" ;;
    *)           _log_kind "$kind" "Cmd: sudo /usr/sbin/networksetup -setairportpower $_dev off" ;;
  esac
  _log_kind "$kind" "Cmd: #       ($_dev is this Mac's Wi-Fi device; on the target: networksetup -listallhardwareports)"
}

# Beta program enrollment. Measured on 27.0: leaving it deleted CatalogURL
# (com.apple.SoftwareUpdate) and NSShowFeedbackMenu (system .GlobalPreferences)
# at once, and neither Delete enrolls anything; nor does seedutil, whose 27.0
# binary says "seedutil is no longer supported". So a NOTE, no command, naming
# the program from the catalog URL via the Seeding framework's SeedCatalogs.plist.
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

# desktoppr records the image it last applied in its own domain. `lastPath` is
# filtered and replaced by the desktoppr command itself (the tool IS the
# command, as utiluti is for default apps). In ALL mode with python3,
# wallpaper_watch already emits it from the Store (and _note_should_show cannot
# dedup across processes), so this emits only elsewhere: single-domain mode,
# or a Mac with no python3.
_desktoppr_lastpath() {
  [ -s "$1" ] || return 0
  # No pipe: a capture of `cmd | head` dies under set -e + pipefail (1.4.3).
  /usr/bin/sed -n 's/^[[:space:]]*"lastPath" => "\(.*\)"$/\1/p' "$1" 2>/dev/null
}
# The one-line header above any desktoppr command. Two emitters print it.
# _note_desktoppr here, and wallpaper_watch. So it lives in one place.
_note_desktoppr_head() { _log_kind "${1:-}" "Cmd: # NOTE: needs desktoppr (github.com/scriptingosx/desktoppr)"; }
_note_desktoppr() {
  local kind="$1" _p _c
  _p="$(_desktoppr_lastpath "$2")" ; _c="$(_desktoppr_lastpath "$3")"
  [ -n "$_c" ] && [ "$_p" != "$_c" ] || return 0
  _note_should_show "__desktoppr__:$_c" || return 0
  # Every key of this domain is filtered, so claim the "new domain" note's dedup
  # slot: it would head an empty block either way.
  _NOTED_DOMAIN[__newdom__:com.scriptingosx.desktoppr]=$EPOCHSECONDS
  # wallpaper_watch is emitting this in ALL mode. See above.
  [ "${ALL_MODE:-false}" = "true" ] && [ -n "$PYTHON3_BIN" ] && return 0
  _note_desktoppr_head "$kind"
  # Wallpaper is per-user session state, so --mdm wraps it in runAsUser the same
  # way a user-domain `defaults` is. Root setting its own wallpaper changes nothing.
  local _dp="desktoppr \"$(_escape_dq "$_c")\""
  _log_kind "$kind" "Cmd: $(_mdm_wrap "$_dp")"
}

# Display plist file diff
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

  # System-level prefs (/Library/Preferences, non-ByHost) are root-owned: flag
  # it so the emitted commands target the system file, not ~/Library's copy.
  typeset -g _EMIT_SYS=false _EMIT_SYS_DOM=""
  # Keep the REAL path (minus .plist): a system plist can sit in a subdirectory,
  # and SystemConfiguration/preferences.plist came out as a nonexistent
  # /Library/Preferences/preferences.
  [[ "$path" == /Library/Preferences/* && "$path" != */ByHost/* ]] && { _EMIT_SYS=true; _EMIT_SYS_DOM="${path%.plist}"; }

  init_cache
  local key prev curr prev_json curr_json
  key=$(hash_path "$path")
  prev="$CACHE_DIR/${key}.prev"
  curr="$CACHE_DIR/${key}.curr"
  prev_json="$CACHE_DIR/${key}.prev.json"
  curr_json="$CACHE_DIR/${key}.curr.json"

  # Mutex fs_watch ↔ poll_watch on the same plist (wait up to 3s). Lockdirs older
  # than 10s are reclaimed, always: a lock orphaned by a killed holder would
  # otherwise silence that plist for the rest of the run (hence the `stat -f %m`
  # fallback without zsh/stat).
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
      # Lock held by the other watcher (fs_watch vs poll_watch), already emitting
      # this plist's diff. Skip to avoid a double-emit. Not an error.
      return 0
    fi
    /bin/sleep 0.1
  done

  if [ "$silent" != "true" ]; then
    # Wait on THESE two by pid: a bare `wait` also waits for the cfprefsd flush
    # hint fs_watch backgrounds just before calling us (measured: 3.00s vs 0.06s),
    # and a hung cfprefsd then froze the diff while HOLDING $lockdir.
    local _dp_pid _dpj_pid
    dump_plist "$path" "$curr" &
    _dp_pid=$!
    dump_plist_json "$path" "$curr_json" &
    _dpj_pid=$!
    wait "$_dp_pid" "$_dpj_pid" 2>/dev/null || true
  else
    dump_plist "$path" "$curr"
  fi

  # Retry with increasing delays: cfprefsd writes asynchronously, so the file may
  # still be stale when the event fires; `defaults read` hints it to sync. Text
  # is re-dumped only when the mtime moved, JSON once a change is confirmed.
  if [ -s "$prev" ] && [ -s "$curr" ] && /usr/bin/cmp -s "$prev" "$curr" 2>/dev/null; then
    local _retry_delay _retry_changed=false _last_mtime _cur_mtime
    # ByHost prefs live in ByHost/<dom>.<UUID>.plist; the bare `defaults read`
    # only syncs the standard plist, so flush the ByHost variant when relevant.
    local _flush_hostflag=""
    [[ "$path" == *"/ByHost/"* ]] && _flush_hostflag="-currentHost"
    # mtime via zstat (module loaded at startup) instead of forking `stat -f %m`
    # up to 6× per retried change. Same integer-seconds granularity, which is what
    # the same-second fall-through below already relies on.
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
      # Hint cfprefsd to flush pending writes for this domain (read triggers sync)
      "${RUN_AS_USER[@]}" /usr/bin/defaults ${_flush_hostflag:+$_flush_hostflag} read "$_dom" >/dev/null 2>&1 || true
      _cur_mtime=$(_mtime_of "$path")
      # Last retry: always dump. Stat %m has 1-second granularity so
      # same-second cfprefsd flushes are invisible to the mtime check.
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
    # Change detected during retry. Dump JSON now for diff engine
    if [ "$_retry_changed" = "true" ] && [ "$silent" != "true" ]; then
      dump_plist_json "$path" "$curr_json"
    fi
    if [ -s "$prev" ] && [ -s "$curr" ] && /usr/bin/cmp -s "$prev" "$curr" 2>/dev/null; then
      /bin/rm -f "$curr" "$curr_json" 2>/dev/null || true
      /bin/rmdir "$lockdir" 2>/dev/null || true
      return 0
    fi
  fi

  # An EMPTY dump is not "every key was deleted": an app rewriting its plist
  # non-atomically leaves `curr` at 0 bytes, and the diff would then emit a
  # `defaults delete` for every key, freeze the baseline empty and re-add
  # everything next cycle. Skip, and release the lock on the way out.
  if [ ! -s "$curr" ]; then
    /bin/rm -f "$curr" "$curr_json" 2>/dev/null || true
    /bin/rmdir "$lockdir" 2>/dev/null || true
    return 0
  fi

  typeset -gA _SKIP_KEYS
  _SKIP_KEYS=()
  typeset -g _HAS_ARRAY_ADDITIONS=false

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
    # Before the diff: this domain's only reportable content is the desktoppr command.
    if [ "$_dom" = "com.scriptingosx.desktoppr" ]; then
      _note_desktoppr "$kind" "$prev" "$curr"
    fi
    # Network location: CurrentSet changed at the top level. The raw write is
    # filtered (is_noisy_key); say what reproduces it.
    if [ "$_dom" = preferences ] && [[ "$path" == */SystemConfiguration/preferences.plist ]] \
       && [ "$(/usr/bin/sed -n 's/^[[:space:]]*"CurrentSet" => //p' "$prev" 2>/dev/null)" != "$(/usr/bin/sed -n 's/^[[:space:]]*"CurrentSet" => //p' "$curr" 2>/dev/null)" ]; then
      _note_network_location "$kind" "$path" || _log_kind "$kind" "Cmd: # NOTE: network location changed. Its name could not be resolved, so no scselect command is emitted."
    fi
    # Time Machine: AutoBackupInterval follows AutoBackup (see _tm_autobackup_moved).
    if [ "$_dom" = "com.apple.TimeMachine" ] && _tm_autobackup_moved "$prev" "$curr"; then
      _SKIP_KEYS[AutoBackupInterval]=1
      _dbg_filtered "$_dom AutoBackupInterval (follows AutoBackup, which tmutil handles)"
    fi
    _process_diff_lines "$kind" "$_emit_dom" "$_emit_hostflag" "$prev" "$curr" "$path" "$path" "$path"
    # A pure Dock reorder emits nothing above (positional churn is filtered). Flag it.
    [ "$_dom" = "com.apple.dock" ] && _note_dock_reorder "$kind" "$prev_json" "$curr_json"
    # Same for menu bar offsets. Any domain, so no guard.
    _note_menubar_positions "$kind" "$prev" "$curr" "$_dom"
    # Battery charge limit lives in a UI-cache domain; real control is SMC. NOTE only.
    [ "$_dom" = "com.apple.batteryui.charging.mac" ] && _note_charge_limit "$kind"
    [ "$_dom" = "com.apple.airport.preferences" ] && _note_wifi_power "$kind" "$prev" "$curr"
    [ "$_dom" = "com.apple.TimeMachine" ] && _note_timemachine "$kind" "$prev" "$curr"
    [ "$_dom" = "com.apple.SoftwareUpdate" ] && _note_seed_enrollment "$kind" "$prev" "$curr"
    [ "$_dom" = "com.apple.amp.mediasharingd" ] && _note_mediasharing "$kind"
    _note_print_preset "$kind" "$_dom"
  fi

  /bin/mv -f "$curr" "$prev" 2>/dev/null || /bin/cp -f "$curr" "$prev" 2>/dev/null || :
  [ -f "$curr_json" ] && { /bin/mv -f "$curr_json" "$prev_json" 2>/dev/null || /bin/cp -f "$curr_json" "$prev_json" 2>/dev/null || : ; }
  /bin/rmdir "$lockdir" 2>/dev/null || true
}

# ---------------------------------------
# Domain Diff (defaults export)
# ---------------------------------------

show_domain_diff() {
  local dom="$1"
  local skip_arrays="${2:-false}"

  # Domain mode uses user-domain semantics; clear any system flag left set by a
  # prior show_plist_diff so emitted commands don't get /Library/Preferences.
  typeset -g _EMIT_SYS=false _EMIT_SYS_DOM=""

  # In ALL mode, skip excluded domains. In domain mode, user explicitly requested it.
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
  # An empty export is an absent domain or a transient read failure (cfprefsd
  # busy): diffed against a full prev it would delete every key and re-add them
  # next cycle. Skip, keep the last good state.
  [ -s "$tmpplist" ] || return 0
  /usr/bin/plutil -p "$tmpplist" > "$curr" 2>/dev/null || /bin/cat "$tmpplist" > "$curr" 2>/dev/null || :
  curr_json="$CACHE_DIR/${key}.curr.json"
  # The JSON is only consumed by the Python workers, gated on skip_arrays; every
  # ALL-mode caller passes true, so dumping it there fed a file nothing read.
  [ "$skip_arrays" != "true" ] && dump_plist_json "$tmpplist" "$curr_json"

  prev_json="$CACHE_DIR/${key}.prev.json"
  typeset -gA _SKIP_KEYS
  _SKIP_KEYS=()
  typeset -g _HAS_ARRAY_ADDITIONS=false

  if [ "$skip_arrays" != "true" ] && [ -n "$PYTHON3_BIN" ] && [ -s "$prev_json" ] && [ -s "$curr_json" ]; then
    _run_py_diff_workers DOMAIN "$dom" "$prev_json" "$curr_json" "$(get_plist_path "$dom" 2>/dev/null)" "$key"
  fi

  # Same in single-domain / ALL-domain mode as in the per-plist diff above.
  if [ "$dom" = "com.scriptingosx.desktoppr" ]; then
    _note_desktoppr DOMAIN "$prev" "$curr"
  fi
  _note_print_preset DOMAIN "$dom"
  _process_diff_lines DOMAIN "$dom" "" "$prev" "$curr" "$tmpplist" "$dom"

  /bin/mv -f "$curr" "$prev" 2>/dev/null || /bin/cp -f "$curr" "$prev" 2>/dev/null || :
  # Only advance the JSON baseline when one was actually produced (see above).
  [ "$skip_arrays" != "true" ] && { /bin/mv -f "$curr_json" "$prev_json" 2>/dev/null || /bin/cp -f "$curr_json" "$prev_json" 2>/dev/null || : ; }
  return 0
}

# ---------------------------------------
# Monitoring
# ---------------------------------------

# Plist path for a domain, or empty. A domain whose only plist sits in a GROUP
# container is not addressable by name (measured: 23 of 23 such domains export
# zero keys while the file holds up to 39), so it is explained, never "watched".
# ~/Library/Containers is different: 4 of 5 domains there ARE reachable by name
# (`defaults read com.apple.Notes` answers with no flat plist), and keeps its branch.
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

get_plist_path_for_domain() {
  local domain="$1"
  local plist_path=""

  # Special case: NSGlobalDomain uses .GlobalPreferences.plist
  if [ "$domain" = "NSGlobalDomain" ] || [ "$domain" = ".GlobalPreferences" ]; then
    plist_path="$TARGET_HOME/Library/Preferences/.GlobalPreferences.plist"
    [ -f "$plist_path" ] && echo "$plist_path" && return 0
  fi

  # Try sandboxed Container first (common for modern apps)
  plist_path="$TARGET_HOME/Library/Containers/${domain}/Data/Library/Preferences/${domain}.plist"
  [ -f "$plist_path" ] && echo "$plist_path" && return 0

  # Try standard Preferences directory
  plist_path="$TARGET_HOME/Library/Preferences/${domain}.plist"
  [ -f "$plist_path" ] && echo "$plist_path" && return 0

  # Try ByHost preferences
  plist_path="$TARGET_HOME/Library/Preferences/ByHost/${domain}."*".plist"
  # `|| plist_path=""`: with no ByHost file the glob/`ls` exits non-zero →
  # pipefail + set -e would abort start_watch at startup. Empty is the right value.
  plist_path=$(/bin/ls $plist_path 2>/dev/null | head -1) || plist_path=""
  [ -n "$plist_path" ] && [ -f "$plist_path" ] && echo "$plist_path" && return 0

  return 1
}

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

# MDM: the deploy helpers, once, as Cmd: lines a root Jamf policy can run.
# PlistBuddy lines carry a $loggedInUser / $UUID path that root edits; a user
# domain `defaults` must run in the user's context (runAsUser), or root writes
# its own prefs and the app never sees the change. Emitted at watcher startup,
# with the other setup NOTEs.
_emit_mdm_resolver_header() {
  [ "$MDM_OUTPUT" = "true" ] || return 0
  log_line "Cmd: # NOTE: put these 4 lines at the top of your deployment script"
  log_line "Cmd: loggedInUser=\$(/usr/bin/stat -f%Su /dev/console)"
  log_line "Cmd: uid=\$(/usr/bin/id -u \"\$loggedInUser\")"
  log_line "Cmd: UUID=\$(/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice | /usr/bin/awk -F'\"' '/IOPlatformUUID/{print \$4}')"
  log_line "Cmd: runAsUser() { /bin/launchctl asuser \"\$uid\" /usr/bin/sudo -u \"\$loggedInUser\" \"\$@\"; }"
}

# Watcher PID registry: `_spawn <fn>` backgrounds a watcher and records its PID
# so the teardown handles the whole set. One global registry: start_watch and
# start_watch_all are mutually exclusive.
typeset -ga _WATCH_PIDS=()
_spawn() { "$@" & _WATCH_PIDS+=($!); }

# Kill a process and its subtree, leaves first, so a watcher's pipeline members
# die with it. Its own copy: _kill_tree lives in MAIN and is not yet parsed when
# this subshell forks.
_wt_kill_tree() {
  local _r="${1:-}" _k
  [ -n "$_r" ] || return 0
  for _k in $(pgrep -P "$_r" 2>/dev/null || true); do _wt_kill_tree "$_k"; done
  kill -TERM "$_r" 2>/dev/null || true
}

# Orphan watchdog. SIGKILL runs no trap, so a force-quit of main left the whole
# subtree alive (measured: 20 of 21 processes, including the fs_usage holding
# the machine's only ktrace slot). The signal is the watcher root's PPID turning
# 1, within a second of main dying. Not `kill -0` on main's pid, which answers
# yes on a recycled pid. It SIGNALS the root so its tested TERM trap does the
# teardown, and it registers in _WATCH_PIDS so it is not itself left behind.
_orphan_watchdog() {
  local _root="$1" _pp
  [ -n "$_root" ] || return 0
  while :; do
    /bin/sleep 5 || true
    _pp=$(/bin/ps -o ppid= -p "$_root" 2>/dev/null | /usr/bin/tr -d ' ') || _pp=""
    # Empty means the root is already gone: nothing to signal, and staying would
    # make this the orphan.
    [ -n "$_pp" ] || return 0
    [ "$_pp" = 1 ] || continue
    /bin/kill -TERM "$_root" 2>/dev/null || true
    return 0
  done
}

_watchers_teardown() {
  # Idempotent: the signal traps run it and then exit, which fires the EXIT trap
  # below, which would otherwise run the whole kill/rm pass a second time.
  [ "${_TEARDOWN_DONE:-false}" = "true" ] && return 0
  typeset -g _TEARDOWN_DONE=true
  # Kill each watcher's whole SUBTREE and never block on `wait`: a watcher whose
  # body is a pipeline (`eslogger | grep | python3`, `script | sed | awk`) does not
  # die when its shell is signalled, and a `wait` on it hung a root teardown
  # forever with fourteen children alive.
  local _p
  for _p in ${_WATCH_PIDS[@]}; do _wt_kill_tree "$_p"; done
  # Bounded wait, then stop caring: nothing here is worth hanging a shutdown for.
  # Poll each pid and stop when NONE answers: `kill -0 p1 p2 p3` fails as soon as
  # one pid is gone, and the tmpdir was removed from under watchers still stopping.
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

# Watcher registry, "name|guard|fn|summary", the single source for both the
# spawn loop and the "Watchers active" line. guard: a test eval'd in an `if`
# (`true` = always; root-only detectors carry the id-0 test); summary: "y" to
# list the name (core fs/poll/cups/pmset plumbing is omitted). Single-quoted so
# `$(id -u)`/`$PYTHON3_BIN` are eval'd at launch with live values.
typeset -ga _WATCHERS=(
  'fs|[ "$(id -u)" -eq 0 ] && [ "$FS_USAGE" = true ]|fs_watch|'
  'poll|true|poll_watch|'
  'cups|true|cups_watch|'
  'pmset|true|pmset_watch|'
  'cups_sharing|[ -f /etc/cups/cupsd.conf ]|cups_sharing_watch|y'
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

# Split one registry entry into globals _W_NAME/_W_GUARD/_W_FN/_W_SUMMARY.
_watcher_parse() {
  local _e="$1"
  _W_NAME="${_e%%|*}"; _e="${_e#*|}"
  _W_GUARD="${_e%%|*}"; _e="${_e#*|}"
  _W_FN="${_e%%|*}"; _W_SUMMARY="${_e##*|}"
}

# Guard for _snapshot_watch: proceed only if the re-read produced non-empty
# output (a transient tool failure yields empty → keep the last good baseline).
_guard_nonempty() { [ -s "$1" ]; }

# Generic snapshot poll loop: <read-fn> writes the state to stdout; every
# <interval>s it is re-read, an optional <guard-fn> (given the curr file) can
# veto churn, and on a change <onchange-fn snap curr> runs and the baseline
# advances. Args: name interval read-fn onchange-fn [guard-fn]. Dynamic scoping:
# the fns are the caller's nested functions and see its locals through this
# frame. `|| true` on onchange so a non-zero return cannot abort the loop.
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

# Start monitoring a specific domain
start_watch() {
  local plist_path last_mtime current_mtime

  # `|| plist_path=""`: the helper returns 1 when the domain has no plist yet (an
  # app installed, not configured), and under set -e that killed the process at
  # startup with only two "# ABORT" lines in /var/log. Empty falls back to
  # full-domain polling, which is right here.
  plist_path=$(get_plist_path_for_domain "$DOMAIN") || plist_path=""

  if [ -n "$plist_path" ]; then
    # Optimized mode: monitor file mtime, only diff when changed
    log_line "Mode: optimized mtime polling (0.5s check on $plist_path)"

    (
      # Take initial baseline snapshot so first user change is detected immediately
      show_domain_diff "$DOMAIN"
      # Baseline established for the watched domain. If it did not exist yet, its
      # creation is now reportable rather than silently swallowed.
      typeset -g _BASELINE_DONE=true
      last_mtime=$(stat -f %m "$plist_path" 2>/dev/null || echo "")
      local _forced_tick=0
      while true; do
        if [ -f "$plist_path" ]; then
          current_mtime=$(stat -f %m "$plist_path" 2>/dev/null || echo "")

          # Only run diff if file has changed
          if [ -n "$current_mtime" ] && [ "$current_mtime" != "$last_mtime" ]; then
            show_domain_diff "$DOMAIN"
            last_mtime="$current_mtime"
            _forced_tick=0
          else
            # Forced diff every 4 iterations (~2s): stat %m has 1-second granularity, and
            # `defaults export` reads cfprefsd directly, so a same-second write is caught.
            _forced_tick=$((_forced_tick + 1))
            if [ "$_forced_tick" -ge 4 ]; then
              show_domain_diff "$DOMAIN"
              last_mtime="$current_mtime"
              _forced_tick=0
            fi
          fi
        else
          # File doesn't exist yet, wait for it
          last_mtime=""
        fi
        sleep 0.5  # Check twice per second for responsiveness
      done
    ) &
    _WATCH_PIDS+=($!)
  else
    # Fallback mode: traditional polling for domains without plist file
    _note_group_container_domain "$DOMAIN" || true
    log_line "Mode: standard polling (plist not found, checking domain every 1s)"

    (
      # First pass writes the baseline; only then may a later appearance of the
      # domain be reported as new (see _process_diff_lines).
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

  # Arm the orphan watchdog before the traps: it is the only thing that survives a
  # SIGKILL of main, which no trap can catch.
  local _wt_self=""
  [ "${HAVE_ZSH_SYSTEM:-false}" = true ] && _wt_self="${sysparams[pid]}"
  if [ -n "$_wt_self" ]; then
    _orphan_watchdog "$_wt_self" &
    _WATCH_PIDS+=($!)
  fi

  # EXIT too, armed HERE: a trap inherited from main does not fire in a `&` job
  # (measured), so an ERR_EXIT abort of the watcher root left 16 sub-watchers
  # reparented to launchd, out of _kill_tree's reach once WATCH_PID was dead.
  trap '_watchers_teardown; exit 0' TERM INT
  trap '_watchers_teardown' EXIT
  wait
}

# Monitor all preferences via fs_usage
start_watch_all() {
  if [ "$(id -u)" -ne 0 ]; then
    log_line "Mode: monitoring ALL preferences (polling only. No root)"
  elif [ "$FS_USAGE" = true ]; then
    log_line "Mode: monitoring ALL preferences (fs_usage + polling)"
  else
    log_line "Mode: monitoring ALL preferences (polling. --fs-usage adds the real-time detector)"
  fi

  local prefs_user prefs_system
  prefs_system="/Library/Preferences"
  prefs_user="$TARGET_HOME/Library/Preferences"

  # Snapshot a single plist (for parallel execution in subshell)
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

  # Snapshot every non-excluded plist under one prefs tree, 16 in parallel, as
  # the baseline. Shared by the USER and SYSTEM passes; sets SNAPSHOT_READY.
  # Args: $1 label ("User"/"System"), $2 root path.
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
        # zsh is 1-based: [1] is the oldest pid; the [@]:1 slice uses a 0-based
        # offset (drop one). Don't "normalize" [1]→[0]. [0] is empty, so
        # `wait ""` returns instantly and the fork throttle is defeated.
        wait "${_snap_pids[1]}" 2>/dev/null || true
        _snap_pids=("${_snap_pids[@]:1}")
      fi
    done < <(/usr/bin/find "$_root" -type f -name "*.plist" 2>/dev/null || true)
    for _pid in "${_snap_pids[@]}"; do wait "$_pid" 2>/dev/null || true; done
    printf "\r  ✓ ${_label} snapshot: %d domains scanned    \n" "$_snap_count"
    snapshot_notice "${_label} snapshot: completed ($_snap_count domains)"
    SNAPSHOT_READY="true"
    # Every existing plist now has a baseline, so from here a missing one means
    # the file did not exist at startup. Which _process_diff_lines may report.
    typeset -g _BASELINE_DONE=true
  }

  # Initial snapshot
  snapshot_notice "Taking initial baseline. Please wait before making changes"

  if [ -d "$prefs_user" ]; then
    _snapshot_tree User "$prefs_user"
  fi

  if [ "$INCLUDE_SYSTEM" = "true" ] && [ -d "$prefs_system" ]; then
    _snapshot_tree System "$prefs_system"
  fi

  if [ "${SNAPSHOT_READY:-false}" = "true" ]; then
    snapshot_notice "Initial snapshots processed. You can now make your changes"
    # Consolidated watcher status. Derived from the SAME _WATCHERS registry that
    # drives the launch loop below (summary="y" entries whose guard passes), so
    # this line can't drift from what's actually spawned.
    local -a _watch_active=()
    local _w=""
    for _w in "${_WATCHERS[@]}"; do
      _watcher_parse "$_w"
      [ "$_W_SUMMARY" = y ] || continue
      if eval "$_W_GUARD"; then _watch_active+=("$_W_NAME"); fi
    done
    # Diagnostic only (--debug): the "Watchers active" line is startup noise for
    # normal runs, so gate it behind DEBUG_FILTER (like the # FILTERED: lines).
    if [ "${DEBUG_FILTER:-false}" = "true" ] && (( ${#_watch_active[@]} > 0 )); then
      log_line "Cmd: # Watchers active: ${(j:, :)_watch_active}"
    fi
    _emit_mdm_resolver_header
    log_line "Cmd: # NOTE: Changes may take a few seconds to appear. Wait between actions for reliable capture"
  fi

  # Where a plist path belongs, for fs_watch: USER and SYSTEM are the two trees
  # the snapshot baselined, CONTAINER a sandboxed app's own Preferences, OTHER
  # anything else. Its own function so the harness can drive it.
  _fs_classify() {
    local _p="$1"
    case "$_p" in
      "$prefs_user"/*)   print -r -- USER ;;
      "$prefs_system"/*) print -r -- SYSTEM ;;
      */Library/Containers/*|*"/Library/Group Containers/"*) print -r -- CONTAINER ;;
      *)                 print -r -- OTHER ;;
    esac
  }

  # Primary detector. Real-time plist writes captured live via fs_usage.
  fs_watch() {
    # Debounce: cfprefsd fires several fs_usage events per logical write.
    # Skip events seen <$FS_DEBOUNCE_S ago; poll_watch catches misses.
    typeset -A _fs_last_seen=()
    local _FS_DEBOUNCE_S=0.3
    # script(1) gives fs_usage a pty so it line-buffers (macOS has no stdbuf);
    # /dev/null is the typescript sink, not an output redirect. fs_usage lives in
    # /usr/bin: a wrong hard-coded path once left real-time detection dead with no
    # error anywhere, so the path is resolved and its absence is logged.
    local _fsu=""
    for _c in /usr/bin/fs_usage /usr/sbin/fs_usage /sbin/fs_usage; do
      [ -x "$_c" ] && { _fsu="$_c"; break; }
    done
    if [ -z "$_fsu" ]; then
      log_line "Cmd: # NOTE: fs_usage not found. Real-time detection off; polling covers the same ground"
      return 0
    fi
    # ktrace admits ONE client: a second fs_usage dies with "Resource busy", and an
    # fs_usage orphaned by an earlier run is the usual holder. No warning up front:
    # on a healthy Mac `ktrace info` names a routine daemon (tailspind) as "last
    # configured by" while fs_usage starts fine. The post-mortem below fires on
    # evidence only, once fs_usage has exited, and asks ktrace who holds it then.
    local _fsu_who=""
    local _fsu_err="${PREFWATCH_TMPDIR}/fs_usage.err"
    # `</dev/null`: script(1) calls tcgetattr on stdin, and under a Jamf policy stdin
    # is a socket, on which it dies and the pipeline goes silent (measured: fails on
    # a socket and a pipe, works on a tty and /dev/null). fs_usage runs under
    # `sh -c "exec … 2>>err"`: its stderr otherwise goes to script's pty and is lost;
    # the outer 2>> only sees script's own errors. `exec` keeps the tree flat for
    # the teardown.
    #
    # `-f pathname`, not `filesys`: under load (mds reindexing) filesys reached 8 GB
    # in five minutes while pathname saw the same plist writes at 510 MB. A process
    # filter (`cfprefsd configd`) saw no plist at all, so only the mode is narrowed.
    #
    # The watchdog below kills OUR fs_usage past FS_USAGE_RSS_LIMIT_MB, matched by
    # grandparent pid so an admin's own fs_usage is never touched (needs sysparams;
    # without zsh/system there is no ceiling rather than a wrong kill). It leaves a
    # marker for the shutdown report and is killed after the pipeline, so it cannot
    # outlive fs_watch.
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
    # Three expressions, one sed, ON ONE LINE (the fs-path-extract case reads it
    # back by that shape):
    #   1. extract the plist path. The capture is anchored on a space + a leading
    #      '/': a greedy `.*` before it once turned /Users/x/Library/Preferences/…
    #      into /Library/Preferences/…, and every user preference was dropped;
    #   2. `/System/Volumes/Data/Users/…` → `/Users/…`. macOS 27 fs_usage reports
    #      the firmlink path, and the baseline is keyed on the plain one; without
    #      this every rewritten plist came out as "a new domain";
    #   3. keep only a file IN a Preferences directory (flat or ByHost): Safari's
    #      Caches/WebKit/HSTS/HSTS.plist once came through as a domain named HSTS.
    # LC_ALL=C is load-bearing: one non-UTF-8 byte in any file name (a Latin-1 é on
    # an old volume) makes BSD sed exit with "illegal byte sequence", and fs_usage
    # then dies of SIGPIPE with nothing in the log. Under C the ASCII regexes match
    # bytes and the odd name passes through.
    LC_ALL=C /usr/bin/sed -l -nE -e 's@.*[[:space:]](/([^[:space:]]*/)?Library/(Group Containers|Containers|Preferences)/.*\.plist).*@\1@' -e 's@^/System/Volumes/Data/@/@' -e '\@/Library/Preferences/(ByHost/)?[^/]+\.plist$@p' |
    while IFS= read -r plist; do
      [ -z "$plist" ] && continue
      cat_type=$(_fs_classify "$plist")
      if [ "$cat_type" = "SYSTEM" ] && [ "${INCLUDE_SYSTEM}" != "true" ]; then
        continue
      fi
      # A container plist has no baseline (the snapshot never enters
      # ~/Library/Containers: sandboxed prefs are out of scope, see the README), so
      # diffing it could only announce "a new domain" and dump it whole under a name
      # the file does not answer to (Yoink and Screen Sharing did, on 27.0). Dropped,
      # and said under --debug.
      if [ "$cat_type" = "CONTAINER" ]; then
        _dbg_filtered "$(domain_from_plist_path "$plist") (container prefs. Out of scope, see README)"
        continue
      fi
      # Same reasoning for any other tree. Root's own ~/Library/Preferences
      # under sudo, another user's, a mounted volume's: no baseline, so nothing
      # true can be said about it. It used to fall into the SYSTEM branch.
      if [ "$cat_type" = "OTHER" ]; then
        _dbg_filtered "$(domain_from_plist_path "$plist") (outside the watched preference trees: $plist)"
        continue
      fi
      # Debounce per-plist using EPOCHREALTIME (float seconds, fork-free via zsh/datetime)
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
        # Track active domain so poll_watch can flush cfprefsd for it next iteration
        /usr/bin/touch "$PREFWATCH_TMPDIR/active-domains/$dom" 2>/dev/null || true
        # Preemptive flush: hint cfprefsd to sync pending writes now so
        # show_plist_diff's retry loop catches the change on its first iteration.
        # Use -currentHost for ByHost paths (the bare read syncs the standard plist).
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
    # Reaching here means fs_usage exited and real-time detection is over for this
    # run: report it, with whatever fs_usage said on its way out.
    [ -n "$_fw_watchdog" ] && { /bin/kill "$_fw_watchdog" 2>/dev/null || true; }
    local _why=""
    [ -s "$_fsu_err" ] && _why=$(/usr/bin/head -1 "$_fsu_err" 2>/dev/null)
    if [ -s "${PREFWATCH_TMPDIR}/fs_usage.rss" ]; then
      local _fw_hit=""; _fw_hit=$(/bin/cat "${PREFWATCH_TMPDIR}/fs_usage.rss" 2>/dev/null) || _fw_hit="?"
      _log_note_wrapped "" "real-time detection stopped by PrefWatch: fs_usage reached ${_fw_hit} MB (limit ${FS_USAGE_RSS_LIMIT_MB} MB), the machine's file activity outran it. Polling continues, at the same latency."
      return 0
    fi
    case "$_why" in
      *"Resource busy"*)
        # Name the process HOLDING the slot: `ktrace info` says "Owning process is [N]"
        # (proven on a VM: FlexNet's licensing service, and killing it let fs_usage
        # start). "Last configured by" is kept only as a labelled fallback, since on a
        # healthy Mac it names tailspind while fs_usage runs fine. Every capture is
        # guarded: `ktrace info` fails without root, and under pipefail an unguarded
        # assignment would kill this watcher mid-report.
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
        # Each branch supplies its own full clause, so the sentence reads correctly
        # in all three cases. Appending an attribution to a fixed "it is taken"
        # gave "taken, held by …" (redundant) and "taken, last configured by …".
        log_line "Cmd: # NOTE: real-time detection OFF. Ktrace allows one client and it is ${_fsu_who:-taken}."
        # Measured, not "a little slower": 0.47s with real-time against 0.49s without,
        # the 0.5s poll interval either way; and ~/Library/Containers is seen by
        # neither. Polling loses nothing fs_usage was providing.
        log_line "Cmd: #       Polling covers the same ground at the same latency (measured)." ;;
      "")
        log_line "Cmd: # NOTE: real-time detection stopped (fs_usage exited without a message). Polling continues" ;;
      *)
        log_line "Cmd: # NOTE: real-time detection stopped. Fs_usage: $_why" ;;
    esac
  }

  # Fallback detector. Periodic poll (find -newer) for writes fs_usage buffers/misses.
  poll_watch() {
    local marker_user marker_sys active_dir
    # Locals declared ONCE, outside the loop: re-running `local foo` on a variable
    # that holds a value prints `foo=value` (TYPESET_SILENT is off).
    local _hd _af _adom _p _watchdog
    local -a _pids _hotpaths
    local -A _st
    marker_user="$PREFWATCH_TMPDIR/poll.marker.user"
    marker_sys="$PREFWATCH_TMPDIR/poll.marker.sys"
    active_dir="$PREFWATCH_TMPDIR/active-domains"
    /bin/mkdir -p "$active_dir" 2>/dev/null || true
    # Hot-marker paths built ONCE: the refresh below used to fork one `touch` per
    # hot domain per cycle (20 forks every 0.5s, for the life of the process). One
    # `touch` with all paths does the same job. `${^array}` distributes the prefix.
    _hotpaths=()
    (( ${#HOT_DOMAINS[@]} )) && _hotpaths=("$active_dir/"${^HOT_DOMAINS})
    # Only create markers if not pre-initialized (avoids rescanning all plists after initial snapshot)
    [ -f "$marker_user" ] || /usr/bin/touch "$marker_user" 2>/dev/null || true
    [ -f "$marker_sys" ]  || /usr/bin/touch "$marker_sys" 2>/dev/null || true

    while true; do
      # Flush cfprefsd for recently-active domains (last 30s) before polling.
      # `defaults read` forces cfprefsd to sync pending writes for that domain.
      if [ -d "$active_dir" ] && [ "$HAVE_ZSH_STAT" = "true" ]; then
        # Refresh hot markers so they never expire via the 30s cleanup below
        (( ${#_hotpaths[@]} )) && { /usr/bin/touch "${_hotpaths[@]}" 2>/dev/null || true; }
        _pids=()
        # (DN), not (N): zsh globs skip dot-prefixed names by default, and
        # `.GlobalPreferences` is a declared HOT domain. Its marker was created
        # here and never seen, so the one domain holding NSGlobalDomain and the
        # ColorSync device map never got the cfprefsd flush meant for it.
        for _af in "$active_dir"/*(DN); do
          [ -f "$_af" ] || continue
          zstat -H _st "$_af" 2>/dev/null || continue
          if (( EPOCHSECONDS - _st[mtime] > 30 )); then
            /bin/rm -f "$_af" 2>/dev/null || true
            continue
          fi
          _adom="${_af:t}"
          # One bare read per domain. No `-currentHost` here. It doubled the
          # fork/hang surface; ByHost is flushed by show_plist_diff/fs_watch instead.
          "${RUN_AS_USER[@]}" /usr/bin/defaults read "$_adom" >/dev/null 2>&1 &
          _pids+=($!)
        done
        # Watchdog: a hung cfprefsd read would freeze the loop on `wait`. Kill
        # stragglers (TERM 1s / KILL 1.5s). Missing a flush hint is harmless.
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

      # Stamp the NEXT marker BEFORE scanning and apply it after: advancing it to
      # "now" once the loop has finished loses every plist written during the scan
      # and its processing (up to ~1.8s per changed plist), for good. Proven on a
      # model: undetected over six cycles one way, caught on the first the other.
      /usr/bin/touch "$marker_user.next" 2>/dev/null || true
      if [ -d "$prefs_user" ]; then
        /usr/bin/find "$prefs_user" -type f -name "*.plist" -newer "$marker_user" 2>/dev/null | while IFS= read -r f; do
          [ -n "$f" ] || continue
          dom=$(domain_from_plist_path "$f")
          if is_excluded_domain "$dom"; then
            continue
          fi
          # Track active domain for next iteration's targeted flush
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

  # Printer Sharing toggle. Own sub-shell so the lpstat 5s debounce never blocks
  # it. Reads cupsd.conf's Browsing directive directly (written before cupsd reloads).
  cups_sharing_watch() {
    local cupsdconf="/etc/cups/cupsd.conf"
    [ -f "$cupsdconf" ] || { log_line "Cmd: # cups_sharing_watch DISABLED: $cupsdconf not present"; return 0; }
    local share_snap=""
    share_snap=$(/usr/bin/grep -iE "^Browsing[[:space:]]+" "$cupsdconf" 2>/dev/null | /usr/bin/head -1 | /usr/bin/awk '{print tolower($2)}' || true)
    [ -z "$share_snap" ] && share_snap="off"

    while true; do
      /bin/sleep 0.5 || true
      [ -f "$cupsdconf" ] || continue
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

  # Printer add/remove detector. Diffs the CUPS printer list (lpstat).
  cups_watch() {
    local cups_snapshot cups_current
    cups_snapshot="$PREFWATCH_TMPDIR/cups.snap"
    cups_current="$PREFWATCH_TMPDIR/cups.curr"

    # Initial snapshot of installed printers
    /usr/bin/lpstat -a 2>/dev/null | /usr/bin/awk '{print $1}' | /usr/bin/sort > "$cups_snapshot" 2>/dev/null || true

    # `|| true` on every sleep in a watcher loop: the shutdown's TERM lands in
    # the sleep, which then exits non-zero, and under set -e the ERR trap logged
    # "# ABORT: set -e … (in cups_watch)" on a clean stop (seen on 27.0).
    while true; do
      /bin/sleep 1 || true
      /usr/bin/lpstat -a 2>/dev/null | /usr/bin/awk '{print $1}' | /usr/bin/sort > "$cups_current" 2>/dev/null || true

      # Debounce: if list changed, wait 5s and re-check to filter DNS-SD/Bonjour glitches
      if ! /usr/bin/cmp -s "$cups_snapshot" "$cups_current"; then
        /bin/sleep 5 || true
        /usr/bin/lpstat -a 2>/dev/null | /usr/bin/awk '{print $1}' | /usr/bin/sort > "$cups_current" 2>/dev/null || true
      fi

      # Detect added printers
      /usr/bin/comm -13 "$cups_snapshot" "$cups_current" 2>/dev/null | while IFS= read -r printer; do
        [ -z "$printer" ] && continue
        log_line "Cmd: # CUPS: printer added. $printer"

        local uri=""
        # `|| uri=""`: `lpstat -v <unknown>` exits 1 (adding a printer reloads cupsd,
        # which answers "Unable to connect to server" meanwhile), and a captured pipe
        # under set -e + pipefail killed this watcher for the session.
        uri=$(/usr/bin/lpstat -v "$printer" 2>/dev/null | /usr/bin/sed -nE 's/.*:[[:space:]]+(.*)/\1/p') || uri=""

        # Extract non-default options
        local opts=""
        opts=$( { /usr/bin/lpoptions -p "$printer" 2>/dev/null | /usr/bin/tr ' ' '\n' | /usr/bin/grep -E '^(media|sides|print-color-mode|print-quality|printer-is-shared)=' | while IFS= read -r o; do printf " -o %s" "$o"; done; } || true)  # grep exits 1 if the printer has none of these → guard set -e

        # Same reason as fw_apps above. A CUPS queue name forbids space and '/'
        # but NOT `$`, backtick or parentheses, and the device URI carries fields
        # straight out of an mDNS announcement.
        local cmd="sudo lpadmin -p \"$(_escape_dq "$printer")\""
        [ -n "$uri" ] && cmd="$cmd -v \"$(_escape_dq "$uri")\""
        cmd="$cmd -m everywhere -E${opts}"
        log_line "Cmd: $cmd"
      done

      # Detect removed printers
      /usr/bin/comm -23 "$cups_snapshot" "$cups_current" 2>/dev/null | while IFS= read -r printer; do
        [ -z "$printer" ] && continue
        log_line "Cmd: # CUPS: printer removed. $printer"
        log_line "Cmd: sudo lpadmin -x \"$(_escape_dq "$printer")\""
      done

      /bin/cp -f "$cups_current" "$cups_snapshot" 2>/dev/null || true
    done
  }

  # Stream eslogger exec events for sharing CLIs (kickstart/systemsetup/sharing/
  # networksetup). UI toggles that modify state outside /Library/Preferences.
  # Requires root + eslogger (Ventura+) + Python3.
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

    # Python reads stdin with readline(): `for line in sys.stdin` buffers and would
    # never fire on a sparse stream. -u unbuffers stdout. The trailing " in each
    # grep pattern anchors on eslogger's JSON executable-path field.
    /usr/bin/eslogger exec 2>/dev/null \
      | /usr/bin/grep --line-buffered -F -e '/kickstart"' -e '/systemsetup"' -e '/sharing"' -e '/networksetup"' -e '/launchctl"' \
                                     -e '/scselect"' -e '/tmutil"' -e '/nvram"' -e '/AssetCacheManagerUtil"' \
      | "$PYTHON3_BIN" -u -c '
import json, sys, shlex, time
# basename -> the ONE path it is allowed to have. Matching the basename alone
# let any local user run their own `sharing` and have PrefWatch write
# `sudo /Users/eve/bin/sharing …` into a log meant for a root shell (verified
# with a synthetic exec event). An exec at another path is dropped.
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
# kickstart is a Perl script → its exec reports `perl` with .../kickstart in args.
# Resolve the real command from args for interpreters only, NOT launchers like
# sudo (which re-exec the target as its own event → would emit it twice).
SCRIPT_INTERPRETERS = ("perl", "python", "python3", "ruby", "bash", "sh", "zsh")
# launchctl is the writeconfig-XPC worker macOS Tahoe System Settings drives.
# Keep only state-changing subcommands; drop kill/list/print/dumpstate noise.
LAUNCHCTL_SUBCMDS = {"load", "unload", "enable", "disable", "bootstrap", "bootout", "kickstart"}
# Third-party apps (Zoom/MS/Adobe/VM updaters) churn their OWN LaunchAgents via
# these same verbs, so whitelist Apple sharing labels only and drop the rest.
# "/ssh.plist" keeps the leading slash so it matches only the real ssh LaunchDaemon
# path. A bare "ssh.plist" substring also matched a jamf ".../startssh.plist" task.
SHARING_LABELS = ("com.apple.smbd", "com.apple.screensharing", "com.openssh.sshd",
                  "/ssh.plist", "com.apple.RemoteDesktop", "com.apple.ARDAgent")
# networksetup/systemsetup are polled read-only by macOS daemons (Wi-Fi refresh,
# Network scan, time sync). Drop queries. Sometimes invoked WITHOUT the dash
# (`networksetup listallhardwareports`), so strip dashes first; write verbs all
# start with set/create/remove/add/switch/… anyway.
READONLY_VERBS = ("get", "list", "print", "show")
# The tools PrefWatch itself emits are watched too, so an admin running one by
# hand on a monitored Mac is reported like any other change. Their read verbs
# outnumber their write verbs, so these carry a WHITELIST of writes instead:
# anything not listed is a query and is dropped.
WRITE_VERBS = {
    "tmutil": ("enable", "disable", "startbackup", "stopbackup", "addexclusion",
               "removeexclusion", "setdestination", "removedestination", "delete",
               "deletelocalsnapshots", "deleteinprogress", "inheritbackup",
               "associatedisk", "localsnapshot", "restore"),
    "AssetCacheManagerUtil": ("activate", "deactivate", "flushCache", "flushPersonalCache",
                              "flushSharedCache", "reloadSettings", "moveCacheTo",
                              "absorbCacheFrom"),
}
# A Time Machine exclusion on a TEMPORARY path is an app housekeeping its own
# scratch space (the .noindex folder of a build tool under /var/folders, seen on
# 27.0), never a setting anyone deploys. Treated as a read: dropped.
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
        # A write is name=value; -d deletes one, -c clears all. Everything else
        # (-p, -x, a bare variable name) reads.
        return not any("=" in a for a in rest) and not any(a in ("-d", "-c") for a in rest)
    if basename == "scselect":
        # With no location argument it only lists the sets. -n defers the switch
        # to the next boot but is still a switch, so flags alone are not enough.
        return not [a for a in rest if not a.startswith("-")]
    if basename not in ("networksetup", "systemsetup"):
        return False
    if len(args) < 2:
        return True
    sub = args[1].lstrip("-")
    return sub.startswith(READONLY_VERBS)
# Dedup: macOS sometimes fires the same exec twice back-to-back
# (eg smbd reload). Skip identical commands within 1s.
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
        # Interpreted DIRECT_BIN (kickstart = Perl): rewrite to the script command.
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
            # An argument carrying a newline would be re-emitted as TWO `Cmd:`
            # lines, the second one being attacker text presented as a command.
            # shlex.quote preserves \n, and the shell side reads this stream line
            # by line. Nothing legitimate needs it.
            if any("\n" in a for a in args):
                continue
            tail = " ".join(shlex.quote(a) for a in args[1:]) if len(args) > 1 else ""
            # shlex.quote on the PATH too, not only on the args below it: `exe`
            # is the path of any binary any local user just ran, and it lands in a
            # `sudo …` line an admin replays as root.
            emit((shlex.quote(exe) + " " + tail).rstrip())
        elif (basename == "launchctl" and exe == "/bin/launchctl"
              and len(args) > 1 and args[1] in LAUNCHCTL_SUBCMDS
              and not any("\n" in a for a in args)):
            # Sharing-only: drop third-party LaunchAgent churn (e.g. Zoom/MS
            # updaters bootstrapping us.zoom.updater.* in gui/<uid>).
            if not any(lbl in " ".join(args) for lbl in SHARING_LABELS):
                continue
            # Skip load/unload churn of socket-activated system daemons that
            # launchd cycles on its own (smbd, bootpd, dhcp6d). Their real
            # persistent state is reported by launchd_state_watch.
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
          # macOS itself writes the login window keyboard to NVRAM whenever the
          # input sources change (seen on 27.0 on every add/remove of a layout).
          # A bare nvram line under an input-source edit reads as a mystery, or
          # as something the admin did; say where it comes from and what it is.
          case "$cmd" in
            */nvram\ prev-lang:kbd=*)
              _note_should_show __nvram_prevlang__ \
                && _log_note_wrapped "" "macOS wrote this itself when the input sources changed. It sets the keyboard layout and language of the login window." ;;
          esac
          # Re-emitted sharing CLIs (systemsetup/sharing/networksetup/kickstart/
          # launchctl) all need root. Prefix sudo like every other privileged emit.
          log_line "Cmd: sudo $cmd"
          # Drop a timestamped marker per service so launchd_state_watch can
          # detect when it's about to emit an equivalent form and add a NOTE.
          # Match: launchctl <verb> -w <…/com.apple.<svc>.plist>
          if [[ "$cmd" =~ launchctl[[:space:]]+(load|unload)[[:space:]]+-w[[:space:]]+[^[:space:]]+/([^/]+)\.plist ]]; then
            /usr/bin/touch "$PREFWATCH_TMPDIR/sharing_recent/${match[2]}" 2>/dev/null || true
          fi
        done
  }

  # Poll launchd's disabled.plist every 2s: Tahoe flips sharing services via pure
  # XPC (no exec event), but the disabled state lands here. Emit launchctl
  # enable/disable per transition. Requires root + Python3 (JSON diff).
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
# Third-party VM / container helpers that auto-toggle their own launchd
# state in the user gui session. Not user-driven preference changes.
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
# gui/<uid> services live in the console user's domain. A root replay needs
# `launchctl asuser <uid> …`, not a bare `launchctl … gui/<uid>/…`. System stays.
def _lc(verb, k):
    # `k` is a label an unprivileged user can put there with
    # `launchctl disable gui/<uid>/<label>`, and the line is emitted with a
    # `sudo` prefix. Quote it.
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

    # Resolve a launchd label to its LaunchDaemon plist: filename = label (smbd,
    # screensharing), else one grep over the text plists confirmed by the Label key
    # (com.openssh.sshd lives in ssh.plist). Unresolved → the caller's reboot NOTE.
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

    # Emit the enable/disable line, a dedup NOTE when sharing_exec_watch logged the
    # equivalent load/unload in the last 10s, and (system domain) the
    # bootstrap/bootout companion: enable/disable only flips the on-disk flag, and
    # a socket service (smbd, ssh) does not start or stop until launchd reloads it.
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
      # launchctl in the system domain (and `asuser` for gui) needs root, like
      # every other privileged emit. Prefix sudo for a copy-paste deploy.
      log_line "Cmd: sudo $cmd"

      # Bootstrap/bootout companion (system daemons only. Gui agent plist
      # paths vary; for those a reboot also applies the enable/disable).
      if [ "$_ld_domain" = "system" ] && [ -n "$_svc" ]; then
        local _companion=""
        if [ "$_verb" = "enable" ]; then
          local _ld_plist=""
          _ld_plist=$(_resolve_launchd_plist "$_svc") || _ld_plist=""
          [ -n "$_ld_plist" ] && _companion="sudo /bin/launchctl bootstrap system \"$_ld_plist\""
        else
          _companion="sudo /bin/launchctl bootout system/${_svc}"
        fi
        # Burst-dedup (like every other NOTE) not once-per-session: show it once
        # per service-toggle burst, re-show after 15s of quiet. So a later,
        # separate sharing change still carries its explanation. The actionable
        # bootstrap/bootout command below is emitted every time regardless.
        if _note_should_show __launchd_bootstrap__; then
          _log_note_wrapped "" "enable/disable only sets the persistent flag; a socket/on-demand service (smbd, ssh, screensharing) won't start/stop, and its UI toggle won't move, until launchd (re)loads it via bootstrap/bootout, or a reboot"
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

  # Monitor energy/battery settings via pmset
  pmset_watch() {
    # Human-readable labels for known pmset values
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

    # Initial snapshot
    /usr/bin/pmset -g custom > "$pmset_snapshot" 2>/dev/null || true

    while true; do
      /bin/sleep 2 || true
      /usr/bin/pmset -g custom > "$pmset_current" 2>/dev/null || true

      # Quick check. Skip parsing if nothing changed
      if ! /usr/bin/cmp -s "$pmset_snapshot" "$pmset_current"; then
        # Parse both snapshots into "section|key|value" lines and diff
        local snap_parsed="" curr_parsed=""  # init: re-`local` in this loop would print the vars
        snap_parsed=$(/usr/bin/awk '/^[A-Z]/{sec=$0; sub(/:$/,"",sec); next} NF>=2{val=$NF; key=""; for(i=1;i<NF;i++){if(i>1)key=key" "; key=key$i}; gsub(/^[[:space:]]+|[[:space:]]+$/,"",key); print sec "|" key "|" val}' "$pmset_snapshot")
        curr_parsed=$(/usr/bin/awk '/^[A-Z]/{sec=$0; sub(/:$/,"",sec); next} NF>=2{val=$NF; key=""; for(i=1;i<NF;i++){if(i>1)key=key" "; key=key$i}; gsub(/^[[:space:]]+|[[:space:]]+$/,"",key); print sec "|" key "|" val}' "$pmset_current")

        # Find changed or added settings in current
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
          # `pmset -g custom` prints DISPLAY LABELS. Every name pmset accepts is one
          # token (measured on 26.6.2: `Sleep On Power Button` is rejected with `Usage:`),
          # so a space is the test, not a list of known labels.
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

  # Remote Management per-user privileges (Observe/Control/…). These live as the
  # `naprivs` bitmask in each user's directory record. Not a plist, and the UI
  # sets them via XPC (no kickstart exec), so fs/poll/launchd/exec watchers all
  # miss them. Poll `dscl . -list /Users naprivs` and emit the replayable write.
  ard_privs_watch() {
    local _ks=/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart
    _read_ardprivs() { /usr/bin/dscl . -list /Users naprivs 2>/dev/null | /usr/bin/sort; }
    _onchange_ardprivs() {
      local _snap="$1" _curr="$2" u v oldv _changed=false
      # Added or changed (a user/value pair in curr not matching snap)
      while IFS=$' \t' read -r u v; do
          [ -n "$u" ] || continue
          oldv=$(/usr/bin/awk -v k="$u" '$1==k{print $2}' "$_snap" 2>/dev/null)
          [ "$oldv" = "$v" ] && continue
          log_line "Cmd: # Remote Management: per-user ARD access for $u (naprivs bitmask)"
          log_line "Cmd: sudo /usr/bin/dscl . -create /Users/$u naprivs $v"
          _changed=true
      done < "$_curr"
      # Removed (user had naprivs in snap, gone from curr → access revoked)
      while IFS=$' \t' read -r u v; do
          [ -n "$u" ] || continue
          /usr/bin/awk -v k="$u" '$1==k{f=1} END{exit !f}' "$_curr" 2>/dev/null && continue
          log_line "Cmd: # Remote Management: ARD access removed for $u"
          log_line "Cmd: sudo /usr/bin/dscl . -delete /Users/$u naprivs"
          _changed=true
      done < "$_snap"
      # Apply: the dscl write (which is exactly what kickstart does internally)
      # only persists the value. The ARD agent must restart to pick it up, or
      # the Options UI / live access won't reflect the change.
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

  # File Sharing SHARE POINTS: which folders are shared and their SMB flags. They
  # live in OpenDirectory (`dscl . -list /SharePoints`), never in a plist, so the
  # diff cannot see them; without this, replaying the smbd launchctl lines started
  # the daemon with whatever the target already shared. Read with
  # `dscl -plist -readall`, present on every supported macOS (`sharing -l -f json`
  # is recent and would read empty on an older one; both give identical output).
  # Flags measured on 26.6.2: `-s` and `-g` take THREE digits (afp, ftp, smb), so
  # smb-only is `001`; `-s 001 -g 000 -R 1 -E 1` reads back as shared/no
  # guest/read-only/sealed, and `sharing -e` flips them back. afp and ftp are
  # "no longer supported", so the first two digits are always 0.
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
    # Only the seven fields a `sharing` command can set. The record also carries
    # com_apple_sharing_uuid / sharepoint_group_id / sharepoint_account_uuid (per
    # machine, would not transplant) and record_daemon_version (pure churn).
    # they are dropped by SELECTING what we need, not by a filter that could rot.
    rows.append((name, one(rec,"directory_path"), one(rec,"smb_shared","0"),
                 one(rec,"smb_guestaccess","0"), one(rec,"smb_readonly","0"),
                 one(rec,"smb_sealed","0"), one(rec,"smb_name", name)))
for row in sorted(rows):
    print("\t".join(str(x) for x in row))
' || true
    }
    # Flags for a NEW share point. -R and -E are the newest options and are emitted
    # only when set, so the common case hands an older macOS nothing unknown.
    _sp_flags_add() {   # <shared> <guest> <readonly> <sealed> <smb name>
      local _f
      _f=$(printf -- '-S "%s" -s 00%s -g 00%s' "$(_escape_dq "$5")" "$1" "$2")
      if [ "$3" = 1 ]; then _f="$_f -R 1"; fi
      if [ "$4" = 1 ]; then _f="$_f -E 1"; fi
      printf '%s' "$_f"
    }
    # Flags for an EDIT: only the fields that changed (measured on 26.6.2). `-S`
    # with the name the share already has is refused ("smb name already exists")
    # and the whole edit is a no-op; an omitted flag is PRESERVED, so read-only
    # 1 -> 0 needs `-R 0` spelled out.
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
            # The shared FOLDER moved. `sharing -e` cannot express that, so the
            # faithful reproduction is a remove followed by a fresh create.
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
      # Removed: present in the snapshot, gone from the current read.
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

  # Bluetooth on/off. A toggle writes nothing to any watched plist (measured with
  # --debug: zero FILTERED lines), so polling is the only way. The probe is
  # `system_profiler SPBluetoothDataType`: moves within 1 s of a toggle, stable at
  # rest, 0.10 s a read. Not `BlueTool -c power`: it reads the controller's power
  # rail, not the setting (stayed at 1 while Off) and prints to stderr only.
  # No `defaults` command reproduces it (the plists are identical On and Off), and
  # BlueTool's flip is undone by bluetoothd within 4 s. The emitted line calls
  # IOBluetoothPreferenceSetControllerPowerState in the public IOBluetooth
  # framework through ctypes: it sets the state, survives a reboot, and needs no
  # third-party tool (python3 on the target is the one requirement, said in a NOTE).
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
      # Key the dedup on the STATE: keyed on the watcher, an off-then-on inside the
      # 15s window logged "turned Off" on a Mac that ended up On. Per-state keying
      # reports every toggle and still collapses a repeat of the same state.
      _note_should_show "__bluetooth__:$_st" || return 0
      # Build the python source in a SINGLE-quoted string so its double quotes stay
      # literal: written into the double-quoted log_line they were eaten and the
      # emitted line was a Python syntax error (caught by EXECUTING it).
      local _py='import ctypes; ctypes.cdll.LoadLibrary("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth").IOBluetoothPreferenceSetControllerPowerState('
      local _cmd="/usr/bin/python3 -c '${_py}${_flag})'"
      # The NOTE states the fact and the command sits on its own line: an admin
      # copies a line, not a sentence.
      log_line "Cmd: # NOTE: Bluetooth turned $_st"
      log_line "Cmd: $_cmd"
      # The TARGET needs a working python3: without the Command Line Tools
      # /usr/bin/python3 is a shim that offers to install them, so under a root
      # policy the line fails and in a session it pops a dialog. The machine that
      # replays is usually not the one PrefWatch ran on.
      _note_should_show __bluetooth_py__ \
        && log_line "Cmd: #       (needs python3 on the TARGET. Without the Command Line Tools /usr/bin/python3 only offers to install them)"
      return 0
    }
    _snapshot_watch bluetooth 2 _read_bluetooth _onchange_bluetooth _guard_nonempty
  }

  # Local user account add/remove (UID >= 501). The account lives in
  # OpenDirectory, not a plist, so a factual NOTE only. `dscl -list` needs no
  # root. The com.apple.preferences.accounts 'deletedUsers' churn is filtered so
  # this NOTE is the single source.
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
    # _guard_nonempty: a transient dscl failure must not report every user as
    # removed. (Cost: removing the very last real user is missed. Negligible.)
    _snapshot_watch useracct 2 _read_useracct _onchange_useracct _guard_nonempty
  }

  # Hostnames land in configd's SystemConfiguration/preferences.plist, where a
  # raw Set is unreliable (filtered in is_noisy_pbcmd); this watcher emits
  # `scutil --set`. `scutil --get` needs no root.
  hostname_watch() {
    [ -x /usr/sbin/scutil ] || return 0
    _read_hostname() {
      local n v
      for n in LocalHostName ComputerName HostName; do
        # `--get` exits non-zero + prints "<Name>: not set" when unset → treat as empty.
        v=$(/usr/sbin/scutil --get "$n" 2>/dev/null) || v=""
        printf '%s\t%s\n' "$n" "$v"
      done
    }
    # LocalHostName is always set. If it read empty, scutil hiccuped; skip so a
    # transient failure can't emit a phantom set / churn the snapshot.
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

  # Default-app handlers live in launchservices.secure.plist, whose domain is
  # EXCLUDED (churny, and a raw Set re-registers nothing). Diff the LSHandlers
  # array and emit `utiluti`, which sets the real default and waits for the
  # macOS confirmation prompt.
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
# http/https + public.html + com.apple.default-app.web-browser are LINKED by
# macOS: collapse them to a single canonical "url http" so one browser change
# emits one command (setting http cascades to the rest).
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
    # comm -13 = associations present now but not before (new or re-pointed);
    # removals (comm -23) aren't reproducible as a `set`, so we skip them.
    _onchange_defapps() {
      local _snap="$1" _curr="$2" _kind _what _app
      while IFS=$'\t' read -r _kind _what _app; do
        [ -n "$_kind" ] || continue
        # One "install utiluti" reminder per burst (deduped for 15s of quiet).
        _note_should_show __default_apps__ && log_line "Cmd: # NOTE: needs utiluti (github.com/scriptingosx/utiluti)"
        # Only the default-browser change (http) pops a macOS confirmation
        # prompt; file types and other schemes apply silently.
        [ "$_kind" = url ] && [ "$_what" = http ] && _note_should_show __default_browser__ \
          && log_line "Cmd: # NOTE: changing the default browser prompts the user to confirm"
        # Both fields come from a plist writable by anything running as the user, and
        # a scheme of `x; curl …|sh; #` injected with no substitution at all. Per-user
        # LaunchServices state: --mdm wraps it like a user `defaults`, or a root policy
        # would set ROOT's default app.
        local _uu="utiluti $_kind set \"$(_escape_dq "$_what")\" \"$(_escape_dq "$_app")\""
        log_line "Cmd: $(_mdm_wrap "$_uu")"
      done < <(/usr/bin/comm -13 "$_snap" "$_curr" 2>/dev/null)
      return 0
    }
    # 1s (not the usual 2s): a default-app change is a discrete user action the
    # admin is actively watching for, so favor responsiveness. The bulk of the
    # residual latency is lsd flushing the secure plist async. Not the poll.
    _snapshot_watch default_apps 1 _read_defapps _onchange_defapps _guard_nonempty
  }

  # Desktop wallpaper lives in the com.apple.wallpaper Store (Index.plist), outside
  # ~/Library/Preferences: not reproducible via defaults, reproducible with
  # desktoppr. Each choice carries a nested binary plist under `Configuration`
  # holding {type: imageFile, url: {relative: file://…}}, a plain percent-encoded
  # URL (verified). A dynamic wallpaper has no file, and the NOTE says so.
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
# Serialize the wallpaper config WITHOUT LastSet/LastUse. The system rewrites
# those timestamps on login without a real change, so ignoring them means we
# only fire on a genuine wallpaper change.
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
    # What the Store holds, as `<kind>\t<location>\t<value>` lines:
    #   I. an image file          → `desktoppr "<path>"`
    #   C. the colour BEHIND it   → `desktoppr color <hex>`  (EncodedOptionValues)
    #   N. a solid system colour  → a NAME, and only a name
    # The LOCATION matters: the Store keeps an entry per display ever seen, and a
    # disconnected one keeps its old value, so the LINES are compared, not the set
    # of values. SystemDefault is skipped, being what a new space inherits. I and C
    # are independent (verified): `desktoppr color` repaints the ground and leaves
    # the image; a solid colour picked in Settings writes N and leaves C untouched,
    # so C is never the chosen colour and must not be emitted as one.
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
    # EncodedOptionValues: {'values': {'color': {'color': {'_0': {'color':
    #   {'components': [r, g, b, a], 'colorSpace': …}}}}, 'placement': …}
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
    # Distinct values of kind $1 among the lines that changed. `cut -f3-`, not
    # `-f3`: a path may contain a tab.
    _wp_changed() { printf '%s\n' "$2" | /usr/bin/grep "^$1	" 2>/dev/null | /usr/bin/cut -f3- | /usr/bin/sort -u || true; }
    _onchange_wallpaper() {
      local _curr="$PREFWATCH_TMPDIR/wallpaper.paths.curr" _new _img _col _nam _ni _nc _p _head=false
      _wallpaper_paths | /usr/bin/sort -u > "$_curr" 2>/dev/null || : > "$_curr"
      _new=$(/usr/bin/comm -13 "$_wp_paths" "$_curr" 2>/dev/null) || _new=""
      # The Store grows rows under a NEW key (a Space, a display) that carry the
      # wallpaper already in place (seen on 27.0: `desktoppr` emitted for a desktop
      # nobody touched). Only a row under a key the baseline had is a change, and a
      # row that VANISHED from a key still present is one too (a dynamic wallpaper).
      # The key is the path up to /Desktop; files are told apart by FILENAME, since
      # NR==FNR swallows stdin when the first file is empty.
      local _gone _wp_known
      _wp_known='function key(p){ sub(/\/Desktop\/.*/, "", p); return p } FILENAME==P{ w[key($2)]=1; next } key($2) in w'
      _gone=$(/usr/bin/comm -23 "$_wp_paths" "$_curr" 2>/dev/null) || _gone=""
      _new=$(printf '%s\n' "$_new" | /usr/bin/awk -F'\t' -v P="$_wp_paths" "$_wp_known" "$_wp_paths" -) || _new=""
      _gone=$(printf '%s\n' "$_gone" | /usr/bin/awk -F'\t' -v P="$_curr" "$_wp_known" "$_curr" -) || _gone=""
      /bin/mv -f "$_curr" "$_wp_paths" 2>/dev/null || true
      [ -z "$_new" ] && [ -z "$_gone" ] && return 0
      # No early return on an empty $_new alone: switching TO a dynamic wallpaper
      # only REMOVES lines, and the change still deserves the NOTE at the bottom.
      _img=$(_wp_changed I "$_new"); _col=$(_wp_changed C "$_new"); _nam=$(_wp_changed N "$_new")
      _ni=0; [ -n "$_img" ] && _ni=$(printf '%s\n' "$_img" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
      _nc=0; [ -n "$_col" ] && _nc=$(printf '%s\n' "$_col" | /usr/bin/wc -l | /usr/bin/tr -d ' ')

      # Same dedup key as _note_desktoppr, so the two sources can't both print the
      # image line for one change (they are separate processes. See that function).
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
        # desktoppr addresses one screen by INDEX, and that index is this Mac's
        # screen order. Not something to emit as a deployable command.
        _log_note_wrapped "" "desktop wallpaper changed. The screens did not all get the same thing, so no single command reproduces it. Deploy per screen with desktoppr (github.com/scriptingosx/desktoppr):"
        printf '%s\n' "$_img" | while IFS= read -r _p; do
          [ -n "$_p" ] && log_line "Cmd: #       desktoppr <screen> \"$(_escape_dq "$_p")\""
        done
        printf '%s\n' "$_col" | while IFS= read -r _p; do
          [ -n "$_p" ] && log_line "Cmd: #       desktoppr <screen> color $_p"
        done
      elif [ -n "$_nam" ]; then
        # A solid colour picked in System Settings. desktoppr CAN set a colour,
        # but only by hex, and the Store records the colour's NAME and nothing
        # else. The RGB sitting in EncodedOptionValues is the separate
        # behind-the-image colour, unchanged by this pick (measured).
        _log_note_wrapped "" "desktop wallpaper set to the solid system colour '$(printf '%s' "$_nam" | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')'. The Store records the name, not the shade, so the exact colour is not recoverable. desktoppr takes a hex value: desktoppr color <RRGGBB>"
      else
        _log_note_wrapped "" "desktop wallpaper changed, but no image or colour moved in the Store. A dynamic wallpaper, which neither defaults nor desktoppr reproduces; set it in System Settings > Wallpaper"
      fi
      return 0
    }
    _snapshot_watch wallpaper 2 _read_wallpaper _onchange_wallpaper _guard_nonempty
  }

  # Privacy & Security permissions live in two SQLite databases, not plists.
  # With Full Disk Access the change is named (service, client, decision);
  # without it the file's mtime and size still move, so it is reported unnamed.
  # Never a command: `tccutil` only RESETS a grant. A grant is a PPPC profile.
  tcc_watch() {
    [ -x /usr/bin/sqlite3 ] || return 0
    local _tcc_sys="/Library/Application Support/com.apple.TCC/TCC.db"
    local _tcc_usr="$TARGET_HOME/Library/Application Support/com.apple.TCC/TCC.db"
    # macOS 27 moved the per-user database into a ProtectedSystem container
    # (/private/var/containers/Data/ProtectedSystem/<UUID>/…/com.apple.TCC/TCC.db),
    # with no symlink at the old path. The container cannot be listed, but the
    # user's own tccd holds the file open: `lsof -p` on that pid names it in 0.09s
    # (`lsof -c tccd` takes minutes). The file answers `stat`, so the metadata
    # fallback works; the SQL read is refused even with Full Disk Access (measured
    # on 27.0), so on 27 the user scope reports "changed", never which permission.
    if [ ! -f "$_tcc_usr" ]; then
      local _tcc_uid="" _tcc_pids="" _tcc_pid="" _tcc_found=""
      _tcc_uid=$(/usr/bin/id -u "${CONSOLE_USER:-$(/usr/bin/id -un)}" 2>/dev/null) || _tcc_uid=""
      if [ -n "$_tcc_uid" ]; then
        _tcc_pids=$(/usr/bin/pgrep -u "$_tcc_uid" -x tccd 2>/dev/null) || _tcc_pids=""
        for _tcc_pid in ${=_tcc_pids}; do
          # The NAME column is last and contains spaces ("Application Support"),
          # so anchor on the path's end, not on a field number.
          _tcc_found=$(/usr/sbin/lsof -p "$_tcc_pid" 2>/dev/null \
            | /usr/bin/sed -nE 's#^.* (/.*/com\.apple\.TCC/TCC\.db)$#\1#p' \
            | /usr/bin/head -1) || _tcc_found=""
          [ -n "$_tcc_found" ] && break
        done
      fi
      if [ -n "$_tcc_found" ] && [ -f "$_tcc_found" ]; then
        _tcc_usr="$_tcc_found"
      else
        # Say so rather than watch half the surface quietly: the summary line
        # above already lists "tcc" as active.
        log_line "Cmd: # NOTE: per-user TCC database not found (~/Library, tccd container). Only SYSTEM privacy permissions are watched"
      fi
    fi
    _read_tcc() {
      local _scope _db
      for _scope in system user; do
        [ "$_scope" = system ] && _db="$_tcc_sys" || _db="$_tcc_usr"
        [ -f "$_db" ] || continue
        # -readonly: never block a system writing the database, and fail on a lock
        # instead of waiting. CAPTURED, not piped into sed: in a pipeline sed's status
        # survives, and a refused read would look like an empty success and silence
        # this watcher on exactly the Macs without Full Disk Access.
        local _rows=""
        if _rows=$(/usr/bin/sqlite3 -readonly -separator $'\t' "$_db" \
                     "select service, client, auth_value from access;" 2>/dev/null); then
          [ -n "$_rows" ] && printf '%s\n' "$_rows" | /usr/bin/sed "s/^/${_scope}\t/"
        else
          # No Full Disk Access (or a locked database): fall back to the file's
          # own metadata, which stays readable, so the change is still seen.
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
        # On 27 the per-user database sits in a ProtectedSystem container that
        # refuses the read even WITH Full Disk Access (measured). Telling the
        # reader to grant FDA would send them to a setting that changes nothing.
        if printf '%s\n' "$_added$_removed" | /usr/bin/grep -q '^user.UNREADABLE' \
           && [ -n "${_tcc_usr:-}" ] && [ "${_tcc_usr#/private/var/containers/}" != "$_tcc_usr" ]; then
          log_line "Cmd: #       Which permission moved is not visible here. This macOS keeps the per-user TCC.db where no process may read."
        else
          log_line "Cmd: #       Which permission moved is not visible here. Reading TCC.db needs Full Disk Access."
        fi
        return 0
      fi

      # A permission that CHANGES is one row leaving and one arriving with the same
      # key: printed as one "before → after" line, where a pane flipping five
      # permissions would otherwise give ten lines to pair by eye. Here-strings, not
      # `printf | while`: a pipeline runs the loop in a subshell and the arrays would
      # be gone. $'\t' is NOT expanded inside an array subscript, hence the separator
      # built once.
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

  # Startup sound and its volume live in NVRAM, not a plist. `nvram` accepts back
  # the same %xx escaping it prints (nvram(8)), so the value read is the value to
  # replay.
  nvram_watch() {
    [ -x /usr/sbin/nvram ] || return 0
    _read_nvram() {
      local _k _v
      for _k in StartupMute SystemAudioVolume; do
        # `nvram <name>` prints "<name>\t<value>" and exits non-zero when unset.
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

  # Time zone is the /etc/localtime symlink (→ …/zoneinfo/<Zone>), not a plist,
  # and a GUI change runs no CLI. Poll the symlink (no root) and emit the exact
  # `systemsetup -settimezone`.
  timezone_watch() {
    [ -L /etc/localtime ] || return 0
    _read_tz() {
      local t; t=$(/usr/bin/readlink /etc/localtime 2>/dev/null) || return 0
      printf '%s' "${t#*/zoneinfo/}"      # /var/db/timezone/zoneinfo/Europe/Paris → Europe/Paris
    }
    # NTP time server lives in /etc/ntp.conf (readable; `systemsetup
    # -getnetworktimeserver` needs root). Same Date & Time pane, folded in here.
    _read_ntp() { /usr/bin/awk '/^server /{print $2; exit}' /etc/ntp.conf 2>/dev/null || true; }
    _read_timezone() { printf 'tz\t%s\nntp\t%s\n' "$(_read_tz)" "$(_read_ntp)"; }
    # Guard: skip a read whose tz is empty (transient readlink failure) so the
    # baseline doesn't churn.
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
            # "Set time zone automatically" (location-based) can overwrite a
            # manual set. Flag it so the deploy sticks.
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

  # Security posture that lives OUTSIDE plists: FileVault (fdesetup), Gatekeeper
  # (spctl), the application firewall (socketfilterfw). All three read WITHOUT
  # root; emit the deploy command (or a NOTE where one command can't reproduce
  # it) on change. Compliance-relevant. Surfaces if a protection got disabled.
  security_watch() {
    local sfw=/usr/libexec/ApplicationFirewall/socketfilterfw
    _read_security() {
      local fv sip gk gkdev _gkv fw fws fwb fwsig
      # `|| true` INSIDE each $(): a grep with no match exits 1 → pipefail +
      # set -e would abort mid-read (killing this watcher / losing later fields).
      fv=$(/usr/bin/fdesetup status 2>/dev/null | /usr/bin/grep -oE 'is (On|Off)' | /usr/bin/head -1 || true)
      # System Integrity Protection. It cannot be CHANGED from a booted Mac (it
      # takes Recovery), so nothing is emitted. But it is exactly as
      # compliance-relevant as the three below, and it was never read at all.
      sip=$(/usr/bin/csrutil status 2>/dev/null | /usr/bin/grep -oE '(enabled|disabled)' | /usr/bin/head -1 || true)
      # `--status --verbose` prints TWO lines: "assessments <state>" (the master
      # Gatekeeper toggle) AND "developer id <state>" (the App Store-only vs
      # +identified-developers sub-mode). The plain --status only shows the first,
      # so switching between the two enabled sub-modes was invisible.
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
    # Guard: skip an empty/partial read (transient tool failure) so we don't churn the snapshot.
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
              # Enabling needs a recovery key (interactive/MDM). Not a single command.
              _log_note_wrapped "" "FileVault is now ${_v#is }. Not reproducible by one command; enable needs a recovery key (sudo fdesetup enable) or an MDM/config profile" ;;
            # `--master-enable`/`--master-disable` are gone from `spctl --help` and the man
            # page on 26.6.2 but still parse: undocumented aliases, the kind that vanishes
            # next release. `--global-enable` is defined word for word as the old enable,
            # so it replaces it. `--global-disable` is NOT the counterpart (it only reveals
            # the "anywhere" option in the pane), so the disable side keeps the old verb
            # and says so.
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
              # App Store-only (developer id disabled) vs +identified-developers.
              # No single spctl command reproduces it. It's a GUI/MDM setting.
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
              # two toggles: built-in signed (--setallowsigned) + downloaded signed (--setallowsignedapp)
              [ "${_v%%,*}" = ENABLED ] && log_line "Cmd: sudo $sfw --setallowsigned on" || log_line "Cmd: sudo $sfw --setallowsigned off"
              [ "${_v#*,}" = ENABLED ] && log_line "Cmd: sudo $sfw --setallowsignedapp on" || log_line "Cmd: sudo $sfw --setallowsignedapp off" ;;
          esac
      done < "$_curr"
      return 0
    }
    _snapshot_watch security 3 _read_security _onchange_security _guard_security
  }

  # Per-app firewall rules (Firewall > Options): com.apple.alf.plist is gone on
  # modern macOS and security_watch covers the global switch only. Poll
  # `socketfilterfw --listapps` (no root) and emit `--add` + `--blockapp`/
  # `--unblockapp`, or `--remove`. Root is needed only to apply.
  fw_apps_watch() {
    local sfw=/usr/libexec/ApplicationFirewall/socketfilterfw
    [ -x "$sfw" ] || return 0
    # Pair each "N : /path" line with its following "(Allow/Block incoming…)"
    # line into "path<TAB>allow|block", sorted for a stable cmp.
    _read_fwapps() {
      "$sfw" --listapps 2>/dev/null | /usr/bin/awk '
        /^[0-9]+ : \// { path=$0; sub(/^[0-9]+ : /,"",path); sub(/[[:space:]]+$/,"",path); next }
        /incoming connections/ { st=(/Block/)?"block":"allow"; if(path!="") print path "\t" st; path="" }
      ' | /usr/bin/sort || true
    }
    _onchange_fwapps() {
      local _snap="$1" _curr="$2" _path _state _oldstate
      # Added or state-changed rules (present now with a new/absent prior state)
      while IFS=$'\t' read -r _path _state; do
        [ -n "$_path" ] || continue
        _oldstate=$(/usr/bin/awk -F'\t' -v p="$_path" '$1==p{print $2}' "$_snap" 2>/dev/null)
        [ "$_oldstate" = "$_state" ] && continue
        _note_should_show __fw_apps__ && log_line "Cmd: # NOTE: per-app firewall rule (Firewall > Options)"
        # _escape_dq on the path: a bundle path the user chose, inside double quotes
        # in a line pasted as root, where `$(…)` would run before socketfilterfw.
        local _pq; _pq=$(_escape_dq "$_path")
        if [ -z "$_oldstate" ]; then log_line "Cmd: sudo $sfw --add \"$_pq\""; fi
        [ "$_state" = block ] && log_line "Cmd: sudo $sfw --blockapp \"$_pq\"" || log_line "Cmd: sudo $sfw --unblockapp \"$_pq\""
      done < "$_curr"
      # Removed rules (in snap, gone from curr → the app's rule was deleted)
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

  # Touch ID lives in the Secure Enclave's store, read and written by `bioutil`
  # (com.apple.biometrickitd.plist is telemetry, already excluded). Two scopes:
  # `-r` reads the CURRENT USER's settings by uid, so it goes through RUN_AS_USER;
  # `-r -s` reads the machine-wide ones and must not. "Effective biometrics" is
  # dropped: it is the AND of both scopes and would report every change twice.
  # bioutil's labels are English on a French system (measured on 26.6.2), unlike
  # `lpstat -d`, so keying on them is safe here.
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
    # A read that produced no system line failed (bioutil absent from the Secure
    # Enclave path, or a transient) -- keep the last good baseline rather than
    # report every setting as removed.
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
          # Per-user Secure Enclave settings: a root policy replaying this bare
          # would configure ROOT's Touch ID, so it is wrapped like a user
          # `defaults`. -a exists ONLY at user scope (bioutil's own usage).
          if [ -n "$_cmd" ]; then
            log_line "Cmd: $(_mdm_wrap "$_cmd")"
            # Measured on 26.6.2: a USER-scope write always prompts for the user's password
            # on stdin, even for the value already in place, and unattended it WAITS rather
            # than fail. System scope answers "Only an admin can adjust", which `sudo` covers.
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
        # A label with no verb is reported, never guessed into a command: bioutil
        # rejects what it does not know, and a dead line in a paste-this log is
        # worse than an honest sentence.
        if [ -z "$_cmd" ] && _note_should_show "__touchid_label__:$_scope:$_key"; then
          log_line "Cmd: # NOTE: Touch ID ($_scope) '$_key' is now $_val. Bioutil has no write verb for it"
        fi
      done < "$_curr"
      return 0
    }
    _snapshot_watch touchid 3 _read_touchid _onchange_touchid _guard_touchid
  }

  # Default printer: cups_watch sees printers arrive and leave, not which one is
  # the default. Read from the lpoptions file, never `lpstat -d`: that line is
  # LOCALISED even under LC_ALL=C ("destination systeme par defaut : NAME"), and
  # with no default its last word is a translated word. The file is read as root
  # (two forks saved a cycle); the EMITTED `lpoptions -d` writes the per-user
  # file, so it is wrapped like a user `defaults` for a root policy.
  defprinter_watch() {
    [ -x /usr/bin/lpoptions ] || return 0
    _read_defprinter() {
      local _f _name=""
      # Per-user first: `lpoptions -d` writes that one, and it is what wins for
      # the logged-in user when both files name a default.
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
      # Empty = no default at all. There is no command for that (`lpoptions -d`
      # requires a destination), so report nothing rather than invent one.
      [ -n "$_name" ] || return 0
      # A default naming a queue that no longer exists is a transient: CUPS picks
      # a new one within the same burst, and cups_watch reports the removal. Emit
      # only a default that can actually be replayed.
      /usr/bin/lpstat -a 2>/dev/null | /usr/bin/awk -v q="$_name" '$1==q{f=1} END{exit !f}' || return 0
      _note_should_show "__defprinter__:$_name" || return 0
      log_line "Cmd: # Printers: default printer is now $_name"
      log_line "Cmd: $(_mdm_wrap "/usr/bin/lpoptions -d \"$(_escape_dq "$_name")\"")"
      return 0
    }
    _snapshot_watch defprinter 3 _read_defprinter _onchange_defprinter
  }

  # Spotlight indexing lives in the metadata store, not a plist: read with
  # `mdutil -s -a` (no root), emit `mdutil -i` on change. EVERY volume, since
  # `/System/Volumes/Data` is the one holding the user's files (five answer here).
  # Not `-v`: it appends "Scan base time … (N seconds ago)", which moves at every
  # probe. Distinct from the com.apple.Spotlight plist (search categories).
  spotlight_watch() {
    [ -x /usr/bin/mdutil ] || return 0
    # `<volume>\t<state>` per line. `mdutil -s -a` prints the volume path on its
    # own line ending in ":", then an indented sentence carrying the state.
    # `|| true` INSIDE the pipe: awk finding nothing exits 0, but mdutil itself
    # can exit non-zero → pipefail + set -e would abort (kill) this watcher.
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
        # A volume ABSENT from the snapshot was just mounted. Its indexing state
        # is what it always was, not a change someone made. Mounting a disk must
        # not emit a command. Same on the way out: a volume that disappeared was
        # unmounted, and there is nothing to reproduce.
        [ -n "$_old" ] || continue
        [ "$_old" = "$_state" ] && continue
        _note_should_show "__spotlight_vol__:$_vol:$_state" || continue
        [ "$_state" = enabled ] \
          && log_line "Cmd: sudo /usr/bin/mdutil -i on \"$(_escape_dq "$_vol")\"" \
          || log_line "Cmd: sudo /usr/bin/mdutil -i off \"$(_escape_dq "$_vol")\""
        # A path under /Volumes is a mounted disk NAMED by whoever formatted it.
        # The command is right here and means nothing on another Mac. The same
        # trap as the ColorSync display UUID, so it gets the same treatment.
        case "$_vol" in
          /Volumes/*)
            log_line "Cmd: #       ('$_vol' is a mounted volume on THIS Mac. The path is not portable)" ;;
        esac
      done < "$_curr"
      return 0
    }
    _snapshot_watch spotlight 3 _read_spotlight _onchange_spotlight _guard_nonempty
  }

  # Pre-initialize poll markers so first iteration only sees post-snapshot changes
  /usr/bin/touch "$PREFWATCH_TMPDIR/poll.marker.user" 2>/dev/null || true
  /usr/bin/touch "$PREFWATCH_TMPDIR/poll.marker.sys" 2>/dev/null || true
  # Create active-domains tracking dir (shared by fs_watch + poll_watch)
  /bin/mkdir -p "$PREFWATCH_TMPDIR/active-domains" 2>/dev/null || true
  # Pre-seed the hot domains; poll_watch refreshes them so they never expire.
  local _hd
  for _hd in "${HOT_DOMAINS[@]}"; do
    /usr/bin/touch "$PREFWATCH_TMPDIR/active-domains/$_hd" 2>/dev/null || true
  done

  # Launch every watcher whose guard passes. Single loop over the SAME _WATCHERS
  # registry that built the summary line above. `eval "$_W_GUARD"` sits in an `if`
  # so a false guard (e.g. non-root for fs) can't set -e-abort. Adding a watcher
  # now means ONE registry entry: no separate launch line, no PID var, no trap.
  local _w=""
  for _w in "${_WATCHERS[@]}"; do
    _watcher_parse "$_w"
    if eval "$_W_GUARD"; then _spawn "$_W_FN"; fi
  done

  # Arm the orphan watchdog before the traps: it is the only thing that survives a
  # SIGKILL of main, which no trap can catch.
  local _wt_self=""
  [ "${HAVE_ZSH_SYSTEM:-false}" = true ] && _wt_self="${sysparams[pid]}"
  if [ -n "$_wt_self" ]; then
    _orphan_watchdog "$_wt_self" &
    _WATCH_PIDS+=($!)
  fi

  # EXIT too, armed HERE: a trap inherited from main does not fire in a `&` job
  # (measured), so an ERR_EXIT abort of the watcher root left 16 sub-watchers
  # reparented to launchd, out of _kill_tree's reach once WATCH_PID was dead.
  trap '_watchers_teardown; exit 0' TERM INT
  trap '_watchers_teardown' EXIT
  wait
}

# ============================================================================
# MAIN. Pre-flight, logging setup, launch
# ============================================================================

# Pre-flight banner + conditional confirmation. The y/n prompt only appears
# when Python3/CLT is missing (degraded detection. User should acknowledge).
# With CLT installed, start directly. Non-interactive contexts (Jamf Self
# Service / launchd / cron) always auto-confirm and log the decision.
_pf_target="$DOMAIN"
if [ "$ALL_MODE" = "true" ]; then
  [ "$INCLUDE_SYSTEM" = "true" ] && _pf_target="ALL (user + system)" || _pf_target="ALL (user only)"
fi
printf "PrefWatch: %s → %s\n" "$_pf_target" "$LOGFILE"
if [ -z "$PYTHON3_BIN" ]; then
  # Prompt contains the warning so Jamf GUI users (who never see stdout) get
  # full context in the osascript dialog. Capture return in `||` context so
  # set -e doesn't exit on non-zero returns (1 = declined, 2 = no channel).
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

# Prepare log file
LOGFILE="$(prepare_logfile "$LOGFILE")"

# Announce the log path, the prefwatch version and the macOS build: preference
# layouts move between releases, so a report without them is unactionable.
# Printed even under ONLY_CMDS, once.
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

# Python3 status. User already consented at pre-flight; log/warn only
if [ -n "$PYTHON3_BIN" ]; then
  log_line "Python3: $PYTHON3_BIN (array change detection enabled)"
else
  printf "WARNING: Xcode Command Line Tools not installed. Python3 unavailable\n"         | tee -a "$LOGFILE" 2>/dev/null || true
  printf "Without Python3: array/dict changes and PlistBuddy commands will not be detected\n" | tee -a "$LOGFILE" 2>/dev/null || true
  /usr/bin/logger -t "prefwatch[init]" -- "Python3 unavailable. Limited detection"
fi

# Warn if ALL mode without root. The old wording said real-time was disabled and
# "only polling will be used (slower)". Measured false: with fs_usage running or
# not, the same commands come out at the same latency. So name what root actually
# adds, and do not advertise a slowdown that does not happen.
if [ "$ALL_MODE" = "true" ] && [ "$(id -u)" -ne 0 ]; then
  local _ts; _ts="$(get_timestamp)"
  local _w1="[$_ts] NOTE: running without sudo. User preferences are fully covered"
  local _w2="[$_ts]   Not covered: /Library/Preferences (system), sharing commands, launchd state"
  local _w3="[$_ts]   For those, re-run with: sudo $0 ALL"
  printf "%s\n%s\n%s\n" "$_w1" "$_w2" "$_w3"
  printf "%s\n%s\n%s\n" "$_w1" "$_w2" "$_w3" >> "$LOGFILE" 2>/dev/null || true
  /usr/bin/logger -t "prefwatch[init]" -- "Running without sudo. System prefs and root-only watchers unavailable"
fi

# Warn if domain is normally excluded (but don't stop. User explicitly requested it)
if [ "$ALL_MODE" != "true" ] && is_excluded_domain "$DOMAIN"; then
  log_line "Cmd: # NOTE: $DOMAIN is normally excluded in ALL mode, but monitoring as explicitly requested"
fi

# Try to open Console.app (unless --no-console)
[ "$NO_CONSOLE" = "true" ] || launch_console

# Start monitoring in background
if [ "$ALL_MODE" = "true" ]; then
  start_watch_all &
else
  start_watch &
fi
WATCH_PID=$!

# Teardown on a signal aimed at the MAIN pid (a supervisor, launchd, `kill
# <pid>`): by default it would kill this shell, skip the EXIT trap and orphan the
# watcher tree with the tmpdir. Ctrl-C already reaches the child's own trap.
# _kill_tree walks main → WATCH_PID → sub-watchers → workers leaves first, so a
# nested subshell cannot reparent away and linger.
_kill_tree() {
  local _root=$1 _kid
  [ -n "$_root" ] || return 0
  # `|| true`: pgrep exits 1 when a process has no children, which is the normal
  # case at every LEAF of the recursion. Without the guard that non-zero status
  # trips ERR_EXIT and aborts the teardown mid-tree (observed: three
  # "# ABORT: set -e … (in _kill_tree)" lines on a single Console-close shutdown).
  for _kid in $(pgrep -P "$_root" 2>/dev/null || true); do _kill_tree "$_kid"; done
  kill -TERM "$_root" 2>/dev/null || true
}
_shutdown_watcher() {
  # Idempotent: the signal traps run it then `exit`, which fires the EXIT trap,
  # which runs it again. Second call is a no-op rather than a second kill/rm pass.
  [ "${_SHUTDOWN_DONE:-false}" = "true" ] && return 0
  typeset -g _SHUTDOWN_DONE=true
  _kill_tree "${WATCH_PID:-}"
  wait ${WATCH_PID:-} 2>/dev/null || true
  # A kill DURING the initial snapshot leaves transient `_snapshot_one_plist &` workers
  # briefly writing into the tmpdir, so a single rm races and loses. Nothing respawns once
  # the tree is dead; retry until the in-flight handful drains (~1s) and the rm wins.
  local _i
  for _i in 1 2 3 4 5 6; do
    /bin/rm -rf "$PREFWATCH_TMPDIR" 2>/dev/null || true
    [ -d "$PREFWATCH_TMPDIR" ] || break
    sleep 0.3
  done
}
trap '_shutdown_watcher; exit 143' TERM
trap '_shutdown_watcher; exit 130' INT
trap '_shutdown_watcher; exit 129' HUP
# Re-arm EXIT on the same teardown: until here it only removed the tmpdir, so an
# ERR_EXIT abort, an internal `exit` or an untrapped signal left the whole
# watcher tree running as root (the 1.4.3 leak). EXIT fires in the MAIN pid
# only (measured: not in `&` jobs nor `( )` subshells), so it is safe globally.
trap '_shutdown_watcher' EXIT

if [ "$NO_CONSOLE" != "true" ] && is_console_running; then
  # Console-close detection, by PID: `kill -0` is a builtin, where `pgrep -x
  # Console` every second cost ~50 s of CPU an hour. A name lookup happens only
  # when the PID stops answering (quit, or relaunched with a new PID), and N
  # CONSECUTIVE misses are required before concluding: one transient miss must not
  # end monitoring. `sleep … || true` because a worker's SIGCHLD interrupts it.
  # `|| true` on the pgrep capture is load-bearing: under pipefail a pgrep that
  # matches nothing kills main by ERR_EXIT, skipping _shutdown_watcher and
  # stranding the root watcher tree (the 1.4.3 leak).
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
  # Reuse the traps' teardown, never a bare `kill -TERM "$WATCH_PID"`: that only
  # reached the sub-watchers, and their pipeline members (eslogger, fs_usage) were
  # reparented to launchd still running as root. Console closing is how a Jamf
  # session ends, so every run leaked an Endpoint Security client. Signature:
  # tmpdir removed, grandchildren alive.
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
