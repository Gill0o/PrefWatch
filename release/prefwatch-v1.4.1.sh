#!/bin/zsh
# ============================================================================
# Script: prefwatch.sh
# Version: 1.4.1
# Author: Gilles Bonpain
# Powered by Claude AI
# Description: Monitor and log changes to macOS preference domains
# ============================================================================
# Usage:
#
# CLI Mode (direct execution):
#   ./prefwatch.sh [domain] [OPTIONS]
#
#   Arguments:
#     [domain]              Preference domain (default: "ALL")
#                           Examples: NSGlobalDomain, com.apple.finder, ALL
#
#   Options:
#     -l, --log <path>      Custom log file path (default: auto-generated)
#     -s, --include-system  Include system preferences in ALL mode (default)
#     --no-system           Exclude system preferences in ALL mode
#     -v, --verbose         Show detailed debug output with timestamps
#     -q, --only-cmds       Show only executable commands (default)
#     --debug               Log '# FILTERED: …' for suppressed detected changes
#     -e, --exclude <glob>  Comma-separated glob patterns to exclude
#     -h, --help            Show this help message
#     --mdm                 MDM deployment mode: replace user home path with
#                           $loggedInUser variable in PlistBuddy commands
#     --no-console          Don't open Console.app / don't stop when it closes
#                           (run until Ctrl+C) — for interactive/VM testing
#
#   Examples:
#     ./prefwatch.sh                    # Monitor ALL (default)
#     ./prefwatch.sh -v                 # Monitor ALL verbose
#     ./prefwatch.sh --log /tmp/all.log # Monitor ALL with custom log
#     ./prefwatch.sh NSGlobalDomain     # Monitor specific domain
#     ./prefwatch.sh com.apple.finder -v # Specific domain verbose
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
#     $6 = INCLUDE_SYSTEM (true/false) — include system preferences (default: true)
#     $7 = ONLY_CMDS (true/false) — show only commands without debug (default: true)
#     $8 = EXCLUDE_DOMAINS — comma-separated glob patterns to exclude
#          Example: ContextStoreAgent*,com.jamf*,com.adobe.*
#     $9 = MDM_OUTPUT (true/false) — replace user home path with $loggedInUser
#          variable in PlistBuddy commands for MDM deployment (default: false)
#     $10 = HOT_DOMAINS — comma-separated list of domains kept permanently
#          "active" so their first change is detected without fs_usage→poll
#          round-trip. Defaults: the common System Settings panels (Finder,
#          Dock, Control Center, keyboard/trackpad/mouse, Accessibility,
#          Spotlight, etc. — see HOT_DOMAINS array). Pass "NONE" to disable.
#     $11 = DEBUG (true/false) — log '# FILTERED: <dom> <key> (reason)' when a
#          detected change is suppressed (noise key / excluded domain). Equivalent
#          of the CLI --debug flag. Default: false.
# ============================================================================

# ============================================================================
# CONFIGURATION
# ============================================================================

# Execution security (zsh)
set -e
set -u
set -o pipefail

# Self-diagnostic: on a `set -e` abort, record WHERE before the shell dies. The
# /var/log file runs in ONLY_CMDS and captures neither the abort nor stderr, and
# a managed VM's Terminal may not be watched — so a crash otherwise leaves no
# trace. TRAPZERR fires ONLY when a non-zero command would trigger ERR_EXIT
# (commands guarded by ||/&&/if/while don't fire it), so it's silent in normal
# operation and pinpoints a real crash to file:line + function. It does NOT
# prevent the exit — it just annotates it. (A SIGKILL — e.g. an EDR killing the
# process — can't be trapped, so if nothing is logged and it still dies, suspect
# a signal, not a set -e abort.)
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
                        change is suppressed (noise key / excluded domain) —
                        answers "why didn't my change appear?"
  -e, --exclude <glob>  Comma-separated glob patterns to exclude
  --hot-domains <list>  Comma-separated list of domains kept permanently active
                        for instant first-change detection. Default: the common
                        System Settings panels (Finder, Dock, Control Center,
                        keyboard/trackpad/mouse, Accessibility, Spotlight, …).
                        Pass "NONE" to disable.
  -h, --help            Show this help message
  --mdm                 MDM deployment mode: replace user home path with
                        \$loggedInUser variable in PlistBuddy commands
  --no-console          Don't open Console.app and don't stop when it closes;
                        run until Ctrl+C / SIGTERM (interactive / VM testing)

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
  When run via Jamf Pro, use positional parameters:
    $4 = Domain
    $5 = Log path
    $6 = INCLUDE_SYSTEM (true/false)
    $7 = ONLY_CMDS (true/false)
    $8 = EXCLUDE_DOMAINS
    $9 = MDM_OUTPUT (true/false)
    $10 = HOT_DOMAINS (comma-separated; "NONE" to disable)
    $11 = DEBUG (true/false) — log '# FILTERED: …' for suppressed changes

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
        # Diagnostic: log `# FILTERED: <dom> <key> (reason)` when a DETECTED
        # change is suppressed (noise key / excluded domain) — answers "why
        # didn't my change appear?". Not on by default. (General --debug flag;
        # more debug categories can hang off DEBUG_FILTER/new vars later.)
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
        # Don't open Console.app and don't tie the watcher lifecycle to it —
        # run until Ctrl+C / SIGTERM. Useful for interactive/VM testing in a
        # Terminal, where closing Console would otherwise stop monitoring.
        NO_CONSOLE_RAW="true"
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

# Make an emitted PlistBuddy path deployable fleet-wide (MDM mode only):
#  - user home       -> /Users/$loggedInUser/...
#  - ByHost filename -> ...<domain>.$UUID.plist
# A ByHost file is named after THIS Mac's hardware UUID, so a literal path is
# valid nowhere else. The caller emits a NOTE with the one-liner resolving $UUID.
# (`defaults -currentHost write` needs none of this — the flag resolves the UUID.)
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
# For a PlistBuddy VALUE the whole `-c '…'` expression is single-quoted, which
# would store the literal `$loggedInUser`. Break out of the quotes around it so
# the shell expands it: `…/Users/'$loggedInUser'/…`. _MDM_LIU is the bare token
# to find (post-escape); _MDM_LIU_QB is its quote-broken form.
typeset -g _MDM_LIU='$loggedInUser'
typeset -g _MDM_LIU_QB="'${_MDM_LIU}'"

# Disable shell trace so -v/--verbose only toggles our own logging.
unsetopt xtrace verbose 2>/dev/null || true

# ---------------------------------------
# CONFIGURATION — Hot domains
# ---------------------------------------

# "Hot" domains stay marked active so their first change is caught without the
# fs_usage→poll round-trip (cfprefsd can buffer writes for seconds; hot ones are
# flushed every cycle → ~1-2s). Override via --hot-domains / Jamf $10; "NONE" disables.
# Note: this is the OPPOSITE of an exclusion — hot domains are kept permanently
# active, not filtered out. Real exclusions live in DEFAULT_EXCLUSIONS below.
typeset -a HOT_DOMAINS=(
  # Shell / appearance
  com.apple.finder
  .GlobalPreferences
  com.apple.dock
  com.apple.controlcenter
  com.apple.WindowManager
  com.apple.systemuiserver                             # legacy menu-bar extras
  com.apple.menuextra.clock                            # menu-bar clock format (ShowAMPM/Date/DayOfWeek)
  # Input — keyboard / shortcuts / trackpad / mouse (all standard plists here, not ByHost)
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
# CONFIGURATION — Exclusions
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

  # Clock/Timer daemon: live timer *instances*, not preferences — fresh UUIDs
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
  # Note: com.apple.security* narrowed — catch only known noisy sub-domains,
  # not "com.apple.security.authorization" or similar which may have real prefs
  "com.apple.security.cloudkeychainproxy3*"  # glob: also covers .keysToRegister sidecar (sync queue)
  "com.apple.security.sosaccount"            # iCloud Keychain sync-circle state (SOSEnabled/ghostbustdate) — securityd-managed, not a defaults-settable pref
  "com.apple.filevault"                      # FileVault ByHost state ONLY (lastAnalyticsEvent dict, recoveryKeyCreatorUID/Invalid, lastEnabledProductVersion) — daemon-written after enabling; no reproducible pref. Real control is fdesetup → security_watch emits the FileVault NOTE
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
  # Note: com.apple.TimeMachine removed — contains real prefs (AutoBackup, ExcludedPaths)
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
  # Apple's analytics agent — sync timestamps / usage counters only (AppUsageSyncTime)
  "com.apple.analyticsagent"
  "com.apple.GenerativeFunctions*"

  # MetricKit daemon (per-app diagnostic bookkeeping, MX* keys touched on every
  # MetricKit query — Outlook, Teams, Edge, etc. trigger writes)
  "com.apple.metrickitd"

  # ML rate limiter (token bucket counters/timestamps for embedding processing)
  "TokenBucketRateLimiter"

  # Emoji search cache (auto-generated locale emoji lists)
  "com.apple.EmojiCache"

  # Calculator currency cache (auto-updated exchange rates)
  "com.apple.calculateframework"

  # Note: com.apple.SoftwareUpdate removed from exclusions — contains real prefs
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
  # loginwindow NOT excluded — system file holds real policies (GuestEnabled,
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

  # Address Book UI state (window geometry, selection)
  "com.apple.AddressBook"

  # Directory Utility app UI state (toolbar layout, last-browsed perHost node) —
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

  # iCloud account services (MobileMeAccounts): the Services array is positional,
  # so an emitted `Set :Accounts:0:Services:N:Enabled` targets a different service
  # on another machine/OS (indices shift once e.g. ImagePlayground appears in
  # Sequoia 15.2). PlistBuddy addresses arrays by index only, not by ServiceID —
  # so no portable command exists for these toggles.
  "MobileMeAccounts"

  # Find My device daemon (APS tokens, internal state)
  "com.apple.icloud.fmfd"

  # Telephony framework internals (camera/call state)
  "com.apple.TelephonyUtilities"

  # Apple TV & Music apps (column info, launch state, internal metadata)
  "com.apple.TV"
  "com.apple.Music"
  "com.apple.itunescloud"
  "com.apple.itunescloudd"
  # Media library daemon: only migration flags, persistent IDs, daemon-written
  # store capability flags and an update counter — no user prefs. (Capital AMP;
  # the com.apple.amp* glob is case-sensitive and misses it.)
  "com.apple.AMPLibraryAgent"

  # ShazamKit: CloudKit account cache, boot tasks and an access token only — no
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
  # Siri/Spotlight suggestions backend daemon — server-driven resource-download
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

  # Adobe Genuine Service (licensing/consent daemon — consent strings contain
  # French apostrophes that break PlistBuddy single-quote escaping anyway)
  "com.adobe.AdobeGenuineService"

  # Spotlight knowledge daemon (internal sync counters, timestamps)
  "com.apple.spotlightknowledged.pipeline"

  # Media sharing daemon (internal playlist/sharing state)
  "com.apple.amp.mediasharingd"

  # TeamViewer internals (AI nudge, license, version, UI phases)
  "com.teamviewer*"

  # IPv6 DHCP daemon (interface changes on device connect)
  "com.apple.dhcp6d"

  # QuickLook daemon (plugin modification timestamps)
  "com.apple.QuickLookDaemon"

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
  "com.apple.SpotlightKnowledge"   # zsh globs are case-sensitive — the real domain is CamelCase (hdbCutover.*.evaluationCount counters)
  "com.apple.amsengagementd"
  "com.apple.StatusKitAgent"
  "com.apple.Accessibility.Assets"
  "com.apple.AOSKit*"

  # Data sync daemons (CalDAV/CardDAV/Exchange account refresh states)
  "com.apple.dataaccess*"

  # Siri assistant daemon/backup churn (experiment IDs, trial configs, sync
  # counters, check dates, CloudKit cache). NOTE: com.apple.assistant.support is
  # deliberately NOT excluded — real Siri prefs live there (Assistant Enabled,
  # dictation settings, data-sharing opt-ins); a narrow list keeps .support visible.
  "com.apple.assistant"
  "com.apple.assistant.backedup"
  "com.apple.assistantd"

  # Tips, personalization & time sync (notification counters, ML internals, clock daemon)
  "com.apple.tipsd"
  "com.apple.proactive.PersonalizationPortrait*"
  "com.apple.chronod"
  "com.apple.studentd"
  "com.apple.configurationprofiles*"
  "com.apple.sharingd"
  "com.apple.controlcenter.displayablemenuextras*"
  "com.apple.NewDeviceOutreach"
  "com.apple.settings.storage*"
  "com.apple.StorageManagement*"
  "com.apple.MIDI*"
  "com.apple.corespotlightui"
  "com.apple.textunderstanding*"

  # Filtered per-key in is_noisy_key (not excluded) so real prefs survive:
  # dock, finder, Safari, systemsettings, Mail, Messages.
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
  p=$(printf '%s' "$p" | /usr/bin/sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
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
  # Try non-system python3 (Homebrew, pyenv, etc.) — safe to run without CLT
  _candidate="$(command -v python3)"
  if [ "$_candidate" != "/usr/bin/python3" ] && _python3_validate "$_candidate"; then
    : # validated via alternative python3
  fi
fi

# Temp directory + EXIT trap — covers every MAIN exit path (sub-shells
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
    # System-level pref: root-owned file under /Library/Preferences
    printf '%s' "/Library/Preferences/${domain}.plist"
  else
    # $TARGET_HOME: console user's home when root (Jamf), $HOME otherwise
    printf '%s' "$TARGET_HOME/Library/Preferences/${domain}.plist"
  fi
}

# Derive a "defaults" domain from a .plist path
domain_from_plist_path() {
  local p="$1" base dom
  base="$(/usr/bin/basename "$p")"
  dom="${base%.plist}"
  printf '%s\n' "$dom" | /usr/bin/sed -E 's/\.[0-9A-Fa-f-]{8,}$//' || printf '%s\n' "$dom"
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
    : > "$path" 2>/dev/null || true
  fi
  echo "$path"
}

# Interactive y/n prompt. Exit: 0 = yes, 1 = no, 2 = no channel / dialog timed out.
# Tries in order: stdin (TTY), /dev/tty (probed — a bare open can set -e-exit under
# Jamf Self Service), then an osascript dialog as the console user via launchctl
# asuser (5-min timeout → 2, so Jamf policies never hang).
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

  # GUI fallback — only when a real console user is logged in.
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
# To filter a noisy key:      add a pattern to is_noisy_key() — automatically applies
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
    # NOT table-view UI state — must precede the NSTableView* noise glob below
    NSTableViewDefaultSizeMode) return 1 ;;
    # Window positions & UI state (changes on every resize/move)
    NSWindow\ Frame*|NSNavPanel*|NSSplitView*|NSTableView*|NSStatusItem*|*ItemPreferredPositions*|*WindowBounds*|*WindowState*|*WindowFrame*|*WindowOriginFrame*|*PreferencesWindow*|*.column.*.width|*.column.*.width.*|*_frame|NSOSPLastRootDirectory|NSNavLastRootDirectory|recentlyPlayed*|*SidebarWidth*)
      return 0 ;;

    # App-controlled macOS menu item overrides (set by app, not user)
    NSDisabledCharacterPaletteMenuItem|NSFullScreenMenuItemEverywhere)
      return 0 ;;

    # NSToolbar Configuration <UUID> — a per-instance toolbar layout an app dumps
    # on first window open (e.g. Console). The UUID is regenerated per instance,
    # so the command isn't portable. NAMED configs (NSToolbar Configuration
    # Browser) ARE reproducible and are kept — the pattern requires a UUID
    # (8-4-4-4-12 hex) right after the name, which "Browser" etc. never match.
    NSToolbar\ Configuration\ [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f]*)
      return 0 ;;

    # Sparkle updater internals (auto-update framework state)
    # Note: SUSendProfileInfo kept — it's a user-toggleable opt-in for stats
    SUUpdateGroupIdentifier|SULastCheckTime|SUHasLaunchedBefore|SUSkippedVersion|SUUpdateRelaunchingMarker)
      return 0 ;;

    # Timestamps & dates (metadata, not preferences) - UNIVERSAL
    # Matches: lastRetryTimestamp, LastUpdate, last-seen, updateTimestamp, CKStartupTime, lastCheckTime, etc.
    *timestamp*|*Timestamp*|*TimeStamp*|*-timestamp|*LastUpdate*|*LastSeen*|*-last-seen|*-last-update|*-last-modified|*LastRetry*|*LastSync*|*lastRetry*|*lastSync*|*StartupTime*|*StartTime*|*CheckTime|lastCheckTime|*LastSuccess*|*lastSuccess*|*LastKnown*|*lastKnown*|*LastLoadedOn*|*lastProcessed*|*LastProcessed*|*LastBackup*|*lastBackup*|*lastAppUpdateCheck*|*LastAppUpdateCheck*|*last*Date|*Last*Date)
      return 0 ;;

    # bare *Date is too broad (masks ExpirationDate/StartDate); anchored *last*Date
    # above is safe — "last…Date" is always a timestamp (e.g. lastCoolOffDate).

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
    # Note: removed exact `flags` — too generic, apps can use it as a real pref
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

    # Note: `last-selection` is NOT global (too generic) — filtered domain-specific
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
    # Note: removed `uses` exact and `*donate*` — too generic, could mask real prefs
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
    # DDMPersistedStateKey, etc. — daemon-managed across many domains)
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
    # Note: *ViewOptionsFrame/Window only — keeps Finder StandardViewOptions etc.
    *ScrollPosition*|*scrollPosition*|*SelectedItem*|*ViewOptionsFrame*|*ViewOptionsWindow*)
      return 0 ;;

    # Playback & connection state (transient states across all apps)
    # Note: removed *ConnectionState* — too broad, could mask real connection prefs
    *PlaybackStatus*|*Playback*Status*|*lastNowPlayedTime*|*LastConnected*)
      return 0 ;;

    # Note: removed state|status|State|Status — too generic, apps may use these as real prefs
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

  # Note: removed ALL_CAPS regex — too broad, could mask real prefs like SHOW_HIDDEN_FILES, ENABLE_DEBUG
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
        workspace-*|mod-count|showAppExposeGestureEnabled|last-messagetrace-stamp|lastShowIndicatorTime|trash-full|recent-apps)
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
        # Keep: ShowPathbar, AppleShowAllFiles, FXPreferredViewStyle, etc.
      esac
      ;;

    # System Settings: Filter timestamps
    com.apple.systemsettings*)
      case "$keyname" in
        # Noisy: last seen timestamps, navigation state, indexing timestamps, extension state
        *-last-seen|*LastUpdate*|*NavigationState*|*update-state-indexing*|*.extension)
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

    # Control Center: Filter UI positioning state
    com.apple.controlcenter)
      case "$keyname" in
        # Noisy: status item visibility/position changes from UI interaction
        NSStatusItem*)
          return 0 ;;
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
        # hudNotifiedConstrast (sic): internal contrast-HUD state, not a setting —
        # value type even varies by machine (float here, bool elsewhere)
        History|com.apple.custommenu.apps|displaysLastCursorLocation|hudNotifiedConstrast) return 0 ;;
      esac
      ;;

    # GlobalPreferences: Filter Keyboard panel first-open artifacts
    .GlobalPreferences)
      case "$keyname" in
        KB_SpellingLanguage|KB_SpellingLanguageIsAutomatic) return 0 ;;
        # Time-zone picker breadcrumbs (Date & Time pane): the last-clicked city's
        # coords/name/country, its AppleMapID, the derived country code. NONE of
        # these SET the time zone — timezone_watch emits `systemsetup -settimezone`
        # (the reproducer); these are UI state, and AppleMapID/lat-long aren't portable.
        com.apple.TimeZonePref.*|com.apple.preferences.timezone.*|com.apple.AppleModemSettingTool.LastCountryCode) return 0 ;;
        # Keep: KB_DoubleQuoteOption, KB_SingleQuoteOption, NSUserQuotesArray (quote style)
      esac
      ;;

    # Spotlight: Filter UI state and counters
    # Siri: internal stash of the menu-bar icon visibility, set on disable and
    # deleted on enable — state preservation, not a pref (StatusMenuVisible is the
    # real one; VoiceTriggerUserEnabled stays too).
    com.apple.Siri)
      case "$keyname" in
        SiriPrefStashedStatusMenuVisible) return 0 ;;
      esac
      ;;

    # Siri setup wizard (macOS 27): which onboarding panes were last shown and at
    # what version (`lastShownCoordinatorVersion:Data Sharing`, `:Voice Selection`)
    # — bookkeeping the wizard writes as it runs, not a setting. The real opt-ins
    # it produces live in com.apple.assistant.support and are kept.
    com.apple.siri.setup)
      case "$keyname" in
        lastShownCoordinatorVersion*) return 0 ;;
      esac
      ;;

    # Assistant support: 'Offline Dictation Status' is per-locale model-download
    # status — Installed/High Quality/Continuous Listening/Emoji Recognition/…
    # flags the daemon writes when an offline dictation model downloads, keyed by
    # EVERY locale (en-US, fr-FR, zh-TW, …). NOT settings: `defaults write
    # …Installed true` fakes the flag, it doesn't install the model. The real
    # prefs (Assistant Enabled, Dictation Auto Punctuation Enabled) are top-level
    # siblings and stay visible (.support is deliberately not excluded).
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

    com.apple.Spotlight)
      case "$keyname" in
        # Noisy: usage counters, window state, timestamps, binary data
        engagementCount*|engagementDate*|useCount|startTime|showedFTE)
          return 0 ;;
        lastWindowPosition|lastVisibleScreenRect|userHasMovedWindow|windowHeight)
          return 0 ;;
        queryViewOptions|PasteboardHistoryVersion|PreferencesVersion|version)
          return 0 ;;
        NSStatusItem*|__NSEnable*|SSAction*|FTEReset*)
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
    # engagementCountForDate-com.apple.Spotlight — a usage tally, not a setting.
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

    # Print presets: Filter Fiery driver defaults & print metadata
    com.apple.print.custompresets*)
      case "$keyname" in
        # Keep: preset array (for emit_array_additions/deletions)
        com.apple.print.customPresetsInfo) ;;
        # Keep: preset identity
        PresetName|PresetBehavior|com.apple.print.preset.id|com.apple.print.preset.behavior) ;;
        # Keep: core print settings
        Duplex|*PageSize|*InputSlot|*MediaType|AP_ColorMatchingMode) ;;
        # Keep: useful Fiery settings
        *EFDuplex|*EFColorMode|*EFMediaType|*EFResolution|*EFSort|*EFNUpOption) ;;
        # Keep: Apple print settings
        com.apple.print.PrintSettings.PMDuplexing|com.apple.print.PrintSettings.PMColorSpaceModel) ;;
        com.apple.print.PageFormat.PMOrientation|com.apple.print.preset.Orientation) ;;
        # Filter: everything else (Fiery defaults, PPD metadata, transient data)
        *) return 0 ;;
      esac
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
        Scrutiny|CKBackgroundSettingsLastReportHour)
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
        # Hardware UUID / USB engine path / virtual-device name — won't transplant
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
      # Trend Micro ZTNA/SASE agent — mixes real config with agent state. Filter
      # the STATE: version numbers (all "0"), the per-device DeviceId (not
      # portable), transient/empty state and runtime validity flags. KEEP the
      # reproducible prefs (dontShowSignInPopupAgain, requireAuth*, separateAuth,
      # LoginURL/SwgServer/pacUrl, CompanyId, *IsEnable).
      case "$keyname" in
        *Version|DeviceId|connectorInfoList|systemExtensionExistFlag|swgIsInvalid|ztnaIsInvalid)
          return 0 ;;
      esac
      ;;

    # Battery charge limit: the only key here (`…prior.limit`) is UI state, not
    # the control — the real limit is SMC/powerd-managed and a `defaults write`
    # doesn't apply it. Filter the misleading command; _note_charge_limit emits
    # an explanatory NOTE instead.
    com.apple.batteryui.charging.mac)
      case "$keyname" in
        *prior.limit) return 0 ;;
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
  # is enabled — side-effect of the toggle. Keep them when they carry a value.
  case "$cmd" in
    *com.apple.RemoteDesktop*'"Text'[1-4]'" -string ""')
      return 0
      ;;
  esac

  return 1
}

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
        # axTextSize (ax-prefixed) is the accessibility-derived per-view text
        # size — the Finder recomputes it in every view dict from the chosen
        # `universalaccess FontSizeCategory`. It is never set from the Finder UI
        # (Cmd+J uses textSize/iconSize/FontSize, which stay real), so one
        # Accessibility text-size change would otherwise flood ~18 Set lines.
        # The FontSizeCategory command reproduces the change; this is derived.
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
      # 'deletedUsers' is a bookkeeping record of removed accounts — replaying
      # the Add commands just creates a phantom entry, it does NOT delete a
      # user. useracct_watch reports the real add/remove via a NOTE instead.
      case "$pb_cmd" in
        *":deletedUsers"*) return 0 ;;
      esac
      ;;
    preferences)
      # Hostnames in the configd-managed SystemConfiguration/preferences.plist:
      # LocalHostName/HostName (:System:Network:HostNames:) + ComputerName and
      # ComputerNameEncoding (:System:System:ComputerName*). A raw PlistBuddy Set
      # is unreliable; hostname_watch emits the documented `scutil --set` instead.
      case "$pb_cmd" in
        *":System:Network:HostNames:"*|*":System:System:ComputerName"*) return 0 ;;
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
        *":ReferenceLocalSnapshotDate "*|*":attemptDate "*|\
        *":backupOfVolumeUUIDs"*)
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
      # Noisy: Character Palette (Emoji viewer) add/remove on open/close
      case "$pb_cmd" in
        *"CharacterPaletteIM"*)
          return 0 ;;
      esac
      ;;
    com.apple.MobileSMS)
      # Noisy: Scrutiny analytics (contact tracking, timestamps)
      case "$pb_cmd" in
        *":Scrutiny:"*|*":Scrutiny "*)
          return 0 ;;
      esac
      ;;
    com.apple.iPod)
      # Per-device sync bookkeeping nested under Devices:<hex-id>: — the Connected
      # timestamp and Use Count counter, rewritten on every connect. is_noisy_key
      # filters the TOP-LEVEL Connected/Use Count, but these arrive nested so they
      # only match here as sub-paths.
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

# Core log function — all log_* wrappers delegate here
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
      if [ -n "$_cmd_dom" ] && is_excluded_domain "$_cmd_dom"; then
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
    if [ -n "$_cmd_dom" ] && is_excluded_domain "$_cmd_dom"; then
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

# Snapshot log — verbose: all lines, ONLY_CMDS: start/complete only
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
  # Try plutil first (fastest)
  # Note: plutil -convert with -o writes output to file, error messages go to stdout (not stderr)
  # so we must suppress both stdout and stderr to avoid visible errors on Sonoma
  if /usr/bin/plutil -convert json -o "$out" "$src" >/dev/null 2>&1; then
    [ -s "$out" ] && return
  fi
  # Fallback: Python plistlib (handles binary data like NSData in Dock plist)
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

# Convert a defaults delete command to PlistBuddy
convert_delete_to_plistbuddy() {
  local cmd="$1"

  local domain target
  domain=$(printf '%s' "$cmd" | /usr/bin/sed -nE 's/.*defaults([[:space:]]+-[^[:space:]]+)*[[:space:]]+delete[[:space:]]+([^[:space:]]+).*/\2/p')
  target=$(printf '%s' "$cmd" | /usr/bin/sed -nE 's/.*delete[[:space:]]+[^[:space:]]+[[:space:]]+"([^"]+)".*/\1/p')
  [ -z "$target" ] && target=$(printf '%s' "$cmd" | /usr/bin/sed -nE 's/.*delete[[:space:]]+[^[:space:]]+[[:space:]]+([^[:space:]]+).*/\1/p')

  [ -n "$domain" ] || return 1
  [ -n "$target" ] || return 1

  local plist_path
  plist_path="$(get_plist_path "$domain")"

  local is_array_deletion=false
  if [[ "$target" =~ ':[^:]+:[0-9]+$' ]]; then
    is_array_deletion=true
  fi

  if [ "$is_array_deletion" = "true" ]; then
    # WARNING is deduped by the caller (parent scope) — this function runs in a
    # $() subshell so setting the flag here would be lost.
    printf '# WARNING: Array deletion - indexes shift after each delete; if removing several, run the commands in the order shown (do not reorder)\n'
  fi
  local _mdm_path=$(mdm_plist_path "$plist_path")
  # Escape single quotes in the key path so a key containing ' doesn't break the
  # single-quoted PlistBuddy -c 'Delete …' expression (each ' → '\'').
  local _target_esc
  _target_esc=$(printf '%s' "$target" | /usr/bin/sed "s/'/'\\\\''/g")
  printf '/usr/libexec/PlistBuddy -c '\''Delete %s'\'' "%s"\n' "$_target_esc" "$_mdm_path"
  return 0
}

# ---------------------------------------
# Command Emission
# ---------------------------------------
# Builds the `defaults`/PlistBuddy commands and routes them through the
# filters/logging — the bridge between the diff engine and the log output.

# Escape a value for safe embedding inside a double-quoted shell string in an
# emitted command: backslash, double-quote, $ and backtick — else a pref value
# containing `$(…)`, `$VAR` or backticks would execute/expand when the logged
# command is copy-pasted and run.
_escape_dq() { printf '%s' "$1" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g; s/`/\\`/g'; }

# Build `defaults write …` for dom/keyname/trimmed via type cascade.
# Stdout = command, or empty for array/dict (not flat-writable).
# Args: dom keyname trimmed hostflag plist_path
_build_defaults_write_cmd() {
  local dom="$1" keyname="$2" trimmed="$3" hostflag="$4" plist_path="$5"
  local actual_type="" type_val noquotes str cmd=""
  local plutil_result plutil_type plutil_value

  # System-level pref: emit (and type-probe) the root-owned /Library/Preferences
  # file by full path — `defaults` accepts a path in place of a bare domain and
  # appends .plist. A bare domain would replay into the console user's ~ copy.
  [ "${_EMIT_SYS:-false}" = "true" ] && [[ "$dom" != /* ]] && dom="/Library/Preferences/${dom}"

  # Probe the type as the CONSOLE USER for user domains. In ALL mode prefwatch runs
  # as root, where a bare `defaults read-type com.apple.dock …` reads ROOT's domain
  # and fails ("Domain not found") — the empty probe then fell through to the 0/1
  # heuristic below and emitted `-bool FALSE` for what is really `-int 0` (proven on
  # wvous-tr-modifier). System prefs are a /Library/Preferences PATH: keep them root-read.
  if [ "${_EMIT_SYS:-false}" = "true" ]; then
    actual_type=$(/usr/bin/defaults ${hostflag:+$hostflag }read-type "$dom" "$keyname" 2>/dev/null | /usr/bin/awk '{print $NF}') || actual_type=""
  else
    actual_type=$("${RUN_AS_USER[@]}" /usr/bin/defaults ${hostflag:+$hostflag }read-type "$dom" "$keyname" 2>/dev/null | /usr/bin/awk '{print $NF}') || actual_type=""
  fi

  if [ "$actual_type" = "float" ]; then
    cmd="defaults ${hostflag:+$hostflag }write ${dom} \"${keyname}\" -float ${trimmed}"
  elif [ "$actual_type" = "integer" ]; then
    cmd="defaults ${hostflag:+$hostflag }write ${dom} \"${keyname}\" -int ${trimmed}"
  elif [ "$actual_type" = "boolean" ]; then
    type_val=$( [ "$trimmed" = "1" ] || [ "$trimmed" = "true" ] && echo TRUE || echo FALSE )
    cmd="defaults ${hostflag:+$hostflag }write ${dom} \"${keyname}\" -bool ${type_val}"
  elif [[ "$trimmed" =~ ^\".*\"$ ]]; then
    noquotes="${trimmed#\"}"; noquotes="${noquotes%\"}"
    str=$(_escape_dq "$noquotes")
    cmd="defaults ${hostflag:+$hostflag }write ${dom} \"${keyname}\" -string \"${str}\""
  elif [[ "$trimmed" == "true" ]] || [[ "$trimmed" == "false" ]]; then
    type_val=$(printf '%s' "$trimmed" | /usr/bin/tr '[:lower:]' '[:upper:]')
    cmd="defaults ${hostflag:+$hostflag }write ${dom} \"${keyname}\" -bool ${type_val}"
  elif [[ "$trimmed" == "0" ]] || [[ "$trimmed" == "1" ]]; then
    type_val=$( [ "$trimmed" = "1" ] && echo TRUE || echo FALSE )
    cmd="defaults ${hostflag:+$hostflag }write ${dom} \"${keyname}\" -bool ${type_val}"
  elif [[ "$trimmed" =~ ^-?[0-9]+$ ]]; then
    cmd="defaults ${hostflag:+$hostflag }write ${dom} \"${keyname}\" -int ${trimmed}"
  elif [[ "$trimmed" =~ ^-?[0-9]*\.[0-9]+$ ]]; then
    cmd="defaults ${hostflag:+$hostflag }write ${dom} \"${keyname}\" -float ${trimmed}"
  else
    if [ -f "$plist_path" ] && plutil_result=$(extract_type_value_with_plutil "$plist_path" "$keyname" 2>/dev/null); then
      plutil_type="${plutil_result%%|*}"
      plutil_value="${plutil_result#*|}"
      case "$plutil_type" in
        string) cmd="defaults ${hostflag:+$hostflag }write ${dom} \"${keyname}\" -string \"$(_escape_dq "$plutil_value")\"" ;;
        bool)   cmd="defaults ${hostflag:+$hostflag }write ${dom} \"${keyname}\" -bool ${plutil_value}" ;;
        int)    cmd="defaults ${hostflag:+$hostflag }write ${dom} \"${keyname}\" -int ${plutil_value}" ;;
        float)  cmd="defaults ${hostflag:+$hostflag }write ${dom} \"${keyname}\" -float ${plutil_value}" ;;
        array|dict) cmd="" ;;
        *) cmd="defaults ${hostflag:+$hostflag }write ${dom} \"${keyname}\" <type> <value>" ;;
      esac
    else
      cmd="defaults ${hostflag:+$hostflag }write ${dom} \"${keyname}\" <type> <value>"
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
  if [ -n "$hostflag" ]; then
    printf 'defaults %s delete %s "%s"' "$hostflag" "$dom" "$target"
  else
    printf 'defaults delete %s "%s"' "$dom" "$target"
  fi
}

# Internal: route a log line through the right wrapper by kind.
_log_kind() {
  case "$1" in
    USER)   log_user   "$2" ;;
    SYSTEM) log_system "$2" ;;
    *)      log_line   "$2" ;;
  esac
}

# One-per-burst NOTE when the current diff targets a system-level pref: the
# emitted defaults/PlistBuddy commands write a root-owned /Library/Preferences
# file and must be replayed as root.
_maybe_sys_note() {
  [ "${_EMIT_SYS:-false}" = "true" ] || return 0
  _note_should_show __sys_root__ || return 0
  # "Cmd: " prefix required so the note survives ONLY_CMDS (Jamf) filtering.
  _log_kind "$1" "Cmd: # NOTE: system-level pref (/Library/Preferences) — replay these commands as root (sudo)"
}

# One-per-burst NOTE when an emitted path was templatized to $UUID (MDM mode,
# ByHost file — see mdm_plist_path). Without the resolver $UUID is undefined and
# the command would target a broken path, so this NOTE is not optional.
# One-per-burst NOTE for a ColorSync command that targets a monitor by its CoreGraphics
# UUID (`Device.mntr.<UUID>`). That UUID differs per display AND per Mac (proven: two
# identical monitors → different UUIDs); it's the TARGET's display and unknown when
# authoring, so mdm_plist_path can't templatize it — the NOTE points at the runtime
# `defaults -currentHost read` lookup instead. SCOPED to `Device.mntr.` on purpose: a bare "any UUID in the key" match
# also fired on `NSToolbar Configuration <UUID>` (a toolbar-config id, already covered by
# its own NOTE) and on account UUIDs, where the display-resolution advice is just wrong.
_note_device_uuid() {
  local kind="$1" key="$2"
  [[ "$key" == *"Device.mntr."[0-9A-Fa-f]* ]] || return 0
  _note_should_show __device_uuid__ || return 0
  _log_kind "$kind" "Cmd: # NOTE: the Device.mntr.<UUID> is the DISPLAY's own UUID (per-monitor), not the Mac's —"
  _log_kind "$kind" "Cmd: #       --mdm can't templatize it. On the target, list displays and pick the one you set:"
  _log_kind "$kind" "Cmd: #       defaults -currentHost read -g com.apple.ColorSync.Devices"
}

_note_byhost_uuid() {
  local kind="$1" path="$2" key="${3:-}"
  # A Device.mntr.<UUID> key carries the DISPLAY's own UUID that --mdm can't
  # templatize — _note_device_uuid says exactly that, and this note's "re-run with
  # --mdm for a deployable form" would contradict it. Let the device note own it.
  [[ "$key" == *"Device.mntr."[0-9A-Fa-f]* ]] && return 0
  case "$path" in
    # MDM mode: the path is templatized to $UUID + $loggedInUser, whose resolvers are
    # emitted ONCE at startup (see MAIN) — so a templatized ByHost path adds nothing here.
    # (Return early so it doesn't fall through to the non-mdm */ByHost/* note below.)
    *'$UUID'*)
      return 0
      ;;
    # Normal mode: the literal UUID is correct for replay HERE, and useless
    # anywhere else — say so, and point at the flag that makes it deployable.
    */ByHost/*)
      _note_should_show __byhost_uuid__ || return 0
      _log_kind "$kind" "Cmd: # NOTE: this ByHost filename holds THIS Mac's hardware UUID — the path is valid on this Mac only; re-run with --mdm for a deployable form"
      ;;
  esac
}

# --debug: log a diagnostic when a DETECTED change is dropped by a filter,
# so "why didn't my change appear?" has an answer. Silent unless --debug.
_dbg_filtered() { [ "${DEBUG_FILTER:-false}" = "true" ] && log_line "Cmd: # FILTERED: $1"; return 0; }  # ALWAYS return 0: called standalone in then-blocks under set -e, so a non-zero (debug OFF → the [ ] fails, && short-circuits) would ABORT the shell

# Emit a built defaults cmd via _log_kind, applying filters/NOTE/gate.
# Deletes go through convert_delete_to_plistbuddy.
# Args: kind cmd note_dom is_delete
_emit_cmd() {
  local kind="$1" cmd="$2" note_dom="$3" is_delete="$4"

  [ -n "$cmd" ] || return 0
  if is_noisy_command "$cmd"; then _dbg_filtered "${note_dom:-?} (noise/invalid command)"; return 0; fi

  if [ "$is_delete" != "true" ]; then
    local _cmd_dom
    _cmd_dom=$(printf '%s' "$cmd" | /usr/bin/sed -nE 's/.*defaults([[:space:]]+-[^[:space:]]+)*[[:space:]]+write[[:space:]]+([^[:space:]]+).*/\2/p')
    if [ -n "$_cmd_dom" ] && is_excluded_domain "$_cmd_dom"; then _dbg_filtered "$_cmd_dom (excluded-domain)"; return 0; fi
    _emit_contextual_note "$note_dom" ""
  fi

  # ALL_MODE+ONLY_CMDS skips DOMAIN output (covered by per-plist diff).
  if [ "$kind" = "DOMAIN" ] && [ "${ALL_MODE:-false}" = "true" ] && [ "${ONLY_CMDS:-false}" = "true" ]; then
    return 0
  fi

  _maybe_sys_note "$kind"

  if [ "$is_delete" = "true" ]; then
    local pb_delete pb_line
    if pb_delete=$(convert_delete_to_plistbuddy "$cmd" 2>/dev/null); then
      while IFS= read -r pb_line; do
        [ -n "$pb_line" ] || continue
        case "$pb_line" in
          # "Cmd: " prefix on comment lines too, else ONLY_CMDS (Jamf) drops them.
          "# WARNING: Array deletion"*)
            _note_should_show __array_del_warning__ && _log_kind "$kind" "Cmd: $pb_line" ;;
          "#"*) _log_kind "$kind" "Cmd: $pb_line" ;;
          *)    _note_byhost_uuid "$kind" "$pb_line" "${${pb_line#*-c \'}%%\'*}"
                # Key expression only — strip the trailing file path, whose ByHost
                # UUID is the Mac's and is a different concern.
                _note_device_uuid "$kind" "${${pb_line#*-c \'}%%\'*}"
                _log_kind "$kind" "Cmd: $pb_line" ;;
        esac
      done <<< "$pb_delete"
    else
      _log_kind "$kind" "Cmd: $cmd"
    fi
  else
    # MDM: templatize a user-home path embedded in a string VALUE the same way
    # (mdm_plist_path only touches the plist file path, not values like a path pref).
    if [ "$MDM_OUTPUT" = "true" ] && [[ "$cmd" == *"$TARGET_HOME"* ]]; then
      cmd="${cmd//"$TARGET_HOME"/$_MDM_HOME_REPL}"
    fi
    _log_kind "$kind" "Cmd: $cmd"
  fi
}

# Consume the tab-separated stream from emit_array_additions +
# emit_nested_dict_changes. PBCMD lines → PlistBuddy emit via _log_kind;
# metadata lines → populate global _SKIP_KEYS. Empty plist_path skips
# PBCMDs but still populates _SKIP_KEYS.
# Args: kind dom meta_raw plist_path
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
      if is_noisy_pbcmd "$dom" "$_pb_cmd"; then _dbg_filtered "$dom — $_pb_cmd (noise-key)"; continue; fi
      if [ "$_domain_note_emitted" = "false" ]; then
        _emit_contextual_note "$dom" "$_last_array_base"
        _domain_note_emitted=true
      fi
      _maybe_sys_note "$kind"
      if (( ${#_pending_comments[@]} > 0 )); then
        for _pc in "${_pending_comments[@]}"; do
          # Precede a dockutil info comment with the "it's an ALTERNATIVE" NOTE.
          [[ "$_pc" == "# dockutil"* ]] && _note_dockutil_alt "$kind"
          _log_kind "$kind" "Cmd: $_pc"
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
      # Escape single quotes in the PBCMD so a value/key containing ' doesn't
      # break the single-quoted PlistBuddy -c '…' wrapper (each ' → '\'').
      _pb_esc=$(printf '%s' "$_pb_cmd" | /usr/bin/sed "s/'/'\\\\''/g")
      # …then break out of those single quotes around the templatized $loggedInUser
      # so the shell actually expands it at run time (single quotes would keep it literal).
      [ "$_mdm_home_hit" = true ] && _pb_esc="${_pb_esc//"$_MDM_LIU"/$_MDM_LIU_QB}"
      pb_full="/usr/libexec/PlistBuddy -c '${_pb_esc}' \"${_mdm_path}\""
      _log_kind "$kind" "Cmd: $pb_full"
      continue
    fi
    # Metadata line — populate _SKIP_KEYS at every level the Python
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
        _k=$(printf '%s' "$_k" | /usr/bin/sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
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
}

# Walk the unified diff(prev,curr) and emit write/delete via _emit_cmd
# for each key not pre-handled by _SKIP_KEYS / is_noisy_key. type_src is
# the plist used by _build_defaults_write_cmd for plutil-fallback;
# diff_label tags the "Diff <label>:" log lines.
# Args: kind dom hostflag prev curr type_src diff_label
# Reads: _SKIP_KEYS, _HAS_ARRAY_ADDITIONS.
_process_diff_lines() {
  local kind="$1" dom="$2" hostflag="$3" prev="$4" curr="$5" type_src="$6" diff_label="$7"
  [ -s "$prev" ] || return 0

  typeset -A _added_keys
  _added_keys=()
  local _aline _ak
  while IFS= read -r _aline; do
    _ak=$(printf '%s' "$_aline" | /usr/bin/sed -nE 's/^\+[[:space:]]*"([^"]+)".*/\1/p')
    [ -n "$_ak" ] && _added_keys["$_ak"]=1
  done < <(/usr/bin/diff -u "$prev" "$curr" 2>/dev/null | /usr/bin/awk 'NR>2 && $0 ~ /^\+/ && $0 !~ /^\+\+\+/' || true)  # diff exits 1 when files differ (always, here) → pipefail fires ZERR/set -e; guard it

  local dline kv keyname val snippet pretty_key array_meta array_name array_idx trimmed cmd delete_cmd
  while IFS= read -r dline; do
    [ -n "$dline" ] || continue

    _log_kind "$kind" "Diff $diff_label: $dline"

    array_meta="" array_name="" array_idx=""
    kv=$(printf '%s' "$dline" | /usr/bin/sed -nE 's/^[+-][[:space:]]*"([^"]+)"[[:space:]]*=>[[:space:]]*(.*)$/\1|\2/p')
    [ -n "$kv" ] || continue

    keyname="${kv%%|*}"
    val="${kv#*|}"

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

    snippet=$(printf '%s' "$val" | /usr/bin/tr '\n' ' ' | /usr/bin/awk '{s=$0; if(length(s)>160) {print substr(s,1,157) "..."} else {print s}}')
    _log_kind "$kind" "Key: ${pretty_key} | Item: ${snippet}"

    case "$dline" in
      +*)
        [ -n "$array_name" ] && continue
        [[ "$dline" =~ ^[+][[:space:]]{4,}\" ]] && continue
        trimmed=$(printf '%s' "$val" | /usr/bin/sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
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
        _emit_cmd "$kind" "$delete_cmd" "$dom" true
        ;;
    esac
  done < <(/usr/bin/diff -u "$prev" "$curr" 2>/dev/null | /usr/bin/awk 'NR>2 && ($0 ~ /^\+/ || $0 ~ /^-/) && $0 !~ /^\+\+\+|^---/' || true)  # diff exits 1 when files differ (always, here) → pipefail fires ZERR/set -e; guard it
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
  py_output=$("$PYTHON3_BIN" - "$dom" "$prev_json" "$curr_json" <<'PY'
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

results = []

# Keys with volatile metadata that changes on every plist rewrite (timestamps, internal IDs)
# Must be stripped before comparing array elements to avoid phantom add/delete
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
                    cmds.append("PBCMD\t# NOTE: an empty-string key ('') was skipped — PlistBuddy can't address it")
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
    # Skip reorders: if array length is the same, elements just moved (not added)
    arr_name = prefix[0]
    if arr_name in prev and arr_name in curr and isinstance(prev[arr_name], list) and isinstance(curr[arr_name], list) and len(prev[arr_name]) == len(curr[arr_name]):
        continue
    # New top-level arrays handled entirely by emit_nested_dict_changes (with NOTE)
    if arr_name not in prev:
        continue
    # Adding to an EXISTING array: the index is positional. Warn once — a target
    # whose array has a different length won't get the element at the same spot.
    if not _array_add_noted:
        print("PBCMD\t# NOTE: array element added at positional index :N — PlistBuddy addresses by position, not content; may land wrong if the target's array differs")
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
                # dockutil equivalent (INFO comment only — the PlistBuddy Add
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

# Per-burst notice dedup: _NOTED_DOMAIN[key] holds the LAST-EMIT epoch time for a
# contextual NOTE / array-deletion WARNING. A notice re-appears only after a quiet
# gap of _NOTE_BURST_GAP seconds — so a rapid burst of changes shows it once, but a
# later change re-shows it (context isn't lost). Not once/session, not every change.
typeset -gA _NOTED_DOMAIN=()
typeset -g _NOTE_BURST_GAP=15   # seconds of quiet between bursts; tune to taste

# Sliding-window per-burst dedup: return 0 to SHOW the notice keyed by $1, 1 to
# suppress. The timestamp updates on EVERY call, so the notice re-shows only after
# _NOTE_BURST_GAP seconds of QUIET — not that long since it was last shown, which
# would let it re-fire mid-burst.
_note_should_show() {
  local _last=${_NOTED_DOMAIN[$1]:-0}
  _NOTED_DOMAIN[$1]=$EPOCHSECONDS
  (( EPOCHSECONDS - _last < _NOTE_BURST_GAP )) && return 1
  return 0
}

# One-per-burst NOTE emitted right before a `# dockutil …` info comment (Dock
# add/remove). The dockutil line and the PlistBuddy commands do the SAME thing —
# without this, an admin who copies the whole block would run BOTH (double-add,
# or fail because dockutil isn't installed). Says: pick one, and dockutil needs
# installing. Burst-deduped so a multi-app change shows it once.
_note_dockutil_alt() {
  _note_should_show __dockutil_alt__ || return 0
  _log_kind "$1" "Cmd: # NOTE: 'dockutil' is a deploy-friendly ALTERNATIVE to the PlistBuddy command(s) here — run ONE or the other, not both (needs dockutil installed: github.com/kcrawford/dockutil)"
}

# Emit contextual notes for domains that need extra steps
_emit_contextual_note() {
  local dom="$1" array_base="$2" _note=""
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
    com.apple.print.custompresets*)
      case "$array_base" in
        com.apple.print.customPresetsInfo)
          _note="Print preset changes require logout/login to take effect" ;;
      esac ;;
    com.apple.symbolichotkeys)
      _note="Keyboard shortcut changes require logout/login to take effect"
      case "$array_base" in
        AppleSymbolicHotKeys) _note="macOS rewrites shortcut parameters on first enable/disable toggle — values shown may reflect existing bindings, not new assignments" ;;
      esac ;;
    com.apple.finder)
      _note="Finder prefs apply on a new window or after 'killall Finder'; icon/list View Options (Cmd+J) need 'Use as Defaults' to be detectable"
      case "$array_base" in
        PreviewPaneSettings) _note="First opening Finder Preview pane options writes the full attribute list — only subsequent toggles reflect actual modifications" ;;
        StandardViewSettings) _note="First 'Use as Defaults' on a Finder view writes the entire view-settings structure (every column) — only subsequent toggles reflect actual changes" ;;
      esac ;;
    com.apple.WindowManager)
      _note="First opening Desktop & Dock settings writes all defaults — only subsequent changes reflect actual modifications" ;;
    com.apple.universalaccess)
      _note="First opening Accessibility settings writes all defaults — only subsequent changes reflect actual modifications" ;;
    com.apple.prodisplaylibrary)
      _note="'defaults write' alone does not apply display presets — alternative third-party tools exist" ;;
  esac
  # Match on array_base for cross-domain keys (e.g. ColorSync in ByHost GlobalPreferences)
  case "$array_base" in
    com.apple.ColorSync.Devices)
      _note="Color profile changes require logout/login to take effect" ;;
    # AppKit toolbar config, written by any app: the first window open dumps the
    # whole item list. NOT filtered — a customized toolbar IS a real preference
    # (deliberately un-filtered in an earlier version) — so annotate instead.
    # Both spellings: metadata reports the top-level key or the nested array name.
    NSToolbar\ Configuration*|TB\ Item\ Identifiers*)
      _note="First opening this window writes the full toolbar layout — only subsequent changes are real customizations; 'TB Is Shown' can also be rewritten by the app itself on window open/close" ;;
  esac
  [ -n "$_note" ] || return 0
  # Dedup per burst (sliding window): show once, re-show only after quiet
  _note_should_show "${dom}:${_note}" || return 0
  log_line "Cmd: # NOTE: $_note"
}

# Raw Python runner for array deletions — prints py_output to stdout so the
# caller can prefetch it in parallel before emit_array_deletions consumes it.
_py_deletions_raw() {
  local dom="$1" prev_json="$2" curr_json="$3"
  [ -n "$PYTHON3_BIN" ] || return 0
  [ -s "$curr_json" ] || return 0
  [ -s "$prev_json" ] || return 0
  "$PYTHON3_BIN" - "$dom" "$prev_json" "$curr_json" <<'PY'
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

results = []

# Keys with volatile metadata that changes on every plist rewrite (timestamps, internal IDs)
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
    print(f"{array_name}\t{index}\t{keys}\t{app_label}")
PY
}

# Detect and emit commands for array deletions
emit_array_deletions() {
  local kind="$1" dom="$2" prev_json="$3" curr_json="$4" precomputed="${5:-}"
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
  while IFS=$'\t' read -r base idx keylist app_label; do
    [ -n "$base" ] || continue

    # Skip noisy arrays
    if is_noisy_key "$dom" "$base"; then _dbg_filtered "$dom $base (noise-array)"; continue; fi

    # Emit contextual note once per array
    if [ -z "${_noted_del_arrays[$base]:-}" ]; then
      _emit_contextual_note "$dom" "$base"
      _noted_del_arrays[$base]=1
    fi

    # Dock: emit app name comment for readability, plus the dockutil INFO
    # comment (--remove by label is more robust than deleting by positional
    # index, which shifts as the array changes; the PlistBuddy Delete below
    # still reproduces it on its own).
    if [ -n "$app_label" ]; then
      _log_kind "$kind" "Cmd: # Dock: removed $app_label"
      _note_dockutil_alt "$kind"
      _log_kind "$kind" "Cmd: # dockutil --remove '$app_label'"
    fi

    local delete_cmd="defaults delete ${dom} \":${base}:${idx}\""

    if is_noisy_command "$delete_cmd"; then
      :
    elif [ "$kind" = "DOMAIN" ] && [ "${ALL_MODE:-false}" = "true" ] && [ "${ONLY_CMDS:-false}" = "true" ]; then
      :
    else
      local pb_delete=""  # init: re-`local` in this read-loop would print `pb_delete=…`
      if pb_delete=$(convert_delete_to_plistbuddy "$delete_cmd" 2>/dev/null); then
        while IFS= read -r pb_line; do
          [ -n "$pb_line" ] || continue
          case "$pb_line" in
            "# WARNING: Array deletion"*)
              _note_should_show __array_del_warning__ || continue ;;
          esac
          _log_kind "$kind" "Cmd: $pb_line"
        done <<< "$pb_delete"
      else
        _log_kind "$kind" "Cmd: $delete_cmd"
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
  py_output=$("$PYTHON3_BIN" - "$dom" "$prev_json" "$curr_json" <<'PY'
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

# Keys with volatile metadata that changes on every plist rewrite (timestamps, internal IDs)
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
        # Removed elements (array shrank) — delete highest index first
        for i in reversed(range(len(curr_obj), len(prev_obj))):
            deletions.append((path_parts + [str(i)],))
    else:
        # Leaf value changed (or type changed)
        tv = pb_type_value(curr_obj)
        if tv:
            changes.append((path_parts, tv))
    return changes, additions, deletions

# An empty-string key ('') makes the ':'.join path a bare '::', which PlistBuddy
# collapses — the value lands one level too high (verified by round-trip). No CLI
# addresses it, so skip the whole subtree from that key down and note it once.
_empty_key_noted = [False]
def _note_empty_key():
    if not _empty_key_noted[0]:
        print("PBCMD\t# NOTE: a key path has an empty-string key ('') — PlistBuddy can't address it, so that subtree is skipped (not reproducible)")
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

# Print preset: whitelist for com.apple.print.preset.settings keys
_PRINT_PRESET_KEEP = {
    'Duplex', 'AP_ColorMatchingMode',
}
_PRINT_PRESET_PREFIXES = (
    '*PageSize', '*InputSlot', '*MediaType',
    '*EFDuplex', '*EFColorMode', '*EFMediaType', '*EFResolution', '*EFSort', '*EFNUpOption',
    'com.apple.print.PrintSettings.', 'com.apple.print.PageFormat.',
    'com.apple.print.preset.displayName', 'com.apple.print.PageToPaperMapping',
    'com.apple.print.pageRange',
)

def filter_print_preset_settings(settings_dict):
    """Filter a print preset settings dict to keep only useful keys."""
    if not isinstance(settings_dict, dict):
        return settings_dict
    filtered = {}
    for k, v in settings_dict.items():
        if k in _PRINT_PRESET_KEEP:
            filtered[k] = v
        elif any(k.startswith(p) for p in _PRINT_PRESET_PREFIXES):
            filtered[k] = v
    return filtered

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
            print("PBCMD\t# NOTE: new key tree — the Add commands build it top-down; later changes to it emit Set.")
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
            # Same-length array: suppress positional Set diffs for elements that
            # merely moved (same content, different index) — reordering an
            # order-insensitive list (e.g. Spotlight EnabledPreferenceRules) must
            # not emit per-index Sets. strip_volatile ignores metadata that
            # changes on every plist rewrite.
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
            if settings_key not in _PRINT_PRESET_KEEP and not any(settings_key.startswith(p) for p in _PRINT_PRESET_PREFIXES):
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

# Run the 3 Python diff workers in parallel, fold their output into the
# global _SKIP_KEYS / _HAS_ARRAY_ADDITIONS, and emit array deletions.
# Shared by show_plist_diff and show_domain_diff. Canonical emission order:
# additions/sets (via _process_py_meta) THEN deletions.
# Args: kind dom prev_json curr_json pb_plist_path key
# Reads/writes the globals _HAS_ARRAY_ADDITIONS and _SKIP_KEYS — do NOT
# declare those local here.
_run_py_diff_workers() {
  local kind="$1" dom="$2" prev_json="$3" curr_json="$4" pb_plist_path="$5" key="$6"
  local _py_add="$CACHE_DIR/${key}.py.add" _py_del="$CACHE_DIR/${key}.py.del" _py_nest="$CACHE_DIR/${key}.py.nest"
  emit_array_additions "$kind" "$dom" "$prev_json" "$curr_json" > "$_py_add" 2>/dev/null &
  _py_deletions_raw "$dom" "$prev_json" "$curr_json" > "$_py_del" 2>/dev/null &
  emit_nested_dict_changes "$kind" "$dom" "$prev_json" "$curr_json" > "$_py_nest" 2>/dev/null &
  wait
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
  emit_array_deletions "$kind" "$dom" "$prev_json" "$curr_json" "$_py_del"
  /bin/rm -f "$_py_add" "$_py_del" "$_py_nest" 2>/dev/null || true
}

# Menu bar item positions (`NSStatusItem Preferred Position <Item>`) are pixel offsets,
# each app storing its own in its OWN domain. They are filtered as UI churn, so a
# Cmd+drag reorder otherwise emits nothing — surface a NOTE.
# Fires only on a VALUE change of an existing key: a key added/removed means an item was
# shown/hidden, whose real command (the Control Center module value) is already emitted.
# A display connect/disconnect can recompute the offsets too (seen once), but not
# reliably — so the NOTE never claims a reorder, only that positions changed.
_note_menubar_positions() {
  local kind="$1" prev="$2" curr="$3" dom="${4:-}" _k _pat
  [ -s "$prev" ] && [ -s "$curr" ] || return 0
  # Old form: every app stores its own `NSStatusItem Preferred Position <Item>`.
  # macOS 27 moved them into ONE domain, com.apple.MenuBarAgent, as a flat dict
  # `*ItemPreferredPositions` whose keys are `module:<id>` / `status:<bundleid>::<item>`
  # and whose values are the offsets — so match those leaf keys in that domain.
  _pat='"NSStatusItem Preferred Position'
  [ "$dom" = "com.apple.MenuBarAgent" ] && _pat='"(module|status):'
  # `|| true` INSIDE the $() — diff exits 1 when the files differ, and pipefail
  # propagates that, which an outer `|| _k=""` would use to wipe the captured key
  # (the bug that kept this NOTE from ever firing). Keep the stdout, drop the status.
  _k=$(/usr/bin/diff "$prev" "$curr" 2>/dev/null \
        | /usr/bin/grep -E "^[<>].*$_pat" \
        | /usr/bin/sed -E 's/^[<>][[:space:]]*//; s/[[:space:]]*=.*//' \
        | /usr/bin/sort | /usr/bin/uniq -d | /usr/bin/head -1 || true)
  [ -n "$_k" ] || return 0
  _note_should_show __menubar_pos__ || return 0
  _log_kind "$kind" "Cmd: # NOTE: menu bar layout changed — item positions are pixel offsets, not"
  _log_kind "$kind" "Cmd: #       portable, so not emitted. A reorder OR a display connect/disconnect triggers this."
}

# Detect a pure Dock reorder — persistent-apps/others hold the SAME apps in a
# different order. The positional churn (GUID/book/file-mod-date) is filtered as
# noise, so a reorder otherwise emits nothing; surface a NOTE. Reproducing the
# order needs a full persistent-apps rewrite, which the per-key diff doesn't emit.
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
    _log_kind "$kind" "Cmd: # NOTE: Dock icons reordered — no command emitted; reproduce the order for deployment with dockutil (github.com/kcrawford/dockutil), e.g. dockutil --move <app> --position <N>"
  fi
}

# Battery charge limit change. Only com.apple.batteryui.charging.mac's
# `…prior.limit` moves, but that's UI state — the actual limit is SMC/powerd-
# managed and NOT reproducible via `defaults` (that write only sets the UI's
# remembered value). The key is filtered (is_noisy_key), so surface a NOTE here.
_note_charge_limit() {
  local kind="$1"
  _note_should_show __charge_limit__ || return 0
  _log_kind "$kind" "Cmd: # NOTE: battery charge limit changed — managed by the power daemon (SMC), not reproducible via defaults; set it in System Settings > Battery"
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

  # System-level prefs (/Library/Preferences, non-ByHost) are root-owned: the
  # emitted defaults/PlistBuddy commands must target the system file and run as
  # root. Flag it so get_plist_path + _build_defaults_write_cmd emit the full
  # /Library/Preferences path instead of the console user's ~/Library copy.
  typeset -g _EMIT_SYS=false
  [[ "$path" == /Library/Preferences/* && "$path" != */ByHost/* ]] && _EMIT_SYS=true

  init_cache
  local key prev curr prev_json curr_json
  key=$(hash_path "$path")
  prev="$CACHE_DIR/${key}.prev"
  curr="$CACHE_DIR/${key}.curr"
  prev_json="$CACHE_DIR/${key}.prev.json"
  curr_json="$CACHE_DIR/${key}.curr.json"

  # Mutex for fs_watch ↔ poll_watch on the same plist (wait up to 3s).
  # Reclaim lockdirs > 10s old — owning process was killed before rmdir.
  local lockdir="$CACHE_DIR/${key}.lock"
  if [ -d "$lockdir" ] && [ "$HAVE_ZSH_STAT" = "true" ]; then
    typeset -A _lockstat
    if zstat -H _lockstat "$lockdir" 2>/dev/null && \
       (( EPOCHSECONDS - ${_lockstat[mtime]:-0} > 10 )); then
      /bin/rmdir "$lockdir" 2>/dev/null || true
    fi
  fi
  local _wait_attempts=0
  while ! /bin/mkdir "$lockdir" 2>/dev/null; do
    _wait_attempts=$((_wait_attempts + 1))
    if [ "$_wait_attempts" -gt 30 ]; then
      # Lock held by the other watcher (fs_watch vs poll_watch), already emitting
      # this plist's diff — skip to avoid a double-emit. Not an error.
      return 0
    fi
    /bin/sleep 0.1
  done

  if [ "$silent" != "true" ]; then
    dump_plist "$path" "$curr" &
    dump_plist_json "$path" "$curr_json" &
    wait
  else
    dump_plist "$path" "$curr"
  fi

  # Retry with increasing delays — cfprefsd writes asynchronously, so the file
  # may still contain stale data when fs_usage fires. `defaults read` hints
  # cfprefsd to sync. Only re-dump text (JSON dumped once change is confirmed).
  # Skip expensive dump_plist when file mtime is unchanged (fast-path skip).
  if [ -s "$prev" ] && [ -s "$curr" ] && /usr/bin/cmp -s "$prev" "$curr" 2>/dev/null; then
    local _retry_delay _retry_changed=false _last_mtime _cur_mtime
    # ByHost prefs live in ByHost/<dom>.<UUID>.plist; the bare `defaults read`
    # only syncs the standard plist, so flush the ByHost variant when relevant.
    local _flush_hostflag=""
    [[ "$path" == *"/ByHost/"* ]] && _flush_hostflag="-currentHost"
    _last_mtime=$(/usr/bin/stat -f %m "$path" 2>/dev/null || echo "")
    for _retry_delay in 0.1 0.2 0.3 0.5 0.7; do
      /bin/sleep "$_retry_delay"
      # Hint cfprefsd to flush pending writes for this domain (read triggers sync)
      "${RUN_AS_USER[@]}" /usr/bin/defaults ${_flush_hostflag:+$_flush_hostflag} read "$_dom" >/dev/null 2>&1 || true
      _cur_mtime=$(/usr/bin/stat -f %m "$path" 2>/dev/null || echo "")
      # Last retry: always dump — stat %m has 1-second granularity so
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
    # Change detected during retry — dump JSON now for diff engine
    if [ "$_retry_changed" = "true" ] && [ "$silent" != "true" ]; then
      dump_plist_json "$path" "$curr_json"
    fi
    if [ -s "$prev" ] && [ -s "$curr" ] && /usr/bin/cmp -s "$prev" "$curr" 2>/dev/null; then
      /bin/rm -f "$curr" "$curr_json" 2>/dev/null || true
      /bin/rmdir "$lockdir" 2>/dev/null || true
      return 0
    fi
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
    _process_diff_lines "$kind" "$_emit_dom" "$_emit_hostflag" "$prev" "$curr" "$path" "$path"
    # A pure Dock reorder emits nothing above (positional churn is filtered) — flag it.
    [ "$_dom" = "com.apple.dock" ] && _note_dock_reorder "$kind" "$prev_json" "$curr_json"
    # Same for menu bar offsets — any domain, so no guard.
    _note_menubar_positions "$kind" "$prev" "$curr" "$_dom"
    # Battery charge limit lives in a UI-cache domain; real control is SMC — NOTE only.
    [ "$_dom" = "com.apple.batteryui.charging.mac" ] && _note_charge_limit "$kind"
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
  typeset -g _EMIT_SYS=false

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
  # An empty export means the domain is absent OR the read transiently failed
  # (cfprefsd busy under load — common on hot domains). Diffing an empty curr
  # against a full prev would emit every key as a spurious delete AND overwrite
  # the baseline empty → full re-add storm next cycle. Skip: keep last good state.
  [ -s "$tmpplist" ] || return 0
  /usr/bin/plutil -p "$tmpplist" > "$curr" 2>/dev/null || /bin/cat "$tmpplist" > "$curr" 2>/dev/null || :
  curr_json="$CACHE_DIR/${key}.curr.json"
  dump_plist_json "$tmpplist" "$curr_json"

  prev_json="$CACHE_DIR/${key}.prev.json"
  typeset -gA _SKIP_KEYS
  _SKIP_KEYS=()
  typeset -g _HAS_ARRAY_ADDITIONS=false

  if [ "$skip_arrays" != "true" ] && [ -n "$PYTHON3_BIN" ] && [ -s "$prev_json" ] && [ -s "$curr_json" ]; then
    _run_py_diff_workers DOMAIN "$dom" "$prev_json" "$curr_json" "$(get_plist_path "$dom" 2>/dev/null)" "$key"
  fi

  _process_diff_lines DOMAIN "$dom" "" "$prev" "$curr" "$tmpplist" "$dom"

  /bin/mv -f "$curr" "$prev" 2>/dev/null || /bin/cp -f "$curr" "$prev" 2>/dev/null || :
  /bin/mv -f "$curr_json" "$prev_json" 2>/dev/null || /bin/cp -f "$curr_json" "$prev_json" 2>/dev/null || :
}

# ---------------------------------------
# Monitoring
# ---------------------------------------

# Get the plist file path for a given domain
# Returns the full path to the .plist file, or empty string if not found
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

  # Try Group Containers (for app groups)
  if [ -d "$TARGET_HOME/Library/Group Containers" ]; then
    plist_path=$(/usr/bin/find "$TARGET_HOME/Library/Group Containers" -name "${domain}.plist" -type f 2>/dev/null | head -1) || plist_path=""
    [ -n "$plist_path" ] && echo "$plist_path" && return 0
  fi

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

# MDM: emit the $loggedInUser (+ $UUID for ByHost) resolvers ONCE, as executable
# Cmd: lines, so every templatized command below deploys as-is — no per-line repeat.
# Called from the watcher startup so it lands with the other setup NOTEs, right
# before the user makes changes (ALL mode: between the watcher summary and the
# "changes may take a few seconds" NOTE; single-domain: right after the Mode line).
_emit_mdm_resolver_header() {
  [ "$MDM_OUTPUT" = "true" ] || return 0
  log_line "Cmd: # NOTE: --mdm paths use \$loggedInUser (and \$UUID for ByHost) — set both once here, then every command below deploys on any Mac:"
  log_line "Cmd: loggedInUser=\$(/usr/bin/stat -f%Su /dev/console)"
  log_line "Cmd: UUID=\$(/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice | /usr/bin/awk -F'\"' '/IOPlatformUUID/{print \$4}')"
}

# Watcher PID registry. `_spawn <fn> [args…]` runs a watcher in the background
# and records its PID, so the teardown trap can kill/wait the whole set with
# ${_WATCH_PIDS[@]} instead of naming each PID (previously each PID appeared 3×:
# launch + kill + wait). start_watch and start_watch_all are mutually exclusive,
# so one global registry is safe.
typeset -ga _WATCH_PIDS=()
_spawn() { "$@" & _WATCH_PIDS+=($!); }

# Declarative watcher registry: "name|guard|fn|summary". SINGLE SOURCE — the
# guard string (eval'd in an `if`) gates BOTH the spawn AND the "Watchers active:"
# summary line, so availability is written once, not twice (previously the
# condition lived in the summary block AND each watcher's own `|| return 0`).
#   guard   : a test; `true` = always. Root-only detectors carry the id-0 test.
#   summary : "y" to list the name in the summary line (core fs/poll/cups/pmset
#             plumbing is intentionally omitted from that line, as before).
# Single-quoted so `$(id -u)`/`$PYTHON3_BIN` are stored literally and eval'd at
# launch time with the live values. Each watcher keeps its own internal
# `|| return 0` guard as harmless defense-in-depth.
typeset -ga _WATCHERS=(
  'fs|[ "$(id -u)" -eq 0 ]|fs_watch|'
  'poll|true|poll_watch|'
  'cups|true|cups_watch|'
  'pmset|true|pmset_watch|'
  'cups_sharing|[ -f /etc/cups/cupsd.conf ]|cups_sharing_watch|y'
  'ard_privs|[ -x /usr/bin/dscl ]|ard_privs_watch|y'
  'useracct|[ -x /usr/bin/dscl ]|useracct_watch|y'
  'hostname|[ -x /usr/sbin/scutil ]|hostname_watch|y'
  'default_apps|[ -n "$PYTHON3_BIN" ]|default_apps_watch|y'
  'wallpaper|[ -n "$PYTHON3_BIN" ]|wallpaper_watch|y'
  'timezone|[ -L /etc/localtime ]|timezone_watch|y'
  'security|[ -x /usr/sbin/spctl ]|security_watch|y'
  'fw_apps|[ -x /usr/libexec/ApplicationFirewall/socketfilterfw ]|fw_apps_watch|y'
  'spotlight_index|[ -x /usr/bin/mdutil ]|spotlight_watch|y'
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

# Generic file-snapshot poll loop shared by the state-polling watchers. Reads a
# baseline via <read-fn> (writes its state to STDOUT), then every <interval>s
# re-reads into a curr file; an optional <guard-fn> (given the curr file) can
# veto churn; on a real change it calls <onchange-fn snap curr> and advances the
# baseline. Args: name interval read-fn onchange-fn [guard-fn]. Collapses the
# ~8-line snap/while/cmp/cp skeleton each such watcher used to duplicate.
# Dynamic scoping: read-fn/onchange-fn are the caller watcher's nested funcs, so
# they still see that watcher's locals ($index/$secure/$sfw…) through this frame.
# `|| true` on onchange so a non-zero return can't set -e-abort the loop.
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

  # Try to find the plist file for optimized mtime monitoring
  plist_path=$(get_plist_path_for_domain "$DOMAIN")

  if [ -n "$plist_path" ]; then
    # Optimized mode: monitor file mtime, only diff when changed
    log_line "Mode: optimized mtime polling (0.5s check on $plist_path)"

    (
      # Take initial baseline snapshot so first user change is detected immediately
      show_domain_diff "$DOMAIN"
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
            # Periodic forced diff every 4 iterations (~2s): stat %m has 1-second
            # granularity, so same-second cfprefsd writes are invisible to mtime
            # comparison. show_domain_diff uses `defaults export` (reads cfprefsd
            # directly), so it catches any change the mtime check missed.
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
    log_line "Mode: standard polling (plist not found, checking domain every 1s)"

    (
      while true; do
        show_domain_diff "$DOMAIN"
        sleep 1
      done
    ) &
    _WATCH_PIDS+=($!)
  fi

  _emit_mdm_resolver_header

  trap 'kill -TERM ${_WATCH_PIDS[@]} 2>/dev/null || true; wait ${_WATCH_PIDS[@]} 2>/dev/null || true; /bin/rm -rf "$PREFWATCH_TMPDIR" 2>/dev/null || true; exit 0' TERM INT
  wait
}

# Monitor all preferences via fs_usage
start_watch_all() {
  if [ "$(id -u)" -ne 0 ]; then
    log_line "Mode: monitoring ALL preferences (polling only — no root)"
  else
    log_line "Mode: monitoring ALL preferences (fs_usage + polling)"
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
    dump_plist "$path" "$curr" &
    dump_plist_json "$path" "$curr_json" &
    wait
    /bin/mv -f "$curr" "$prev" 2>/dev/null || /bin/cp -f "$curr" "$prev" 2>/dev/null || :
    /bin/mv -f "$curr_json" "$prev_json" 2>/dev/null || /bin/cp -f "$curr_json" "$prev_json" 2>/dev/null || :
  }

  # Snapshot every non-excluded plist under ONE prefs tree, in parallel (16-way
  # throttle), advancing each to its baseline. Shared by the USER and SYSTEM
  # passes — they differed only in label + path. Sets SNAPSHOT_READY on finish.
  # Args: $1 label (e.g. "User"/"System" for the progress line; :u form for the
  # per-domain notice) ; $2 root path.
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
        # offset (drop one). Don't "normalize" [1]→[0] — [0] is empty, so
        # `wait ""` returns instantly and the fork throttle is defeated.
        wait "${_snap_pids[1]}" 2>/dev/null || true
        _snap_pids=("${_snap_pids[@]:1}")
      fi
    done < <(/usr/bin/find "$_root" -type f -name "*.plist" 2>/dev/null || true)
    for _pid in "${_snap_pids[@]}"; do wait "$_pid" 2>/dev/null || true; done
    printf "\r  ✓ ${_label} snapshot: %d domains scanned    \n" "$_snap_count"
    snapshot_notice "${_label} snapshot: completed ($_snap_count domains)"
    SNAPSHOT_READY="true"
  }

  # Initial snapshot
  snapshot_notice "Taking initial baseline — please wait before making changes"

  if [ -d "$prefs_user" ]; then
    _snapshot_tree User "$prefs_user"
  fi

  if [ "$INCLUDE_SYSTEM" = "true" ] && [ -d "$prefs_system" ]; then
    _snapshot_tree System "$prefs_system"
  fi

  if [ "${SNAPSHOT_READY:-false}" = "true" ]; then
    snapshot_notice "Initial snapshots processed — you can now make your changes"
    # Consolidated watcher status — derived from the SAME _WATCHERS registry that
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
    log_line "Cmd: # NOTE: Changes may take a few seconds to appear — wait between actions for reliable capture"
  fi

  # Primary detector — real-time plist writes captured live via fs_usage.
  fs_watch() {
    # Debounce: cfprefsd fires several fs_usage events per logical write.
    # Skip events seen <$FS_DEBOUNCE_S ago; poll_watch catches misses.
    typeset -A _fs_last_seen=()
    local _FS_DEBOUNCE_S=0.3
    # Force line-buffered I/O so a single fs_usage event isn't stuck in a
    # block buffer waiting for more data (notably for idle domains).
    # script(1) allocates a pty so fs_usage line-buffers; /dev/null is its
    # typescript sink, NOT an output redirect. macOS has no stdbuf — don't drop it.
    script -q /dev/null /usr/sbin/fs_usage -w -f filesys 2>/dev/null |
    /usr/bin/sed -l -nE 's@.*(/.*Library/(Group Containers|Containers|Preferences)/.*\.plist).*@\1@p' |
    /usr/bin/awk -v pu="${prefs_user}" -v ps="${prefs_system}" -v incsys="${INCLUDE_SYSTEM}" '{
      path=$0;
      if (index(path, pu)==1)      { print "USER " path }
      else if (index(path, ps)==1) { print "SYSTEM " path }
      else                         { print "OTHER " path }
      fflush()
    }' | while IFS= read -r line; do
      cat_type="${line%% *}"; plist="${line#* }"
      [ -z "$plist" ] && continue
      if [ "$cat_type" = "SYSTEM" ] && [ "${INCLUDE_SYSTEM}" != "true" ]; then
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
  }

  # Fallback detector — periodic poll (find -newer) for writes fs_usage buffers/misses.
  poll_watch() {
    local marker_user marker_sys active_dir
    # Flush-block locals — declared ONCE here, not inside the while loop.
    # zsh has TYPESET_SILENT off by default, so re-running `local foo` on a
    # variable that already holds a value prints `foo=value` to stdout; doing
    # it every iteration spammed the output with `_hd=…`/`_adom=…` lines.
    local _hd _af _adom _p _watchdog
    local -a _pids
    local -A _st
    marker_user="$PREFWATCH_TMPDIR/poll.marker.user"
    marker_sys="$PREFWATCH_TMPDIR/poll.marker.sys"
    active_dir="$PREFWATCH_TMPDIR/active-domains"
    /bin/mkdir -p "$active_dir" 2>/dev/null || true
    # Only create markers if not pre-initialized (avoids rescanning all plists after initial snapshot)
    [ -f "$marker_user" ] || /usr/bin/touch "$marker_user" 2>/dev/null || true
    [ -f "$marker_sys" ]  || /usr/bin/touch "$marker_sys" 2>/dev/null || true

    while true; do
      # Flush cfprefsd for recently-active domains (last 30s) before polling.
      # `defaults read` forces cfprefsd to sync pending writes for that domain.
      if [ -d "$active_dir" ] && [ "$HAVE_ZSH_STAT" = "true" ]; then
        # Refresh hot markers so they never expire via the 30s cleanup below
        for _hd in "${HOT_DOMAINS[@]}"; do
          /usr/bin/touch "$active_dir/$_hd" 2>/dev/null || true
        done
        _pids=()
        for _af in "$active_dir"/*(N); do
          [ -f "$_af" ] || continue
          zstat -H _st "$_af" 2>/dev/null || continue
          if (( EPOCHSECONDS - _st[mtime] > 30 )); then
            /bin/rm -f "$_af" 2>/dev/null || true
            continue
          fi
          _adom="${_af:t}"
          # One bare read per domain. No `-currentHost` here — it doubled the
          # fork/hang surface; ByHost is flushed by show_plist_diff/fs_watch instead.
          "${RUN_AS_USER[@]}" /usr/bin/defaults read "$_adom" >/dev/null 2>&1 &
          _pids+=($!)
        done
        # Watchdog: a hung cfprefsd read would freeze the loop on `wait`. Kill
        # stragglers (TERM 1s / KILL 1.5s) — missing a flush hint is harmless.
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
      /usr/bin/touch "$marker_user" 2>/dev/null || true
      /usr/bin/touch -r "$marker_user" "$marker_sys" 2>/dev/null || true
      /bin/sleep 0.5
    done
  }

  # Printer Sharing toggle — own sub-shell so the lpstat 5s debounce never blocks
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

  # Printer add/remove detector — diffs the CUPS printer list (lpstat).
  cups_watch() {
    local cups_snapshot cups_current
    cups_snapshot="$PREFWATCH_TMPDIR/cups.snap"
    cups_current="$PREFWATCH_TMPDIR/cups.curr"

    # Initial snapshot of installed printers
    /usr/bin/lpstat -a 2>/dev/null | /usr/bin/awk '{print $1}' | /usr/bin/sort > "$cups_snapshot" 2>/dev/null || true

    while true; do
      /bin/sleep 1
      /usr/bin/lpstat -a 2>/dev/null | /usr/bin/awk '{print $1}' | /usr/bin/sort > "$cups_current" 2>/dev/null || true

      # Debounce: if list changed, wait 5s and re-check to filter DNS-SD/Bonjour glitches
      if ! /usr/bin/cmp -s "$cups_snapshot" "$cups_current"; then
        /bin/sleep 5
        /usr/bin/lpstat -a 2>/dev/null | /usr/bin/awk '{print $1}' | /usr/bin/sort > "$cups_current" 2>/dev/null || true
      fi

      # Detect added printers
      /usr/bin/comm -13 "$cups_snapshot" "$cups_current" 2>/dev/null | while IFS= read -r printer; do
        [ -z "$printer" ] && continue
        log_line "Cmd: # CUPS: printer added — $printer"

        local uri=""
        uri=$(/usr/bin/lpstat -v "$printer" 2>/dev/null | /usr/bin/sed -nE 's/.*:[[:space:]]+(.*)/\1/p')

        # Extract non-default options
        local opts=""
        opts=$( { /usr/bin/lpoptions -p "$printer" 2>/dev/null | /usr/bin/tr ' ' '\n' | /usr/bin/grep -E '^(media|sides|print-color-mode|print-quality|printer-is-shared)=' | while IFS= read -r o; do printf " -o %s" "$o"; done; } || true)  # grep exits 1 if the printer has none of these → guard set -e

        local cmd="sudo lpadmin -p \"$printer\""
        [ -n "$uri" ] && cmd="$cmd -v \"$uri\""
        cmd="$cmd -m everywhere -E${opts}"
        log_line "Cmd: $cmd"
      done

      # Detect removed printers
      /usr/bin/comm -23 "$cups_snapshot" "$cups_current" 2>/dev/null | while IFS= read -r printer; do
        [ -z "$printer" ] && continue
        log_line "Cmd: # CUPS: printer removed — $printer"
        log_line "Cmd: sudo lpadmin -x \"$printer\""
      done

      /bin/cp -f "$cups_current" "$cups_snapshot" 2>/dev/null || true
    done
  }

  # Stream eslogger exec events for sharing CLIs (kickstart/systemsetup/sharing/
  # networksetup) — UI toggles that modify state outside /Library/Preferences.
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

    # Python reads stdin via readline() in a loop to avoid block-buffering
    # on the pipe — `for line in sys.stdin` defers to a large internal
    # buffer and would never fire on sparse event streams (one toggle every
    # few minutes). -u also forces unbuffered stdout.
    # The trailing " in each grep pattern anchors the match to eslogger's JSON
    # executable-path field (not a typo) — keeps this cheap prefilter tight
    # before the Python stage re-validates.
    /usr/bin/eslogger exec 2>/dev/null \
      | /usr/bin/grep --line-buffered -F -e '/kickstart"' -e '/systemsetup"' -e '/sharing"' -e '/networksetup"' -e '/launchctl"' \
      | "$PYTHON3_BIN" -u -c '
import json, sys, shlex, time
# Direct sharing-toolkit binaries — any invocation is relevant
DIRECT_BINS = ("kickstart", "systemsetup", "sharing", "networksetup")
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
# path — a bare "ssh.plist" substring also matched a jamf ".../startssh.plist" task.
SHARING_LABELS = ("com.apple.smbd", "com.apple.screensharing", "com.openssh.sshd",
                  "/ssh.plist", "com.apple.RemoteDesktop", "com.apple.ARDAgent")
# networksetup/systemsetup are polled read-only by macOS daemons (Wi-Fi refresh,
# Network scan, time sync). Drop queries — sometimes invoked WITHOUT the dash
# (`networksetup listallhardwareports`), so strip dashes first; write verbs all
# start with set/create/remove/add/switch/… anyway.
READONLY_VERBS = ("get", "list", "print", "show")
def is_readonly(basename, args):
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
            if is_readonly(basename, args):
                continue
            tail = " ".join(shlex.quote(a) for a in args[1:]) if len(args) > 1 else ""
            emit((exe + " " + tail).rstrip())
        elif basename == "launchctl" and len(args) > 1 and args[1] in LAUNCHCTL_SUBCMDS:
            # Sharing-only: drop third-party LaunchAgent churn (e.g. Zoom/MS
            # updaters bootstrapping us.zoom.updater.* in gui/<uid>).
            if not any(lbl in " ".join(args) for lbl in SHARING_LABELS):
                continue
            # Skip load/unload churn of socket-activated system daemons that
            # launchd cycles on its own (smbd, bootpd, dhcp6d) — their real
            # persistent state is reported by launchd_state_watch.
            if args[1] in ("load", "unload") and any(
                n in a for n in ("com.apple.smbd", "com.apple.bootpd", "com.apple.dhcp6d")
                for a in args):
                pass
            else:
                tail = " ".join(shlex.quote(a) for a in args[1:])
                emit(exe + " " + tail)
    except Exception:
        pass
' 2>/dev/null \
      | while IFS= read -r cmd; do
          [ -n "$cmd" ] || continue
          # Re-emitted sharing CLIs (systemsetup/sharing/networksetup/kickstart/
          # launchctl) all need root — prefix sudo like every other privileged emit.
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
import json, sys, fnmatch
prev_path, curr_path, domain = sys.argv[1], sys.argv[2], sys.argv[3]
# Third-party VM / container helpers that auto-toggle their own launchd
# state in the user gui session — not user-driven preference changes.
NOISE_PATTERNS = (
    "codes.rambo.*",                  # VirtualBuddy
    "com.parallels.*",                # Parallels Desktop
    "com.vmware.*",                   # VMware Fusion
    "org.virtualbox.*",               # VirtualBox
    "com.docker.*",                   # Docker Desktop
    "com.fortinet.*",                 # FortiClient VPN/security agent — re-bootstraps its daemons on wake
    "com.apple.ManagedClient*",       # MDM enrollagent auto-disable post-enrollment
    "com.apple.bootpd",               # DHCP/BOOTP server — flaps with Internet Sharing/network
    "com.apple.dhcp6d",               # DHCPv6 server — flaps automatically
    "com.apple.FolderActionsDispatcher",  # Folder Actions dispatcher — system auto-toggles it (enable+disable in one burst = net no-op flap)
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
# gui/<uid> services live in the console user's domain — a root replay needs
# `launchctl asuser <uid> …`, not a bare `launchctl … gui/<uid>/…`. System stays.
def _lc(verb, k):
    base = f"/bin/launchctl {verb} {domain}/{k}"
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

    # Resolve a launchd label to its LaunchDaemon plist path. Fast path =
    # filename matches the label (smbd, screensharing). Fallback for the
    # mismatches (com.openssh.sshd lives in ssh.plist): one grep over the
    # text plists, confirmed by the Label key. Binary-plist mismatches stay
    # unresolved → caller degrades to the reboot NOTE. Prints path or fails.
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

    # Emit an enable/disable command, plus:
    #  - a one-shot dedup NOTE if sharing_exec_watch logged the equivalent
    #    load/unload form for the same service in the last 10s;
    #  - the bootstrap/bootout companion (system domain) so the output is
    #    actually replayable — enable/disable only flips the persistent
    #    on-disk flag; a socket/on-demand service (smbd, ssh, …) won't
    #    start/stop until launchd (re)loads it, so the UI stays unchanged
    #    until a bootstrap/bootout (or a reboot).
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
      # every other privileged emit — prefix sudo for a copy-paste deploy.
      log_line "Cmd: sudo $cmd"

      # Bootstrap/bootout companion (system daemons only — gui agent plist
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
        # per service-toggle burst, re-show after 15s of quiet — so a later,
        # separate sharing change still carries its explanation. The actionable
        # bootstrap/bootout command below is emitted every time regardless.
        if _note_should_show __launchd_bootstrap__; then
          log_line "Cmd: # NOTE: enable/disable only sets the persistent flag; a socket/on-demand service (smbd, ssh, screensharing) won't start/stop — and its UI toggle won't move — until launchd (re)loads it via bootstrap/bootout, or a reboot"
        fi
        [ -n "$_companion" ] && log_line "Cmd: $_companion"
      fi
    }

    while true; do
      /bin/sleep 2
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
      /bin/sleep 2
      /usr/bin/pmset -g custom > "$pmset_current" 2>/dev/null || true

      # Quick check — skip parsing if nothing changed
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
            log_line "Cmd: # Energy: ${section} — ${key} changed: ${old_label} → ${new_label}"
          else
            log_line "Cmd: # Energy: ${section} — ${key} set to ${new_label}"
          fi
          log_line "Cmd: sudo /usr/bin/pmset ${flag} ${key} ${val}"
        done <<< "$curr_parsed"
      fi

      /bin/cp -f "$pmset_current" "$pmset_snapshot" 2>/dev/null || true
    done
  }

  # Remote Management per-user privileges (Observe/Control/…). These live as the
  # `naprivs` bitmask in each user's directory record — not a plist, and the UI
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
      # only persists the value — the ARD agent must restart to pick it up, or
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

  # Detect local user account add/remove (real users, UID >= 501). The account
  # itself (UID/home/password) lives in OpenDirectory/dslocal, not a plist, so
  # it is NOT reproducible via `defaults` — emit a factual NOTE only, no command.
  # `dscl -list` needs no root and works in every mode (same approach as ard_privs).
  # Also suppresses the misleading com.apple.preferences.accounts 'deletedUsers'
  # churn (see is_noisy_pbcmd) so the NOTE is the single source of truth.
  useracct_watch() {
    _read_useracct() {
      /usr/bin/dscl . -list /Users UniqueID 2>/dev/null | /usr/bin/awk '$2 >= 501 {print $1}' | /usr/bin/sort || true
    }
    _onchange_useracct() {
      local _snap="$1" _curr="$2" u
      while IFS= read -r u; do
        [ -n "$u" ] || continue
        log_line "Cmd: # NOTE: user account '$u' added — the account itself (UID/home/password) is NOT reproducible via defaults; use sysadminctl/dscl or a config profile"
      done < <(/usr/bin/comm -13 "$_snap" "$_curr" 2>/dev/null)
      while IFS= read -r u; do
        [ -n "$u" ] || continue
        log_line "Cmd: # NOTE: user account '$u' removed — not reproducible via defaults; use sysadminctl/dscl"
      done < <(/usr/bin/comm -23 "$_snap" "$_curr" 2>/dev/null)
      return 0
    }
    # _guard_nonempty: a transient dscl failure must not report every user as
    # removed. (Cost: removing the very last real user is missed — negligible.)
    _snapshot_watch useracct 2 _read_useracct _onchange_useracct _guard_nonempty
  }

  # Hostname changes (LocalHostName / ComputerName / HostName) land in the
  # configd-managed SystemConfiguration/preferences.plist; a raw PlistBuddy Set
  # to that file is unreliable (configd caches it), so the plist diff's write is
  # filtered (is_noisy_pbcmd, domain 'preferences') and this watcher emits the
  # documented `scutil --set` instead. `scutil --get` needs no root; the set does.
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
    # LocalHostName is always set — if it read empty, scutil hiccuped; skip so a
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

  # LaunchServices default-app handlers (URL schemes + file types) live in the
  # user's launchservices.secure.plist, whose domain is EXCLUDED (churny, and a
  # raw PlistBuddy Set won't re-register a handler). This watcher diffs the
  # LSHandlers array and emits `utiluti`, which changes the real default AND
  # waits for the macOS confirmation prompt the user must accept.
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
        log_line "Cmd: utiluti $_kind set $_what $_app"
      done < <(/usr/bin/comm -13 "$_snap" "$_curr" 2>/dev/null)
      return 0
    }
    # 1s (not the usual 2s): a default-app change is a discrete user action the
    # admin is actively watching for, so favor responsiveness. The bulk of the
    # residual latency is lsd flushing the secure plist async — not the poll.
    _snapshot_watch default_apps 1 _read_defapps _onchange_defapps _guard_nonempty
  }

  # Desktop wallpaper lives in the com.apple.wallpaper Store (Index.plist),
  # OUTSIDE ~/Library/Preferences — so the plist diff never sees it — and it
  # isn't reproducible via defaults anyway (built-in wallpapers are a
  # provider+config with no file; custom images are security-scoped bookmarks).
  # This watcher just DETECTS a change and points at desktoppr for deployment.
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
# Serialize the wallpaper config WITHOUT LastSet/LastUse — the system rewrites
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
    _onchange_wallpaper() {
      _note_should_show __wallpaper__ && log_line "Cmd: # NOTE: desktop wallpaper changed — not reproducible via defaults. Deploy with desktoppr (github.com/scriptingosx/desktoppr): desktoppr /path/to/image.jpg"
      return 0
    }
    _snapshot_watch wallpaper 2 _read_wallpaper _onchange_wallpaper _guard_nonempty
  }

  # Time zone lives in the /etc/localtime SYMLINK (→ .../zoneinfo/<Zone>), NOT a
  # plist — so the diff never sees it, and sharing_exec_watch only catches a
  # `systemsetup` CLI run (root+eslogger), not a GUI change. This watcher polls
  # the symlink and emits the EXACT `systemsetup -settimezone` command (the zone
  # is recoverable, unlike the wallpaper path). Detection needs no root.
  timezone_watch() {
    [ -L /etc/localtime ] || return 0
    _read_tz() {
      local t; t=$(/usr/bin/readlink /etc/localtime 2>/dev/null) || return 0
      printf '%s' "${t#*/zoneinfo/}"      # /var/db/timezone/zoneinfo/Europe/Paris → Europe/Paris
    }
    # NTP time server lives in /etc/ntp.conf (readable; `systemsetup
    # -getnetworktimeserver` needs root) — same Date & Time pane, folded in here.
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
            # manual set — flag it so the deploy sticks.
            [ "$(defaults read /Library/Preferences/com.apple.timezone.auto Active 2>/dev/null)" = "1" ] \
              && log_line "Cmd: # NOTE: 'Set time zone automatically' is ON (com.apple.timezone.auto) — it can override a manual set; turn it off first (Settings > Date & Time)"
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
  # it) on change. Compliance-relevant — surfaces if a protection got disabled.
  security_watch() {
    local sfw=/usr/libexec/ApplicationFirewall/socketfilterfw
    _read_security() {
      local fv gk gkdev _gkv fw fws fwb fwsig
      # `|| true` INSIDE each $(): a grep with no match exits 1 → pipefail +
      # set -e would abort mid-read (killing this watcher / losing later fields).
      fv=$(/usr/bin/fdesetup status 2>/dev/null | /usr/bin/grep -oE 'is (On|Off)' | /usr/bin/head -1 || true)
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
      printf 'filevault\t%s\ngatekeeper\t%s\ngatekeeper-devid\t%s\nfirewall\t%s\nfw-stealth\t%s\nfw-blockall\t%s\nfw-signed\t%s\n' \
        "$fv" "$gk" "$gkdev" "$fw" "$fws" "$fwb" "$fwsig"
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
            filevault)
              # Enabling needs a recovery key (interactive/MDM) — not a single command.
              log_line "Cmd: # NOTE: FileVault is now ${_v#is } — not reproducible by one command; enable needs a recovery key (sudo fdesetup enable) or an MDM/config profile" ;;
            gatekeeper)
              if [ "$_v" = enabled ]; then
                log_line "Cmd: sudo /usr/sbin/spctl --master-enable"
              else
                log_line "Cmd: sudo /usr/sbin/spctl --master-disable"
                log_line "Cmd: # NOTE: on macOS 15+ disabling Gatekeeper also needs confirming in Settings > Privacy & Security"
              fi ;;
            gatekeeper-devid)
              # App Store-only (developer id disabled) vs +identified-developers.
              # No single spctl command reproduces it — it's a GUI/MDM setting.
              if [ "$_v" = disabled ]; then
                log_line "Cmd: # NOTE: Gatekeeper set to 'App Store' only (identified developers disabled) — no single spctl command reproduces this; set it in System Settings > Privacy & Security, or via an MDM Gatekeeper config profile"
              else
                log_line "Cmd: # NOTE: Gatekeeper now allows 'App Store and identified developers' — set in System Settings > Privacy & Security or an MDM config profile (no single spctl command)"
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

  # Per-application firewall rules — the per-app "allow/block incoming
  # connections" list (Settings > Network > Firewall > Options), e.g. blocking
  # smbd. On modern macOS com.apple.alf.plist is GONE, so the plist diff never
  # sees it, and security_watch covers only the GLOBAL firewall. Poll
  # `socketfilterfw --listapps` (reads WITHOUT root) and emit the reproducer:
  # `--add <path>` (into the list) + `--blockapp`/`--unblockapp <path>`, or
  # `--remove <path>`. Root is needed only to APPLY (the NOTE says so).
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
        if [ -z "$_oldstate" ]; then log_line "Cmd: sudo $sfw --add \"$_path\""; fi
        [ "$_state" = block ] && log_line "Cmd: sudo $sfw --blockapp \"$_path\"" || log_line "Cmd: sudo $sfw --unblockapp \"$_path\""
      done < "$_curr"
      # Removed rules (in snap, gone from curr → the app's rule was deleted)
      while IFS=$'\t' read -r _path _state; do
        [ -n "$_path" ] || continue
        /usr/bin/awk -F'\t' -v p="$_path" '$1==p{f=1} END{exit !f}' "$_curr" 2>/dev/null && continue
        _note_should_show __fw_apps__ && log_line "Cmd: # NOTE: per-app firewall rule removed (Firewall > Options)"
        log_line "Cmd: sudo $sfw --remove \"$_path\""
      done < "$_snap"
      return 0
    }
    _snapshot_watch fw_apps 3 _read_fwapps _onchange_fwapps _guard_nonempty
  }

  # Spotlight indexing state lives in the metadata store, not a plist — read it
  # with `mdutil -s` (no root) and emit `mdutil -i` on change. Common MDM op
  # (disabling indexing on a volume). Distinct from the com.apple.Spotlight plist
  # (search categories), which the diff already covers.
  spotlight_watch() {
    [ -x /usr/bin/mdutil ] || return 0
    # `|| true` INSIDE the pipe: grep exits 1 when mdutil's output has no
    # enabled/disabled token → pipefail + set -e would abort (kill) this watcher.
    _read_spotlight() { /usr/bin/mdutil -s / 2>/dev/null | /usr/bin/grep -oE '(enabled|disabled)' | /usr/bin/head -1 || true; }
    _onchange_spotlight() {
      local _v; _v=$(/bin/cat "$2" 2>/dev/null)
      [ "$_v" = enabled ] && log_line "Cmd: sudo /usr/bin/mdutil -i on /" || log_line "Cmd: sudo /usr/bin/mdutil -i off /"
      return 0
    }
    _snapshot_watch spotlight 3 _read_spotlight _onchange_spotlight _guard_nonempty
  }

  # Pre-initialize poll markers so first iteration only sees post-snapshot changes
  /usr/bin/touch "$PREFWATCH_TMPDIR/poll.marker.user" 2>/dev/null || true
  /usr/bin/touch "$PREFWATCH_TMPDIR/poll.marker.sys" 2>/dev/null || true
  # Create active-domains tracking dir (shared by fs_watch + poll_watch)
  /bin/mkdir -p "$PREFWATCH_TMPDIR/active-domains" 2>/dev/null || true
  # Pre-seed hot domains so first change is detected without fs_usage→poll
  # round-trip. poll_watch auto-refreshes them so they never expire.
  local _hd
  for _hd in "${HOT_DOMAINS[@]}"; do
    /usr/bin/touch "$PREFWATCH_TMPDIR/active-domains/$_hd" 2>/dev/null || true
  done

  # Launch every watcher whose guard passes — single loop over the SAME _WATCHERS
  # registry that built the summary line above. `eval "$_W_GUARD"` sits in an `if`
  # so a false guard (e.g. non-root for fs) can't set -e-abort. Adding a watcher
  # now means ONE registry entry: no separate launch line, no PID var, no trap.
  local _w=""
  for _w in "${_WATCHERS[@]}"; do
    _watcher_parse "$_w"
    if eval "$_W_GUARD"; then _spawn "$_W_FN"; fi
  done

  trap 'kill -TERM ${_WATCH_PIDS[@]} 2>/dev/null || true; wait ${_WATCH_PIDS[@]} 2>/dev/null || true; /bin/rm -rf "$PREFWATCH_TMPDIR" 2>/dev/null || true; exit 0' TERM INT
  wait
}

# ============================================================================
# MAIN — pre-flight, logging setup, launch
# ============================================================================

# Pre-flight banner + conditional confirmation. The y/n prompt only appears
# when Python3/CLT is missing (degraded detection — user should acknowledge).
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
  prompt_yn "⚠ Python3 unavailable — limited detection.

Run 'xcode-select --install' to enable full detection (array/dict diffs, PlistBuddy commands).

Start anyway?" || _pf_rc=$?
  case $_pf_rc in
    0) ;;
    1) printf "Aborted.\n"; exit 0 ;;
    2)
      printf "⚠ No TTY or GUI session available — auto-continuing with limited detection\n"
      /usr/bin/logger -t "prefwatch[init]" -- "Python3 unavailable — auto-continued (no prompt channel)"
      ;;
  esac
fi

# Prepare log file
LOGFILE="$(prepare_logfile "$LOGFILE")"

# Announce the actually used log path
if [ "${ONLY_CMDS:-false}" = "true" ]; then
  printf "[init] Log file: %s\n" "$LOGFILE" >> "$LOGFILE" 2>/dev/null || true
else
  { printf "[init] Log file: %s\n" "$LOGFILE"; } | { cat; cat >> "$LOGFILE" 2>/dev/null || true; }
fi
/usr/bin/logger -t "prefwatch[init]" -- "Log file: $LOGFILE"

if [ "$ALL_MODE" = "true" ]; then
  log_line "Starting: monitoring ALL preferences"
else
  log_line "Starting monitoring on $DOMAIN"
fi

# Python3 status — user already consented at pre-flight; log/warn only
if [ -n "$PYTHON3_BIN" ]; then
  log_line "Python3: $PYTHON3_BIN (array change detection enabled)"
else
  printf "WARNING: Xcode Command Line Tools not installed — Python3 unavailable\n"         | tee -a "$LOGFILE" 2>/dev/null || true
  printf "Without Python3: array/dict changes and PlistBuddy commands will not be detected\n" | tee -a "$LOGFILE" 2>/dev/null || true
  /usr/bin/logger -t "prefwatch[init]" -- "Python3 unavailable — limited detection"
fi

# Warn if ALL mode without root (fs_usage unavailable)
if [ "$ALL_MODE" = "true" ] && [ "$(id -u)" -ne 0 ]; then
  local _ts; _ts="$(get_timestamp)"
  local _w1="[$_ts] WARNING: Running without sudo — fs_usage is unavailable"
  local _w2="[$_ts]   Real-time detection disabled; only polling will be used (slower)"
  local _w3="[$_ts]   For full detection, re-run with: sudo $0 ALL"
  printf "%s\n%s\n%s\n" "$_w1" "$_w2" "$_w3"
  printf "%s\n%s\n%s\n" "$_w1" "$_w2" "$_w3" >> "$LOGFILE" 2>/dev/null || true
  /usr/bin/logger -t "prefwatch[init]" -- "Running without sudo — fs_usage unavailable, polling only"
fi

# Warn if domain is normally excluded (but don't stop — user explicitly requested it)
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

# Tear the watcher down on a termination signal aimed at the MAIN pid, then remove the
# tmpdir. Without this, a SIGTERM/SIGHUP to the main pid (a supervisor, launchd,
# `kill <pid>`) kills this shell by default disposition — the EXIT trap is skipped on
# signal death — orphaning the watcher child and leaking $PREFWATCH_TMPDIR. Ctrl-C
# already works (process-group SIGINT reaches the child's own trap); this makes
# single-pid signals safe too, which matters most in Jamf/root where the process is
# killed non-interactively by pid.
# Kill a process and its whole subtree, leaves first, so nothing gets reparented to init
# and survives. The watcher tree is main → WATCH_PID → sub-watchers → transient workers;
# just TERM-ing WATCH_PID lets its own trap kill the sub-watchers, but a sub-watcher's
# nested subshell can reparent away and linger. Walking the tree bottom-up closes that.
_kill_tree() {
  local _root=$1 _kid
  [ -n "$_root" ] || return 0
  for _kid in $(pgrep -P "$_root" 2>/dev/null); do _kill_tree "$_kid"; done
  kill -TERM "$_root" 2>/dev/null || true
}
_shutdown_watcher() {
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

if [ "$NO_CONSOLE" != "true" ] && is_console_running; then
  # Robust Console-close detection. Two hazards over a long run (each would stop
  # monitoring silently while Console is still open):
  #  1. `sleep` interrupted by a worker's SIGCHLD returns non-zero → under set -e
  #     that would abort the shell. → `sleep … || true`.
  #  2. `pgrep -x Console` can transiently miss (Console briefly unmatched under
  #     load). A single miss must NOT end monitoring → require N CONSECUTIVE
  #     misses (~N seconds) before concluding Console really closed.
  _console_misses=0
  while true; do
    if is_console_running; then
      _console_misses=0
    else
      _console_misses=$(( _console_misses + 1 ))
      [ "$_console_misses" -ge 5 ] && break
    fi
    sleep 1 || true
  done
  log_line "Console.app closed — stopping monitoring"
  kill -TERM "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  exit 0
else
  if [ "$NO_CONSOLE" = "true" ]; then
    log_line "Console disabled (--no-console) — monitoring until Ctrl+C / SIGTERM"
  else
    log_line "Console not detected — continuing monitoring (Ctrl+C to stop)"
  fi
  wait "$WATCH_PID" 2>/dev/null || true
  exit 0
fi
