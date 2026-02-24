#!/bin/zsh
# ============================================================================
# Script: prefwatch.sh
# Version: 1.1.1
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
#     -e, --exclude <glob>  Comma-separated glob patterns to exclude
#     -h, --help            Show this help message
#     --mdm                 MDM deployment mode: replace user home path with
#                           $loggedInUser variable in PlistBuddy commands
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
# ============================================================================

# ============================================================================
# CONFIGURATION
# ============================================================================

# Execution security (zsh)
set -e
set -u
set -o pipefail

# Help message
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
  -e, --exclude <glob>  Comma-separated glob patterns to exclude
  -h, --help            Show this help message
  --mdm                 MDM deployment mode: replace user home path with
                        \$loggedInUser variable in PlistBuddy commands

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

EOF
  exit 0
}

# Parse CLI arguments
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
      -e|--exclude)
        if [[ -z "${2:-}" ]]; then
          echo "Error: --exclude requires a pattern argument" >&2
          exit 1
        fi
        EXCLUDE_DOMAINS="${2}"
        shift 2
        ;;
      --mdm)
        MDM_OUTPUT_RAW="true"
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
  ONLY_CMDS_RAW="${ONLY_CMDS:-${7:-true}}"
  EXCLUDE_DOMAINS="${8:-}"
  MDM_OUTPUT_RAW="${9:-false}"
else
  # CLI mode: use flag-based parsing
  parse_cli_args "$@"
fi

# Boolean normalization
to_bool() {
  case "$(printf "%s" "${1:-}" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on|enable|enabled|oui|vrai) echo "true";;
    *) echo "false";;
  esac
}
ONLY_CMDS=$(to_bool "$ONLY_CMDS_RAW")
INCLUDE_SYSTEM=$(to_bool "$INCLUDE_SYSTEM_RAW")
MDM_OUTPUT=$(to_bool "$MDM_OUTPUT_RAW")

# Replace user home path with $loggedInUser variable for MDM deployment scripts
mdm_plist_path() {
  if [ "$MDM_OUTPUT" = "true" ] && [[ "$1" == "$HOME"* ]]; then
    printf '%s' "/Users/\$loggedInUser${1#$HOME}"
  else
    printf '%s' "$1"
  fi
}

# Always disable xtrace to prevent noisy variable assignments (kv=, keyname=, etc.)
# This prevents debug output from appearing even with -v/--verbose flag
# Users can still see all output via log files with timestamps
# Use multiple methods to ensure xtrace is disabled regardless of shell state
set +x 2>/dev/null || true
set +v 2>/dev/null || true
unsetopt xtrace 2>/dev/null || true
unsetopt verbose 2>/dev/null || true
{ set +o xtrace; } 2>/dev/null || true

# ============================================================================
# EXCLUSIONS
# ============================================================================

# Default exclusion patterns for noisy/irrelevant domains
# These domains change frequently but are rarely useful for preference monitoring
# You can override with --exclude flag or $8 parameter in Jamf mode
typeset -a DEFAULT_EXCLUSIONS=(
  # Background daemons & agents (very noisy, no user-configurable preferences)
  "com.apple.cfprefsd*"
  "com.apple.notificationcenterui*"
  "com.apple.ncplugin*"
  "com.apple.knowledge-agent"
  "com.apple.DuetExpertCenter*"
  "com.apple.xpc.activity2"
  "com.apple.powerlogd"
  "ContextStoreAgent*"

  # Cloud sync internals (constant updates, not user preferences)
  "com.apple.CloudKit*"
  "com.apple.bird"
  "com.apple.cloudd"
  "com.apple.CallHistorySyncHelper"
  "com.apple.appleaccountd"
  "com.apple.remindd.babysitter"

  # System maintenance & cache (noisy, not user settings)
  "com.apple.CacheDelete"

  # Security & crash reporting (noisy, not user settings)
  "com.apple.CrashReporter"
  "com.apple.security*"
  "com.apple.biometrickitd"

  # Accessibility telemetry (hearing device state, not user preferences)
  "com.apple.AccessibilityHearingNearby"
  "com.apple.SpeakSelection"

  # Network internals (frequent changes, not user preferences)
  "com.apple.networkextension*"
  "com.apple.wifi.known-networks"
  "com.apple.vmnet"
  "com.apple.LaunchServices*"  # zsh globs are case-sensitive, need both
  "com.apple.launchservices*"
  "com.apple.apsd"

  # Backup internals (constant state updates, not user preferences)
  "com.apple.TimeMachine"
  "com.apple.timemachine*"

  # Graphics internals (updates on every window change)
  "com.apple.CoreGraphics"

  # App store internals (not user preferences)
  "com.apple.appstored"
  "com.apple.AppStore"
  "com.apple.AppleMediaServices*"

  # Game Center internals (daemon state, not user preferences)
  "com.apple.gamed"
  "com.apple.gamecenter"

  # Input analytics / telemetry (not user preferences)
  "com.apple.inputAnalytics*"
  "com.apple.appleintelligencereporting"
  "com.apple.GenerativeFunctions*"

  # Calculator currency cache (auto-updated exchange rates)
  "com.apple.calculateframework"

  # Software Update cache (available updates metadata, not user settings)
  "com.apple.SoftwareUpdate"

  # Power management internals (constant battery updates)
  "com.apple.PowerManagement*"
  "com.apple.BackgroundTaskManagement*"

  # Audio internals (device routing state, not user preferences)
  "com.apple.audio.SystemSettings"

  # User activity tracking (Handoff/Continuity state, not user preferences)
  "com.apple.coreservices.useractivityd*"

  # System internals (no plist-based user settings)
  "com.apple.loginwindow"
  "com.apple.spaces"
  "com.apple.BezelServices"
  "com.apple.jetpackassetd"
  "com.apple.windowserver*"
  "com.apple.settings.Storage"
  "diagnostics_agent"

  # Services menu localization cache (auto-regenerated, not user preferences)
  "com.apple.ServicesMenu.Services"

  # Address Book UI state (window geometry, selection, not user preferences)
  "com.apple.AddressBook"

  # Calendar internals (account UUIDs, UI state, not user preferences)
  "com.apple.iCal"

  # Messages preview rendering internals (screen scale, dimensions)
  "com.apple.MobileSMSPreview"

  # Notification Center internal state (app path tracking, binary blobs)
  "com.apple.ncprefs"

  # Account existence tracking (internal state, not user preferences)
  "com.apple.accounts.exists"

  # Find My device daemon (APS tokens, internal state)
  "com.apple.icloud.fmfd"

  # Telephony framework internals (camera/call state)
  "com.apple.TelephonyUtilities"

  # Apple TV & Music apps (column info, launch state, internal metadata)
  "com.apple.TV"
  "com.apple.Music"
  "com.apple.itunescloud"
  "com.apple.itunescloudd"

  # Find My app & framework (UI state, window geometry, precision flags)
  "com.apple.findmy*"
  "com.apple.icloud.searchpartyuseragent"

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

  # Third-party updaters & telemetry (background noise, not user preferences)
  "com.microsoft.autoupdate*"
  "com.microsoft.shared"
  "com.microsoft.office"
  "com.microsoft.OneDriveUpdater"
  "*.zoom.updater*"
  "com.openai.chat"
  "ChatGPTHelper"
  "com.segment.storage.*"

  # Background observers (constant telemetry, not user preferences)
  "com.apple.suggestions.*Observer*"
  "com.apple.personalizationportrait.*Observer*"

  # Cellular/comm internals (boot counters, modem state)
  "com.apple.commcenter*"

  # Ad platform internals (correlation IDs, tracking counters)
  "com.apple.AdPlatforms"

  # Background event counters & sync telemetry (constant updates, not user preferences)
  "com.apple.cseventlistener"
  "com.apple.spotlightknowledge"
  "com.apple.amsengagementd"
  "com.apple.StatusKitAgent"
  "com.apple.Accessibility.Assets"
  "com.apple.AOSKit*"

  # Data sync daemons (CalDAV/CardDAV/Exchange account refresh states)
  "com.apple.dataaccess*"

  # Siri assistant (account validation token renewal)
  "com.apple.assistant*"

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

  # Note: The following are now intelligently filtered instead of excluded:
  # - com.apple.dock (filter workspace-*, keep orientation, autohide, etc.)
  # - com.apple.finder (filter FXRecentFolders, keep ShowPathbar, etc.)
  # - com.apple.Safari (filter History*; limited — most prefs in internal DB since Sequoia)
  # - com.apple.systemsettings (filter timestamps, keep actual settings)
  # - com.apple.Mail, Messages, etc. (limited — most prefs in internal DB since Sequoia)
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

# Binary availability checks (optimization to avoid repeated lookups)
# Detect /bin/date availability at startup
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

if [ -z "$PYTHON3_BIN" ]; then
  # Python3 not available or Command Line Tools not installed
  # Script will still work but without array change detection (JSON diff)
  _py_warn="Python3 not available — array change detection disabled."
  _py_warn="$_py_warn Install Command Line Tools: xcode-select --install"
fi

# Temp directory — all temp files under one directory for clean /tmp
PREFWATCH_TMPDIR=$(/usr/bin/mktemp -d "/tmp/prefwatch.${$}.XXXXXX") || PREFWATCH_TMPDIR="/tmp/prefwatch.${$}"
/bin/mkdir -p "$PREFWATCH_TMPDIR" 2>/dev/null || true

# Cache initialization
typeset -A _EXCLUSION_CACHE  # Cache for domain exclusion checks
CACHE_DIR=""                  # Cache directory for plist diffs (WATCH_ALL mode)

# Domain tag for logging
DOMAIN_TAG="$DOMAIN"
[ "$ALL_MODE" = "true" ] && DOMAIN_TAG="all"

# Extract script version from header
SCRIPT_VERSION=$(head -20 "$0" 2>/dev/null | /usr/bin/grep "^# Version:" | /usr/bin/sed -E 's/^# Version: //' | head -1)
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

# Helper function for optimized timestamp
get_timestamp() {
  if [ "$HAVE_BIN_DATE" = "true" ]; then
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
  else
    # Use $HOME instead of ~ to ensure proper expansion in [ -f ... ] tests
    printf '%s' "$HOME/Library/Preferences/${domain}.plist"
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

# Initialize cache directory
init_cache() {
  if [ -z "$CACHE_DIR" ]; then
    CACHE_DIR="$PREFWATCH_TMPDIR/cache"
    /bin/mkdir -p "$CACHE_DIR" 2>/dev/null || true
  fi
}

# Prepare log files
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

  # Cache check
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
    # Window positions & UI state (changes on every resize/move)
    NSWindow\ Frame*|NSNavPanel*|NSSplitView*|NSTableView*|NSStatusItem*|*WindowBounds*|*WindowState*|*WindowFrame*|*WindowOriginFrame*|*PreferencesWindow*|FK_SidebarWidth*|*.column.*.width|*.column.*.width.*)
      return 0 ;;

    # Sparkle updater internals (auto-update framework state)
    SUUpdateGroupIdentifier|SULastCheckTime|SUHasLaunchedBefore|SUSendProfileInfo|SUSkippedVersion)
      return 0 ;;

    # Timestamps & dates (metadata, not preferences) - UNIVERSAL
    # Matches: lastRetryTimestamp, LastUpdate, last-seen, updateTimestamp, CKStartupTime, lastCheckTime, etc.
    *timestamp*|*Timestamp*|*-timestamp|*LastUpdate*|*LastSeen*|*-last-seen|*-last-update|*-last-modified|*LastRetry*|*LastSync*|*lastRetry*|*lastSync*|*StartupTime*|*StartTime*|*CheckTime|lastCheckTime|*LastSuccess*|*lastSuccess*|*LastKnown*|*lastKnown*|*LastLoadedOn*)
      return 0 ;;

    # Date fields (float/string dates are usually metadata)
    *Date|Date)
      return 0 ;;

    # Error states & sync errors (transient, not user preferences)
    *Error|*Errors|*error|*errors|*ErrorCode*|*ErrorDomain*|*ErrorUserInfo*|IMCloudKitSyncErrors|IMSerializedError*)
      return 0 ;;

    # Rollout configs & A/B testing (system telemetry, not user settings)
    rollouts|rolloutId|deploymentId|*RolloutId|*DeploymentId)
      return 0 ;;

    # Analytics & telemetry counters (not user preferences)
    *Analytics*|*Telemetry*|*BootstrapTime*|*lastBootstrap*|*HeartbeatDate*)
      return 0 ;;

    # Device/Library/Session IDs (change per device, not user preferences)
    *-library-id|*-persistent-id|*-session-id|*-device-id|shared-library-id|devices-persistent-id)
      return 0 ;;

    # UUIDs and flags (transient notification/state identifiers)
    # Matches: uuid, UUID, *UUID, *uuid (e.g., sessionUUID, updatedSinceBootUUID)
    uuid|UUID|flags|*UUID|*uuid)
      return 0 ;;

    # Feature flags (internal state, not user preferences)
    feature.*)
      return 0 ;;

    # Zoom focus tracking state (transient during zoom operations)
    closeViewZoom*FocusFollowMode*)
      return 0 ;;

    # Metadata/sync counters (change constantly, not user preferences)
    *ChangeCount*|*MetaDataChange*|*ChangeToken*|*DataSequenceKey*)
      return 0 ;;

    # File metadata (changes on every file operation)
    parent-mod-date|file-mod-date|mod-count|file-type)
      return 0 ;;

    # Recent items & history (noisy, changes constantly)
    *RecentFolders|*RecentDocuments|*RecentSearches|*History*|*RecentlyUsed*)
      return 0 ;;

    # Finder sync state (iCloud Drive extension toolbar, not user preferences)
    FXSync*)
      return 0 ;;

    # Linguistic data assets (spell checker internal state)
    NSLinguisticDataAssets*)
      return 0 ;;

    # Third-party update schedulers (background check timestamps)
    MRSActivityScheduler)
      return 0 ;;

    # App launch counters & donation reminders (internal state)
    uses|launchCount|*reminder.date|*donate*)
      return 0 ;;

    # Migration flags (one-time internal state, not user preferences)
    *DidMigrate*|*didMigrate*)
      return 0 ;;

    # WebKit internal state (set when opening Settings panels that use WebKit views)
    WebKitUseSystemAppearance)
      return 0 ;;

    # Cache & temporary data
    *-cache|*Cache*|*-temp|*Temp*|*-tmp)
      return 0 ;;

    # View state (scroll positions, selected items, etc.)
    *ScrollPosition|*SelectedItem*|*ViewOptions*|*IconViewSettings*)
      return 0 ;;

    # Playback & connection state (transient states across all apps)
    *PlaybackStatus*|*Playback*Status*|*ConnectionState*|*lastNowPlayedTime*|*LastConnected*)
      return 0 ;;

    # App state & status (running state, temporary status)
    state|status|State|Status)
      return 0 ;;
  esac

  # Hash keys (session IDs, cache keys) - long hex strings (zsh built-in regex, no fork)
  # Examples: bc4a9925ba8a1ebc964af5dbb213795013950b6b8b234aacf7fb20f5a791e5d7 (SHA256)
  if [[ "$keyname" =~ ^[0-9a-fA-F]{32,}$ ]]; then
    return 0
  fi

  # UUID keys (internal identifiers used as key names, not user preferences)
  # Examples: 3A4B5C6D-1234-5678-9ABC-DEF012345678 (com.apple.prodisplaylibrary, etc.)
  if [[ "$keyname" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    return 0
  fi

  # Feature flags (ALL_CAPS keys with underscores) - system A/B testing configs
  # Examples: SIRI_MEMORY_SYNC_CONFIG, HEALTH_FEATURE_AVAILABILITY
  if [[ "$keyname" =~ ^[A-Z][A-Z_0-9]+$ ]] && [[ "$keyname" == *_* ]]; then
    return 0
  fi

  # ========================================================================
  # DOMAIN-SPECIFIC NOISY KEYS
  # ========================================================================

  case "$domain" in
    # Dock preferences: Keep useful settings, filter workspace state & tile internals
    com.apple.dock)
      case "$keyname" in
        # Noisy: workspace IDs, counts, expose gestures, trash state, recent apps
        workspace-*|mod-count|showAppExposeGestureEnabled|last-messagetrace-stamp|lastShowIndicatorTime|trash-full|recent-apps)
          return 0 ;;
        # Noisy: internal tile metadata (reorder noise, not user preferences)
        GUID|dock-extra|tile-type|is-beta|file-type|file-mod-date|parent-mod-date|book|file-data|tile-data)
          return 0 ;;
        # Note: bundle-identifier, _CFURLString, file-label are useful in PlistBuddy output
        # (identify the app); suppressed as flat defaults write by _skip_keys
        # Keep: orientation, autohide, tilesize, magnification, persistent-apps, etc.
      esac
      ;;

    # Finder preferences: Keep view settings, filter recent folders
    com.apple.finder|com.apple.Finder)
      case "$keyname" in
        # Noisy: recent folders, trash state, search history, window name
        FXRecentFolders|FXConnectToBounds|SearchRecentsSavedViewStyle|SearchRecentsViewSettings|GoToField*|LastTrashState|FXDesktopVolumePositions|name)
          return 0 ;;
        # Keep: ShowPathbar, AppleShowAllFiles, FXPreferredViewStyle, etc.
      esac
      ;;

    # System Settings: Filter timestamps, keep actual settings
    com.apple.systemsettings*)
      case "$keyname" in
        # Noisy: last seen timestamps, navigation state, indexing timestamps, extension state
        *-last-seen|*LastUpdate*|*NavigationState*|*update-state-indexing*|*.extension)
          return 0 ;;
        # Keep: actual preference values
      esac
      ;;

    # Control Center: Filter UI positioning state, keep preference toggles
    com.apple.controlcenter)
      case "$keyname" in
        # Noisy: status item visibility/position changes from UI interaction
        NSStatusItem*)
          return 0 ;;
        # Keep: actual preference toggles
      esac
      ;;

    # HIToolbox: Filter transient input source state, keep layout additions/removals
    com.apple.HIToolbox)
      case "$keyname" in
        # Noisy: current active keyboard (changes on every language switch)
        AppleSavedCurrentInputSource|InputSourceKind|KeyboardLayout\ ID|KeyboardLayout\ Name)
          return 0 ;;
        # Keep: AppleEnabledInputSources (adding/removing keyboard layouts)
      esac
      ;;

    # Universal Access: Filter internal change history, keep accessibility settings
    com.apple.universalaccess)
      case "$keyname" in
        History|com.apple.custommenu.apps) return 0 ;;
      esac
      ;;

    # GlobalPreferences: Filter Keyboard panel first-open artifacts
    .GlobalPreferences)
      case "$keyname" in
        KB_SpellingLanguage|KB_SpellingLanguageIsAutomatic) return 0 ;;
        # Keep: KB_DoubleQuoteOption, KB_SingleQuoteOption, NSUserQuotesArray (quote style)
      esac
      ;;

    # Spotlight: Filter UI state and counters, keep preference settings
    com.apple.Spotlight)
      case "$keyname" in
        # Noisy: usage counters, window state, timestamps, binary data
        engagementCount*|engagementDate*|useCount|startTime|showedFTE)
          return 0 ;;
        lastWindowPosition|lastVisibleScreenRect|userHasMovedWindow|windowHeight)
          return 0 ;;
        queryViewOptions|PasteboardHistoryVersion|PreferencesVersion)
          return 0 ;;
        NSStatusItem*|__NSEnable*|SSAction*|FTEReset*)
          return 0 ;;
        # Keep: DisabledUTTypes, EnabledPreferenceRules, orderedItems, etc.
      esac
      ;;

    # Zoom: Filter per-user session state (tab selection, XMPP identifiers)
    us.zoom.xos)
      case "$keyname" in
        *@xmpp.zoom.us*) return 0 ;;
      esac
      ;;

    # iPod/iPhone sync: Filter connection timestamps and counters
    com.apple.iPod)
      case "$keyname" in
        Connected|Use\ Count) return 0 ;;
      esac
      ;;

    # Terminal: Keep profile settings, filter preferences UI state
    com.apple.Terminal)
      case "$keyname" in
        TTAppPreferences\ Selected\ Tab) return 0 ;;
      esac
      ;;

    # Safari: Keep useful prefs, filter safe browsing updates
    com.apple.Safari)
      case "$keyname" in
        # Noisy: safe browsing cache, history
        SafeBrowsing*|History*|LastSession*)
          return 0 ;;
        # Keep: HomePage, SearchEngine, AutoFillPasswords, etc.
      esac
      ;;

    # CUPS printing prefs: Keep UseLastPrinter, filter printer history
    org.cups.PrintingPrefs)
      case "$keyname" in
        Network|PrinterID) return 0 ;;
      esac
      ;;

    # Print presets: Keep meaningful settings, filter Fiery driver defaults & print metadata
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
    *"ViewSettings"*|*":GUID "*|*":window-file:"*|\
    *":com.apple.finder.SyncExtensions"*)
      return 0 ;;
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

    if [[ "$out" =~ 'defaults[[:space:]]+write[[:space:]]+' ]]; then
      local _cmd_dom
      _cmd_dom=$(printf '%s' "$out" | /usr/bin/sed -nE 's/.*defaults[[:space:]]+write[[:space:]]+([^[:space:]]+).*/\1/p')
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
  if [[ "$msg" =~ '(Cmd: |CMD: )?defaults[[:space:]]+write[[:space:]]+' ]]; then
    local _raw _cmd_dom
    _raw=$(printf '%s' "$msg" | /usr/bin/sed -E 's/^(Cmd: |CMD: )//')
    _cmd_dom=$(printf '%s' "$_raw" | /usr/bin/sed -nE 's/.*defaults[[:space:]]+write[[:space:]]+([^[:space:]]+).*/\1/p')
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
  # Disable xtrace to prevent debug output leaking
  { set +x; } 2>/dev/null

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
    printf '# WARNING: Array deletion - indexes change after each deletion\n'
    printf '# For multiple deletions: execute from HIGHEST index to LOWEST\n'
  fi
  local _mdm_path=$(mdm_plist_path "$plist_path")
  printf '/usr/libexec/PlistBuddy -c '\''Delete %s'\'' "%s"\n' "$target" "$_mdm_path"
  return 0
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
  local kind="$1" dom="$2" prev_json="$3" curr_json="$4"
  [ -n "$PYTHON3_BIN" ] || return 0
  [ -s "$curr_json" ] || return 0
  [ -s "$prev_json" ] || return 0

  local py_output
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
        return ("string", val)
    return None

def pb_escape(s):
    """Escape spaces in PlistBuddy key paths"""
    return s.replace(' ', '\\ ')

def emit_plistbuddy(array_name, index, item, path_prefix=""):
    """Recursively generate PlistBuddy Add commands for nested dicts"""
    cmds = []
    if isinstance(item, dict):
        for k, v in item.items():
            key_path = f"{path_prefix}{pb_escape(k)}"
            if isinstance(v, dict):
                cmds.append(f"PBCMD\tAdd :{array_name}:{index}:{key_path} dict")
                cmds.extend(emit_plistbuddy(array_name, index, v, key_path + ":"))
            elif isinstance(v, list):
                cmds.append(f"PBCMD\tAdd :{array_name}:{index}:{key_path} array")
            else:
                tv = pb_type_value(v)
                if tv:
                    cmds.append(f"PBCMD\tAdd :{array_name}:{index}:{key_path} {tv[0]} {tv[1]}")
    return cmds

diff(prev, curr, [])

emitted_arrays = set()
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
    # Emit array creation if the array is new (didn't exist in prev)
    if arr_name not in emitted_arrays and arr_name not in prev:
        print(f"PBCMD\tAdd :{arr_name} array")
        emitted_arrays.add(arr_name)
    if isinstance(item, dict):
        keys = ','.join(sorted(all_keys_recursive(item)))
        # Output metadata line (for _skip_keys in shell)
        print(f"{prefix[0]}\t{index}\t{keys}\t")
        # Dock: emit app name comment for readability
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

  [ -n "$py_output" ] || return 0

  # Pass through all Python output (metadata + PBCMD lines)
  # PBCMD lines are handled by the caller (not here, because this function
  # is called inside $() and log_* output would be captured instead of displayed)
  printf '%s\n' "$py_output"
}

# Dedup domain-level notes across handlers (show_plist_diff + show_domain_diff)
typeset -gA _NOTED_DOMAIN=()

# Emit contextual notes for domains that need extra steps
# Called once per domain after array metadata processing
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
      _note="Some changes require 'killall Finder' to apply — view settings may also be overridden per-folder in .DS_Store" ;;
    com.apple.WindowManager)
      _note="First opening Desktop & Dock settings writes all defaults — only subsequent changes reflect actual modifications" ;;
    com.apple.universalaccess)
      _note="First opening Accessibility settings writes all defaults — only subsequent changes reflect actual modifications" ;;
  esac
  # Match on array_base for cross-domain keys (e.g. ColorSync in ByHost GlobalPreferences)
  case "$array_base" in
    com.apple.ColorSync.Devices)
      _note="Color profile changes require logout/login to take effect" ;;
  esac
  [ -n "$_note" ] || return 0
  # Dedup: emit each note only once per session
  local _note_key="${dom}:${_note}"
  [[ -z "${_NOTED_DOMAIN[$_note_key]+isset}" ]] || return 0
  _NOTED_DOMAIN[$_note_key]=1
  log_line "Cmd: # NOTE: $_note"
}

# Detect and emit commands for array deletions
emit_array_deletions() {
  local kind="$1" dom="$2" prev_json="$3" curr_json="$4"
  [ -n "$PYTHON3_BIN" ] || return 0
  [ -s "$curr_json" ] || return 0
  [ -s "$prev_json" ] || return 0

  local py_output
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
) || return 0

  [ -n "$py_output" ] || return 0

  typeset -A _noted_del_arrays=()
  while IFS=$'\t' read -r base idx keylist app_label; do
    [ -n "$base" ] || continue

    # Skip noisy arrays
    is_noisy_key "$dom" "$base" && continue

    # Emit contextual note once per array
    if [ -z "${_noted_del_arrays[$base]:-}" ]; then
      _emit_contextual_note "$dom" "$base"
      _noted_del_arrays[$base]=1
    fi

    # Dock: emit app name comment for readability
    if [ -n "$app_label" ]; then
      case "$kind" in
        USER) log_user "Cmd: # Dock: removed $app_label" ;;
        SYSTEM) log_system "Cmd: # Dock: removed $app_label" ;;
        *) log_line "Cmd: # Dock: removed $app_label" ;;
      esac
    fi

    local delete_cmd="defaults delete ${dom} \":${base}:${idx}\""

    if is_noisy_command "$delete_cmd"; then
      :
    elif [ "$kind" = "DOMAIN" ] && [ "${ALL_MODE:-false}" = "true" ] && [ "${ONLY_CMDS:-false}" = "true" ]; then
      :
    else
      local pb_delete
      if pb_delete=$(convert_delete_to_plistbuddy "$delete_cmd" 2>/dev/null); then
        while IFS= read -r pb_line; do
          [ -n "$pb_line" ] || continue
          case "$kind" in
            USER) log_user "Cmd: $pb_line" ;;
            SYSTEM) log_system "Cmd: $pb_line" ;;
            DOMAIN) log_line "Cmd: $pb_line" ;;
            *) log_line "Cmd: $pb_line" ;;
          esac
        done <<< "$pb_delete"
      else
        case "$kind" in
          USER) log_user "Cmd: $delete_cmd" ;;
          SYSTEM) log_system "Cmd: $delete_cmd" ;;
          DOMAIN) log_line "Cmd: $delete_cmd" ;;
          *) log_line "Cmd: $delete_cmd" ;;
        esac
      fi
    fi
  done <<< "$py_output"
}

# Detect and emit PlistBuddy commands for changes inside nested dicts
# Handles cases like symbolichotkeys where values change deep inside dicts
emit_nested_dict_changes() {
  local kind="$1" dom="$2" prev_json="$3" curr_json="$4"
  [ -n "$PYTHON3_BIN" ] || return 0
  [ -s "$curr_json" ] || return 0
  [ -s "$prev_json" ] || return 0

  local py_output
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

# Recursively emit PlistBuddy Add commands for an entire dict/value tree
def emit_add_tree(base_parts, obj):
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
            print("PBCMD\t# NOTE: First change creates the full structure — subsequent changes only modify individual entries")
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
            # Same-length array: detect moved elements (same content, different index)
            # Uses strip_volatile to ignore metadata that changes on every plist rewrite
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
        full_path = ':'.join(p.replace(' ', '\\ ') for p in path_parts)
        print(f"PBCMD\tSet :{full_path} {pvalue}")
PY
) || return 0

  [ -n "$py_output" ] || return 0

  # Pass through all Python output (metadata + PBCMD lines)
  printf '%s\n' "$py_output"
}

# Display plist file diff
show_plist_diff() {
  local kind="$1" path="$2" mode="${3:-normal}" silent="false"
  [ "$mode" = "silent" ] && silent="true"
  [ -f "$path" ] || return 0

  local _dom
  _dom="$(domain_from_plist_path "$path")"
  if is_excluded_domain "$_dom"; then
    return 0
  fi

  init_cache
  local key prev curr prev_json curr_json
  key=$(hash_path "$path")
  prev="$CACHE_DIR/${key}.prev"
  curr="$CACHE_DIR/${key}.curr"
  prev_json="$CACHE_DIR/${key}.prev.json"
  curr_json="$CACHE_DIR/${key}.curr.json"

  # Lock to prevent fs_watch + poll_watch processing the same file simultaneously
  local lockdir="$CACHE_DIR/${key}.lock"
  if ! /bin/mkdir "$lockdir" 2>/dev/null; then
    return 0
  fi

  if [ "$silent" != "true" ]; then
    dump_plist "$path" "$curr" &
    dump_plist_json "$path" "$curr_json" &
    wait
  else
    dump_plist "$path" "$curr"
  fi

  # Dedup: skip if no change since last processing
  # Retry with increasing delays — cfprefsd writes to disk asynchronously,
  # so the file may still contain stale data when fs_usage fires (0.5s + 1.5s = 2s max)
  if [ -s "$prev" ] && [ -s "$curr" ] && /usr/bin/cmp -s "$prev" "$curr" 2>/dev/null; then
    local _retry_delay
    for _retry_delay in 0.5 1.5; do
      /bin/sleep "$_retry_delay"
      if [ "$silent" != "true" ]; then
        dump_plist "$path" "$curr" &
        dump_plist_json "$path" "$curr_json" &
        wait
      else
        dump_plist "$path" "$curr"
      fi
      /usr/bin/cmp -s "$prev" "$curr" 2>/dev/null || break
    done
    if [ -s "$prev" ] && [ -s "$curr" ] && /usr/bin/cmp -s "$prev" "$curr" 2>/dev/null; then
      /bin/rm -f "$curr" "$curr_json" 2>/dev/null || true
      /bin/rmdir "$lockdir" 2>/dev/null || true
      return 0
    fi
  fi

  typeset -A _skip_keys
  _skip_keys=()
  local _array_meta_raw=""
  local _has_array_additions=false

  if [ "$silent" != "true" ] && [ -n "$PYTHON3_BIN" ] && [ -s "$prev_json" ] && [ -s "$curr_json" ]; then
    _array_meta_raw=$(emit_array_additions "$kind" "$_dom" "$prev_json" "$curr_json") || _array_meta_raw=""
    # Detect changes inside nested dicts (e.g. symbolichotkeys)
    local _nested_raw
    _nested_raw=$(emit_nested_dict_changes "$kind" "$_dom" "$prev_json" "$curr_json") || _nested_raw=""
    if [ -n "$_nested_raw" ]; then
      if [ -n "$_array_meta_raw" ]; then
        _array_meta_raw="${_array_meta_raw}"$'\n'"${_nested_raw}"
      else
        _array_meta_raw="$_nested_raw"
      fi
    fi
    if [ -n "$_array_meta_raw" ]; then
      _has_array_additions=true
      typeset -A _noted_arrays=()
      local _domain_note_emitted=false
      local -a _pending_comments=()
      local _last_array_base=""
      while IFS=$'\t' read -r _array_base _array_idx _array_keys; do
        [ -n "$_array_base" ] || continue
        # Handle PBCMD lines (PlistBuddy commands from Python)
        if [ "$_array_base" = "PBCMD" ]; then
          local _pb_cmd="$_array_idx"
          # Comments from Python (e.g. # Dock: AppName, # NOTE:) — buffer until a real command passes filtering
          if [[ "$_pb_cmd" == "#"* ]]; then
            _pending_comments+=("$_pb_cmd")
            continue
          fi
          # Filter noisy key paths in PlistBuddy commands
          is_noisy_pbcmd "$_dom" "$_pb_cmd" && continue
          # Emit domain-level note before first non-filtered command (using tracked array_base)
          if [ "$_domain_note_emitted" = "false" ]; then
            _emit_contextual_note "$_dom" "$_last_array_base"
            _domain_note_emitted=true
          fi
          # Flush buffered comments now that we have a real command
          if (( ${#_pending_comments[@]} > 0 )); then
            for _pc in "${_pending_comments[@]}"; do
              case "$kind" in
                USER) log_user "Cmd: $_pc" ;;
                SYSTEM) log_system "Cmd: $_pc" ;;
                *) log_line "Cmd: $_pc" ;;
              esac
            done
            _pending_comments=()
          fi
          local _mdm_path=$(mdm_plist_path "$path")
          local pb_full="/usr/libexec/PlistBuddy -c '${_pb_cmd}' \"${_mdm_path}\""
          case "$kind" in
            USER) log_user "Cmd: $pb_full" ;;
            SYSTEM) log_system "Cmd: $pb_full" ;;
            *) log_line "Cmd: $pb_full" ;;
          esac
          continue
        fi
        # Metadata line: populate _skip_keys and track array_base for deferred note
        _last_array_base="$_array_base"
        _skip_keys["$_array_base"]=1
        if [ -n "$_array_idx" ]; then
          _skip_keys[":${_array_base}:${_array_idx}"]=1
        fi
        if [ -n "$_array_keys" ]; then
          typeset -a _array_key_list
          IFS=',' read -rA _array_key_list <<< "$_array_keys"
          for _k in "${_array_key_list[@]}"; do
            [ -n "$_k" ] || continue
            _k=$(printf '%s' "$_k" | /usr/bin/sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
            [ -n "$_k" ] || continue
            _skip_keys["$_k"]=1
            _skip_keys["${_array_base}:${_k}"]=1
            _skip_keys[":${_array_base}:${_k}"]=1
            if [ -n "$_array_idx" ]; then
              _skip_keys["${_array_base}:${_array_idx}:${_k}"]=1
              _skip_keys[":${_array_base}:${_array_idx}:${_k}"]=1
            fi
          done
        fi
      done <<< "$_array_meta_raw"
    fi

    emit_array_deletions "$kind" "$_dom" "$prev_json" "$curr_json"
  fi

  if [ -s "$prev" ] && [ "$silent" != "true" ]; then
    # Pre-collect keys from + lines to identify value changes (not deletions)
    typeset -A _added_keys
    _added_keys=()
    while IFS= read -r _aline; do
      local _ak
      _ak=$(printf '%s' "$_aline" | /usr/bin/sed -nE 's/^\+[[:space:]]*"([^"]+)".*/\1/p')
      [ -n "$_ak" ] && _added_keys["$_ak"]=1
    done < <(/usr/bin/diff -u "$prev" "$curr" 2>/dev/null | /usr/bin/awk 'NR>2 && $0 ~ /^\+/ && $0 !~ /^\+\+\+/')

    typeset -A _noted_dom=()

    # Use process substitution (not pipe) so _skip_keys is accessible in while loop
    while IFS= read -r dline; do
      [ -n "$dline" ] || continue

      if [ "$kind" = "USER" ]; then
        log_user "Diff $path: $dline"
      else
        log_system "Diff $path: $dline"
      fi

      local kv keyname val snippet pretty_key array_meta="" array_name="" array_idx="" array_cmd=""
      kv=$(printf '%s' "$dline" | /usr/bin/sed -nE 's/^[+-][[:space:]]*"([^"]+)"[[:space:]]*=>[[:space:]]*(.*)$/\1|\2/p')
      if [ -n "$kv" ]; then
        keyname="${kv%%|*}"
        val="${kv#*|}"

        if [ -n "${_skip_keys[$keyname]:-}" ]; then
          continue
        fi

        # Additional filtering: if we had array additions, skip any top-level key
        # that looks like it's part of a dictionary (contains space or common dict key patterns)
        if [ "$_has_array_additions" = "true" ] && [[ "$keyname" != *":"* ]]; then
          # Skip keys that are likely dictionary sub-keys (contain spaces or match common patterns)
          if [[ "$keyname" == *" "* ]] || [[ "$keyname" =~ ^(InputSourceKind|KeyboardLayout|tile-data|file-data|file-label|bundle-identifier|_CFURLString).*$ ]]; then
            continue
          fi
        fi

        if is_noisy_key "$_dom" "$keyname"; then
          continue
        fi

        if array_meta=$(parse_array_index_key "$keyname" 2>/dev/null); then
          array_name="${array_meta%% *}"
          array_idx="${array_meta##* }"
          pretty_key="${array_name}[${array_idx}]"
        else
          pretty_key="$keyname"
        fi

        snippet=$(printf '%s' "$val" | /usr/bin/tr '\n' ' ' | /usr/bin/awk '{s=$0; if(length(s)>160) {print substr(s,1,157) "..."} else {print s}}')
        if [ "$kind" = "USER" ]; then
          log_user "Key: ${pretty_key} | Item: ${snippet}"
        else
          log_system "Key: ${pretty_key} | Item: ${snippet}"
        fi

        case "$dline" in
          +*)
            if [ -n "$array_name" ]; then
              continue
            fi
            # Skip nested keys (indent ≥ 4 spaces in diff = sub-dict values)
            if [[ "$dline" =~ ^[+][[:space:]]{4,}\" ]]; then
              continue
            fi
            local base dom hostflag cmd trimmed type_val noquotes str
            base="$(/usr/bin/basename "$path")"
            dom="${base%.plist}"
            hostflag=""
            if [[ "$path" == *"/ByHost/"* ]]; then
              hostflag="-currentHost"
              dom="$(printf '%s' "$dom" | /usr/bin/sed -E 's/\.[0-9A-Fa-f-]{8,}$//')"
            fi
            trimmed=$(printf '%s' "$val" | /usr/bin/sed -E 's/^[[:space:]]+|[[:space:]]+$//g')

            # Check actual plist type first to avoid misdetection (e.g., float "1" detected as bool/int)
            local actual_type=""
            actual_type=$(/usr/bin/defaults read-type "$dom" "$keyname" ${hostflag:+$hostflag} 2>/dev/null | /usr/bin/awk '{print $NF}') || actual_type=""

            # Use actual plist type when available for numeric/bool values to avoid misdetection
            if [ "$actual_type" = "float" ]; then
              cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-float ${trimmed}"
            elif [ "$actual_type" = "integer" ]; then
              cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-int ${trimmed}"
            elif [ "$actual_type" = "boolean" ]; then
              type_val=$( [ "$trimmed" = "1" ] || [ "$trimmed" = "true" ] && echo TRUE || echo FALSE )
              cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-bool ${type_val}"
            elif [[ "$trimmed" =~ ^\".*\"$ ]]; then
              noquotes="${trimmed#\"}"; noquotes="${noquotes%\"}"
              str=$(printf '%s' "$noquotes" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g')
              cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-string \"${str}\""
            elif [[ "$trimmed" == "true" ]] || [[ "$trimmed" == "false" ]]; then
              type_val=$(printf '%s' "$trimmed" | /usr/bin/tr '[:lower:]' '[:upper:]')
              cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-bool ${type_val}"
            elif [[ "$trimmed" == "0" ]] || [[ "$trimmed" == "1" ]]; then
              type_val=$( [ "$trimmed" = "1" ] && echo TRUE || echo FALSE )
              cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-bool ${type_val}"
            elif [[ "$trimmed" =~ ^-?[0-9]+$ ]]; then
              cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-int ${trimmed}"
            elif [[ "$trimmed" =~ ^-?[0-9]*\.[0-9]+$ ]]; then
              cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-float ${trimmed}"
            else
              local plutil_result plutil_type plutil_value
              if plutil_result=$(extract_type_value_with_plutil "$path" "$keyname" 2>/dev/null); then
                plutil_type="${plutil_result%%|*}"
                plutil_value="${plutil_result#*|}"
                case "$plutil_type" in
                  string) cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-string \"${plutil_value}\"" ;;
                  bool) cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-bool ${plutil_value}" ;;
                  int) cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-int ${plutil_value}" ;;
                  float) cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-float ${plutil_value}" ;;
                  array|dict) cmd="" ;;
                  *) cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }<type> <value>" ;;
                esac
              else
                cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }<type> <value>"
              fi
            fi

            if [ -n "$cmd" ]; then
              local _cmd_dom
              _cmd_dom=$(printf '%s' "$cmd" | /usr/bin/sed -nE 's/.*defaults[[:space:]]+write[[:space:]]+([^[:space:]]+).*/\1/p')
              if [ -n "$_cmd_dom" ] && is_excluded_domain "$_cmd_dom"; then
                :
              elif is_noisy_command "$cmd"; then
                :
              else
                if [ -z "${_noted_dom[$_dom]:-}" ]; then
                  _emit_contextual_note "$_dom" ""
                  _noted_dom[$_dom]=1
                fi
                if [ "$kind" = "USER" ]; then
                  log_user "Cmd: $cmd"
                else
                  log_system "Cmd: $cmd"
                fi
              fi
            fi
            ;;
          -*)
            # Skip nested keys (same logic as + case above)
            if [[ "$dline" =~ ^[-][[:space:]]{4,}\" ]]; then
              continue
            fi
            # Skip value changes (key exists in both - and + lines = changed, not deleted)
            if [ -n "${_added_keys[$keyname]:-}" ]; then
              continue
            fi
            # Skip flat key deletes for print presets (array deletion covers all sub-keys)
            if [[ "$_dom" == com.apple.print.custompresets* ]]; then
              continue
            fi
            # Verify key is truly deleted by checking the current snapshot
            # If the key still exists in $curr, it's a value change not a deletion
            if [ -z "$array_name" ] && /usr/bin/grep -qF "\"$keyname\" =>" "$curr" 2>/dev/null; then
              continue
            fi
            local base dom hostflag target delete_cmd
            base="$(/usr/bin/basename "$path")"
            dom="${base%.plist}"
            hostflag=""
            if [[ "$path" == *"/ByHost/"* ]]; then
              hostflag="-currentHost"
              dom="$(printf '%s' "$dom" | /usr/bin/sed -E 's/\.[0-9A-Fa-f-]{8,}$//')"
            fi
            if [ -n "$array_name" ]; then
              target=":${array_name}:${array_idx}"
            else
              target="$keyname"
            fi
            delete_cmd="defaults"
            if [ -n "$hostflag" ]; then
              delete_cmd="${delete_cmd} ${hostflag}"
            fi
            delete_cmd="${delete_cmd} delete ${dom} \"${target}\""

            if is_noisy_command "$delete_cmd"; then
              :
            elif [ "$kind" = "USER" ]; then
              local pb_delete
              if pb_delete=$(convert_delete_to_plistbuddy "$delete_cmd" 2>/dev/null); then
                while IFS= read -r pb_line; do
                  [ -n "$pb_line" ] || continue
                  if [[ "$pb_line" == "#"* ]]; then
                    log_user "$pb_line"
                  else
                    log_user "Cmd: $pb_line"
                  fi
                done <<< "$pb_delete"
              else
                log_user "Cmd: $delete_cmd"
              fi
            else
              local pb_delete
              if pb_delete=$(convert_delete_to_plistbuddy "$delete_cmd" 2>/dev/null); then
                while IFS= read -r pb_line; do
                  [ -n "$pb_line" ] || continue
                  if [[ "$pb_line" == "#"* ]]; then
                    log_system "$pb_line"
                  else
                    log_system "Cmd: $pb_line"
                  fi
                done <<< "$pb_delete"
              else
                log_system "Cmd: $delete_cmd"
              fi
            fi
            ;;
        esac
      fi
    done < <(/usr/bin/diff -u "$prev" "$curr" 2>/dev/null | /usr/bin/awk 'NR>2 && ($0 ~ /^\+/ || $0 ~ /^-/) && $0 !~ /^\+\+\+|^---/')
  else
    :
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
  if [ -s "$tmpplist" ]; then
    /usr/bin/plutil -p "$tmpplist" > "$curr" 2>/dev/null || /bin/cat "$tmpplist" > "$curr" 2>/dev/null || :
    curr_json="$CACHE_DIR/${key}.curr.json"
    dump_plist_json "$tmpplist" "$curr_json"
  else
    : > "$curr" 2>/dev/null || true
    curr_json="$CACHE_DIR/${key}.curr.json"
    : > "$curr_json" 2>/dev/null || true
  fi

  prev_json="$CACHE_DIR/${key}.prev.json"
  typeset -A _skip_keys
  _skip_keys=()
  local _array_meta_raw=""
  local _has_array_additions=false

  if [ "$skip_arrays" != "true" ] && [ -n "$PYTHON3_BIN" ] && [ -s "$prev_json" ] && [ -s "$curr_json" ]; then
    _array_meta_raw=$(emit_array_additions DOMAIN "$dom" "$prev_json" "$curr_json") || _array_meta_raw=""
    emit_array_deletions DOMAIN "$dom" "$prev_json" "$curr_json"
    # Detect changes inside nested dicts (e.g. symbolichotkeys)
    local _nested_raw
    _nested_raw=$(emit_nested_dict_changes DOMAIN "$dom" "$prev_json" "$curr_json") || _nested_raw=""
    if [ -n "$_nested_raw" ]; then
      if [ -n "$_array_meta_raw" ]; then
        _array_meta_raw="${_array_meta_raw}"$'\n'"${_nested_raw}"
      else
        _array_meta_raw="$_nested_raw"
      fi
    fi

    if [ -n "$_array_meta_raw" ]; then
      _has_array_additions=true
      local _pb_plist_path
      _pb_plist_path="$(get_plist_path "$dom" 2>/dev/null)"
      typeset -A _noted_arrays=()
      local _domain_note_emitted=false
      local -a _pending_comments=()
      local _last_array_base=""
      while IFS=$'\t' read -r _array_base _array_idx _array_keys; do
        [ -n "$_array_base" ] || continue
        # Handle PBCMD lines (PlistBuddy commands from Python)
        if [ "$_array_base" = "PBCMD" ]; then
          local _pb_cmd="$_array_idx"
          # Comments from Python (e.g. # Dock: AppName, # NOTE:) — buffer until a real command passes filtering
          if [[ "$_pb_cmd" == "#"* ]]; then
            _pending_comments+=("$_pb_cmd")
            continue
          fi
          [ -n "$_pb_plist_path" ] || continue
          # Filter noisy key paths in PlistBuddy commands
          is_noisy_pbcmd "$dom" "$_pb_cmd" && continue
          # Emit domain-level note before first non-filtered command (using tracked array_base)
          if [ "$_domain_note_emitted" = "false" ]; then
            _emit_contextual_note "$dom" "$_last_array_base"
            _domain_note_emitted=true
          fi
          # Flush buffered comments now that we have a real command
          if (( ${#_pending_comments[@]} > 0 )); then
            for _pc in "${_pending_comments[@]}"; do
              log_line "Cmd: $_pc"
            done
            _pending_comments=()
          fi
          local _mdm_path=$(mdm_plist_path "$_pb_plist_path")
          local pb_full="/usr/libexec/PlistBuddy -c '${_pb_cmd}' \"${_mdm_path}\""
          log_line "Cmd: $pb_full"
          continue
        fi
        # Metadata line: populate _skip_keys and track array_base for deferred note
        _last_array_base="$_array_base"
        _skip_keys["$_array_base"]=1
        if [ -n "$_array_idx" ]; then
          _skip_keys[":${_array_base}:${_array_idx}"]=1
        fi
        if [ -n "$_array_keys" ]; then
          typeset -a _array_key_list
          IFS=',' read -rA _array_key_list <<< "$_array_keys"
          for _k in "${_array_key_list[@]}"; do
            [ -n "$_k" ] || continue
            _k=$(printf '%s' "$_k" | /usr/bin/sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
            [ -n "$_k" ] || continue
            _skip_keys["$_k"]=1
            _skip_keys["${_array_base}:${_k}"]=1
            _skip_keys[":${_array_base}:${_k}"]=1
            if [ -n "$_array_idx" ]; then
              _skip_keys["${_array_base}:${_array_idx}:${_k}"]=1
              _skip_keys[":${_array_base}:${_array_idx}:${_k}"]=1
            fi
          done
        fi
      done <<< "$_array_meta_raw"
    fi
  fi

  if [ -s "$prev" ]; then
    # Pre-collect keys from + lines to identify value changes (not deletions)
    typeset -A _added_keys
    _added_keys=()
    while IFS= read -r _aline; do
      local _ak
      _ak=$(printf '%s' "$_aline" | /usr/bin/sed -nE 's/^\+[[:space:]]*"([^"]+)".*/\1/p')
      [ -n "$_ak" ] && _added_keys["$_ak"]=1
    done < <(/usr/bin/diff -u "$prev" "$curr" 2>/dev/null | /usr/bin/awk 'NR>2 && $0 ~ /^\+/ && $0 !~ /^\+\+\+/')

    typeset -A _noted_dom=()

    # Use process substitution (not pipe) so _skip_keys is accessible in while loop
    while IFS= read -r dline; do
      [ -n "$dline" ] || continue
      log_line "Diff $dom: $dline"

      local kv keyname val snippet pretty_key array_meta="" array_name="" array_idx="" array_cmd=""
      kv=$(printf '%s' "$dline" | /usr/bin/sed -nE 's/^[+-][[:space:]]*"([^"]+)"[[:space:]]*=>[[:space:]]*(.*)$/\1|\2/p')
      if [ -n "$kv" ]; then
        keyname="${kv%%|*}"
        val="${kv#*|}"

        if [ -n "${_skip_keys[$keyname]:-}" ]; then
          continue
        fi

        # Additional filtering: if we had array additions, skip any top-level key
        # that looks like it's part of a dictionary (contains space or common dict key patterns)
        if [ "$_has_array_additions" = "true" ] && [[ "$keyname" != *":"* ]]; then
          # Skip keys that are likely dictionary sub-keys (contain spaces or match common patterns)
          if [[ "$keyname" == *" "* ]] || [[ "$keyname" =~ ^(InputSourceKind|KeyboardLayout|tile-data|file-data|file-label|bundle-identifier|_CFURLString).*$ ]]; then
            continue
          fi
        fi

        if is_noisy_key "$dom" "$keyname"; then
          continue
        fi

        if array_meta=$(parse_array_index_key "$keyname" 2>/dev/null); then
          array_name="${array_meta%% *}"
          array_idx="${array_meta##* }"
          pretty_key="${array_name}[${array_idx}]"
        else
          pretty_key="$keyname"
        fi

        snippet=$(printf '%s' "$val" | /usr/bin/tr '\n' ' ' | /usr/bin/awk '{s=$0; if(length(s)>160) {print substr(s,1,157) "..."} else {print s}}')
        log_line "Key: ${pretty_key} | Item: ${snippet}"

        case "$dline" in
          +*)
            if [ -n "$array_name" ]; then
              continue
            fi
            # Skip nested keys (indent ≥ 4 spaces in diff = sub-dict values)
            if [[ "$dline" =~ ^[+][[:space:]]{4,}\" ]]; then
              continue
            fi

            local trimmed type_val str noquotes cmd
            trimmed=$(printf '%s' "$val" | /usr/bin/sed -E 's/^[[:space:]]+|[[:space:]]+$//g')

            # Check actual plist type first to avoid misdetection (e.g., float "1" detected as bool/int)
            local actual_type=""
            actual_type=$(/usr/bin/defaults read-type "$dom" "$keyname" 2>/dev/null | /usr/bin/awk '{print $NF}') || actual_type=""

            # Use actual plist type when available for numeric/bool values to avoid misdetection
            if [ "$actual_type" = "float" ]; then
              cmd="defaults write ${dom} \"${keyname}\" -float ${trimmed}"
            elif [ "$actual_type" = "integer" ]; then
              cmd="defaults write ${dom} \"${keyname}\" -int ${trimmed}"
            elif [ "$actual_type" = "boolean" ]; then
              type_val=$( [ "$trimmed" = "1" ] || [ "$trimmed" = "true" ] && echo TRUE || echo FALSE )
              cmd="defaults write ${dom} \"${keyname}\" -bool ${type_val}"
            elif [[ "$trimmed" =~ ^\".*\"$ ]]; then
              noquotes="${trimmed#\"}"; noquotes="${noquotes%\"}"
              str=$(printf '%s' "$noquotes" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g')
              cmd="defaults write ${dom} \"${keyname}\" -string \"${str}\""
            elif [[ "$trimmed" == "true" ]] || [[ "$trimmed" == "false" ]]; then
              type_val=$(printf '%s' "$trimmed" | /usr/bin/tr '[:lower:]' '[:upper:]')
              cmd="defaults write ${dom} \"${keyname}\" -bool ${type_val}"
            elif [[ "$trimmed" == "0" ]] || [[ "$trimmed" == "1" ]]; then
              type_val=$( [ "$trimmed" = "1" ] && echo TRUE || echo FALSE )
              cmd="defaults write ${dom} \"${keyname}\" -bool ${type_val}"
            elif [[ "$trimmed" =~ ^-?[0-9]+$ ]]; then
              cmd="defaults write ${dom} \"${keyname}\" -int ${trimmed}"
            elif [[ "$trimmed" =~ ^-?[0-9]*\.[0-9]+$ ]]; then
              cmd="defaults write ${dom} \"${keyname}\" -float ${trimmed}"
            else
              local plutil_result plutil_type plutil_value
              if [ -f "$tmpplist" ] && plutil_result=$(extract_type_value_with_plutil "$tmpplist" "$keyname" 2>/dev/null); then
                plutil_type="${plutil_result%%|*}"
                plutil_value="${plutil_result#*|}"
                case "$plutil_type" in
                  string) cmd="defaults write ${dom} \"${keyname}\" -string \"${plutil_value}\"" ;;
                  bool) cmd="defaults write ${dom} \"${keyname}\" -bool ${plutil_value}" ;;
                  int) cmd="defaults write ${dom} \"${keyname}\" -int ${plutil_value}" ;;
                  float) cmd="defaults write ${dom} \"${keyname}\" -float ${plutil_value}" ;;
                  array|dict) cmd="" ;;
                  *) cmd="defaults write ${dom} \"${keyname}\" <type> <value>" ;;
                esac
              else
                cmd="defaults write ${dom} \"${keyname}\" <type> <value>"
              fi
            fi

            if [ -n "$cmd" ]; then
              local _cmd_dom
              _cmd_dom=$(printf '%s' "$cmd" | /usr/bin/sed -nE 's/.*defaults[[:space:]]+write[[:space:]]+([^[:space:]]+).*/\1/p')
              if [ -n "$_cmd_dom" ] && is_excluded_domain "$_cmd_dom"; then
                :
              elif is_noisy_command "$cmd"; then
                :
              else
                if [ -z "${_noted_dom[$dom]:-}" ]; then
                  _emit_contextual_note "$dom" ""
                  _noted_dom[$dom]=1
                fi
                if [ "${ALL_MODE:-false}" = "true" ] && [ "${ONLY_CMDS:-false}" = "true" ]; then
                  :
                else
                  log_line "Cmd: $cmd"
                fi
              fi
            fi
            ;;
          -*)
            # Skip nested keys (same logic as + case above)
            if [[ "$dline" =~ ^[-][[:space:]]{4,}\" ]]; then
              continue
            fi
            # Skip value changes (key exists in both - and + lines = changed, not deleted)
            if [ -n "${_added_keys[$keyname]:-}" ]; then
              continue
            fi
            # Skip flat key deletes for print presets (array deletion covers all sub-keys)
            if [[ "$dom" == com.apple.print.custompresets* ]]; then
              continue
            fi
            # Verify key is truly deleted by checking the current snapshot
            # If the key still exists in $curr, it's a value change not a deletion
            if [ -z "$array_name" ] && /usr/bin/grep -qF "\"$keyname\" =>" "$curr" 2>/dev/null; then
              continue
            fi
            local target delete_cmd
            if [ -n "$array_name" ]; then
              target=":${array_name}:${array_idx}"
            else
              target="$keyname"
            fi
            delete_cmd="defaults delete ${dom} \"${target}\""

            if is_noisy_command "$delete_cmd"; then
              :
            elif [ "${ALL_MODE:-false}" = "true" ] && [ "${ONLY_CMDS:-false}" = "true" ]; then
              :
            else
              local pb_delete
              if pb_delete=$(convert_delete_to_plistbuddy "$delete_cmd" 2>/dev/null); then
                while IFS= read -r pb_line; do
                  [ -n "$pb_line" ] || continue
                  if [[ "$pb_line" == "#"* ]]; then
                    log_line "$pb_line"
                  else
                    log_line "Cmd: $pb_line"
                  fi
                done <<< "$pb_delete"
              else
                log_line "Cmd: $delete_cmd"
              fi
            fi
            ;;
        esac
      fi
    done < <(/usr/bin/diff -u "$prev" "$curr" 2>/dev/null | /usr/bin/awk 'NR>2 && ($0 ~ /^\+/ || $0 ~ /^-/) && $0 !~ /^\+\+\+|^---/')
  else
    :
  fi

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
    plist_path="$HOME/Library/Preferences/.GlobalPreferences.plist"
    [ -f "$plist_path" ] && echo "$plist_path" && return 0
  fi

  # Try sandboxed Container first (common for modern apps)
  plist_path="$HOME/Library/Containers/${domain}/Data/Library/Preferences/${domain}.plist"
  [ -f "$plist_path" ] && echo "$plist_path" && return 0

  # Try standard Preferences directory
  plist_path="$HOME/Library/Preferences/${domain}.plist"
  [ -f "$plist_path" ] && echo "$plist_path" && return 0

  # Try ByHost preferences
  plist_path="$HOME/Library/Preferences/ByHost/${domain}."*".plist"
  plist_path=$(/bin/ls $plist_path 2>/dev/null | head -1)
  [ -n "$plist_path" ] && [ -f "$plist_path" ] && echo "$plist_path" && return 0

  # Try Group Containers (for app groups)
  if [ -d "$HOME/Library/Group Containers" ]; then
    plist_path=$(/usr/bin/find "$HOME/Library/Group Containers" -name "${domain}.plist" -type f 2>/dev/null | head -1)
    [ -n "$plist_path" ] && echo "$plist_path" && return 0
  fi

  return 1
}

# Check if Console.app is running
is_console_running() {
  /usr/bin/pgrep -x "Console" >/dev/null 2>/dev/null
}

# Launch Console.app
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

# Start monitoring a specific domain
start_watch() {
  local POLL_PID="" plist_path last_mtime current_mtime

  # Try to find the plist file for optimized mtime monitoring
  plist_path=$(get_plist_path_for_domain "$DOMAIN")

  if [ -n "$plist_path" ]; then
    # Optimized mode: monitor file mtime, only diff when changed
    log_line "Mode: optimized mtime polling (0.5s check on $plist_path)"

    (
      # Take initial baseline snapshot so first user change is detected immediately
      show_domain_diff "$DOMAIN"
      last_mtime=$(stat -f %m "$plist_path" 2>/dev/null || echo "")
      while true; do
        if [ -f "$plist_path" ]; then
          current_mtime=$(stat -f %m "$plist_path" 2>/dev/null || echo "")

          # Only run diff if file has changed
          if [ -n "$current_mtime" ] && [ "$current_mtime" != "$last_mtime" ]; then
            show_domain_diff "$DOMAIN"
            last_mtime="$current_mtime"
          fi
        else
          # File doesn't exist yet, wait for it
          last_mtime=""
        fi
        sleep 0.5  # Check twice per second for responsiveness
      done
    ) &
    POLL_PID=$!
  else
    # Fallback mode: traditional polling for domains without plist file
    log_line "Mode: standard polling (plist not found, checking domain every 1s)"

    (
      while true; do
        show_domain_diff "$DOMAIN"
        sleep 1
      done
    ) &
    POLL_PID=$!
  fi

  trap 'kill -TERM ${POLL_PID:-} 2>/dev/null || true; wait ${POLL_PID:-} 2>/dev/null || true; /bin/rm -rf "$PREFWATCH_TMPDIR" 2>/dev/null || true; exit 0' TERM INT
  wait
}

# Monitor all preferences via fs_usage
start_watch_all() {
  if [ "$(id -u)" -ne 0 ]; then
    log_line "Mode: monitoring ALL preferences (polling only — no root)"
  else
    log_line "Mode: monitoring ALL preferences (fs_usage + polling)"
  fi

  local console_user console_home prefs_user prefs_system
  console_user=$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || echo "")
  prefs_system="/Library/Preferences"

  if [ -n "$console_user" ] && [ "$console_user" != "root" ]; then
    console_home=$(/usr/bin/dscl . -read "/Users/$console_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    [ -z "$console_home" ] && console_home="/Users/$console_user"
    prefs_user="$console_home/Library/Preferences"
  else
    prefs_user="$HOME/Library/Preferences"
  fi

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

  # Initial snapshot
  snapshot_notice "Taking initial baseline — please wait before making changes"
  local _snap_spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local _snap_count=0 _snap_idx=0
  local -a _snap_pids=()
  local _max_parallel=16

  if [ -d "$prefs_user" ]; then
    snapshot_notice "User snapshot: scanning..."
    _snap_count=0
    _snap_pids=()
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      local dom=""
      dom=$(domain_from_plist_path "$f")
      if is_excluded_domain "$dom"; then
        continue
      fi
      _snap_count=$(( _snap_count + 1 ))
      _snap_idx=$(( _snap_count % ${#_snap_spinner[@]} ))
      printf "\r  ${_snap_spinner[$_snap_idx+1]} User snapshot: %d domains scanned..." "$_snap_count"
      snapshot_notice "USER: ${dom:-$f}" true
      _snapshot_one_plist "$f" &
      _snap_pids+=($!)
      if (( ${#_snap_pids[@]} >= _max_parallel )); then
        wait "${_snap_pids[1]}" 2>/dev/null || true
        _snap_pids=("${_snap_pids[@]:1}")
      fi
    done < <(/usr/bin/find "$prefs_user" -type f -name "*.plist" 2>/dev/null)
    for _pid in "${_snap_pids[@]}"; do wait "$_pid" 2>/dev/null || true; done
    printf "\r  ✓ User snapshot: %d domains scanned    \n" "$_snap_count"
    snapshot_notice "User snapshot: completed ($_snap_count domains)"
    SNAPSHOT_READY="true"
  fi

  if [ "$INCLUDE_SYSTEM" = "true" ] && [ -d "$prefs_system" ]; then
    snapshot_notice "System snapshot: scanning..."
    _snap_count=0
    _snap_pids=()
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      local dom=""
      dom=$(domain_from_plist_path "$f")
      if is_excluded_domain "$dom"; then
        continue
      fi
      _snap_count=$(( _snap_count + 1 ))
      _snap_idx=$(( _snap_count % ${#_snap_spinner[@]} ))
      printf "\r  ${_snap_spinner[$_snap_idx+1]} System snapshot: %d domains scanned..." "$_snap_count"
      snapshot_notice "SYSTEM: ${dom:-$f}" true
      _snapshot_one_plist "$f" &
      _snap_pids+=($!)
      if (( ${#_snap_pids[@]} >= _max_parallel )); then
        wait "${_snap_pids[1]}" 2>/dev/null || true
        _snap_pids=("${_snap_pids[@]:1}")
      fi
    done < <(/usr/bin/find "$prefs_system" -type f -name "*.plist" 2>/dev/null)
    for _pid in "${_snap_pids[@]}"; do wait "$_pid" 2>/dev/null || true; done
    printf "\r  ✓ System snapshot: %d domains scanned    \n" "$_snap_count"
    snapshot_notice "System snapshot: completed ($_snap_count domains)"
    SNAPSHOT_READY="true"
  fi

  if [ "${SNAPSHOT_READY:-false}" = "true" ]; then
    snapshot_notice "Initial snapshots processed — you can now make your changes"
    log_line "Cmd: # NOTE: Changes may take a few seconds to appear — wait between actions for reliable capture"
  fi

  # fs_usage monitoring function
  fs_watch() {
    script -q /dev/null /usr/sbin/fs_usage -w -f filesys 2>/dev/null |
    /usr/bin/sed -nE 's@.*(/.*Library/(Group Containers|Containers|Preferences)/.*\.plist).*@\1@p' |
    /usr/bin/awk -v pu="${prefs_user}" -v ps="${prefs_system}" -v incsys="${INCLUDE_SYSTEM}" '{
      path=$0;
      if (index(path, pu)==1)      { print "USER " path }
      else if (index(path, ps)==1) { print "SYSTEM " path }
      else                         { print "OTHER " path }
    }' | while IFS= read -r line; do
      cat_type="${line%% *}"; plist="${line#* }"
      [ -z "$plist" ] && continue
      if [ "$cat_type" = "SYSTEM" ] && [ "${INCLUDE_SYSTEM}" != "true" ]; then
        continue
      fi
      dom=$(domain_from_plist_path "$plist")
      if is_excluded_domain "$dom"; then
        continue
      fi
      if [ "$cat_type" = "USER" ]; then
        log_user "FS change: $plist"; show_plist_diff USER "$plist"; [ -n "$dom" ] && show_domain_diff "$dom" true
      else
        log_system "FS change: $plist"; show_plist_diff SYSTEM "$plist"; [ -n "$dom" ] && show_domain_diff "$dom" true
      fi
    done
  }

  # Polling monitoring function
  poll_watch() {
    local marker_user marker_sys
    marker_user="$PREFWATCH_TMPDIR/poll.marker.user"
    marker_sys="$PREFWATCH_TMPDIR/poll.marker.sys"
    # Only create markers if not pre-initialized (avoids rescanning all plists after initial snapshot)
    [ -f "$marker_user" ] || /usr/bin/touch "$marker_user" 2>/dev/null || true
    [ -f "$marker_sys" ]  || /usr/bin/touch "$marker_sys" 2>/dev/null || true

    while true; do
      if [ -d "$prefs_user" ]; then
        /usr/bin/find "$prefs_user" -type f -name "*.plist" -newer "$marker_user" 2>/dev/null | while IFS= read -r f; do
          [ -n "$f" ] || continue
          dom=$(domain_from_plist_path "$f")
          if is_excluded_domain "$dom"; then
            continue
          fi
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
      /bin/sleep 1
    done
  }

  # CUPS printer monitoring function
  cups_watch() {
    local cups_snapshot cups_current
    cups_snapshot="$PREFWATCH_TMPDIR/cups.snap"
    cups_current="$PREFWATCH_TMPDIR/cups.curr"

    # Initial snapshot of installed printers
    /usr/bin/lpstat -a 2>/dev/null | /usr/bin/awk '{print $1}' | /usr/bin/sort > "$cups_snapshot" 2>/dev/null || true

    while true; do
      /bin/sleep 2
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

        # Extract URI
        local uri=""
        uri=$(/usr/bin/lpstat -v "$printer" 2>/dev/null | /usr/bin/sed -nE 's/.*:[[:space:]]+(.*)/\1/p')

        # Extract non-default options
        local opts=""
        opts=$(/usr/bin/lpoptions -p "$printer" 2>/dev/null | /usr/bin/tr ' ' '\n' | /usr/bin/grep -E '^(media|sides|print-color-mode|print-quality|printer-is-shared)=' | while IFS= read -r o; do printf " -o %s" "$o"; done)

        # Build lpadmin command
        local cmd="lpadmin -p \"$printer\""
        [ -n "$uri" ] && cmd="$cmd -v \"$uri\""
        cmd="$cmd -m everywhere -E${opts}"
        log_line "Cmd: $cmd"
      done

      # Detect removed printers
      /usr/bin/comm -23 "$cups_snapshot" "$cups_current" 2>/dev/null | while IFS= read -r printer; do
        [ -z "$printer" ] && continue
        log_line "Cmd: # CUPS: printer removed — $printer"
        log_line "Cmd: lpadmin -x \"$printer\""
      done

      # Update snapshot
      /bin/cp -f "$cups_current" "$cups_snapshot" 2>/dev/null || true
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
        local snap_parsed curr_parsed
        snap_parsed=$(/usr/bin/awk '/^[A-Z]/{sec=$0; sub(/:$/,"",sec); next} NF>=2{val=$NF; key=""; for(i=1;i<NF;i++){if(i>1)key=key" "; key=key$i}; gsub(/^[[:space:]]+|[[:space:]]+$/,"",key); print sec "|" key "|" val}' "$pmset_snapshot")
        curr_parsed=$(/usr/bin/awk '/^[A-Z]/{sec=$0; sub(/:$/,"",sec); next} NF>=2{val=$NF; key=""; for(i=1;i<NF;i++){if(i>1)key=key" "; key=key$i}; gsub(/^[[:space:]]+|[[:space:]]+$/,"",key); print sec "|" key "|" val}' "$pmset_current")

        # Find changed or added settings in current
        while IFS='|' read -r section key val; do
          [ -z "$key" ] && continue
          local old_val=""
          old_val=$(printf '%s\n' "$snap_parsed" | /usr/bin/grep "^${section}|${key}|" | /usr/bin/cut -d'|' -f3)
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
          log_line "Cmd: pmset ${flag} ${key} ${val}"
        done <<< "$curr_parsed"
      fi

      # Update snapshot
      /bin/cp -f "$pmset_current" "$pmset_snapshot" 2>/dev/null || true
    done
  }

  # Pre-initialize poll markers so first iteration only sees post-snapshot changes
  /usr/bin/touch "$PREFWATCH_TMPDIR/poll.marker.user" 2>/dev/null || true
  /usr/bin/touch "$PREFWATCH_TMPDIR/poll.marker.sys" 2>/dev/null || true

  # Start all mechanisms
  local FS_PID=""
  if [ "$(id -u)" -eq 0 ]; then
    fs_watch &
    FS_PID=$!
  fi
  poll_watch &
  local POLL_PID=$!
  cups_watch &
  local CUPS_PID=$!
  pmset_watch &
  local PMSET_PID=$!

  trap 'kill -TERM ${FS_PID:-} $POLL_PID $CUPS_PID $PMSET_PID 2>/dev/null || true; wait ${FS_PID:-} $POLL_PID $CUPS_PID $PMSET_PID 2>/dev/null || true; /bin/rm -rf "$PREFWATCH_TMPDIR" 2>/dev/null || true; exit 0' TERM INT
  wait
}

# ============================================================================
# MAIN
# ============================================================================

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

# Python3 status — in ALL mode, require Python or prompt user
if [ -n "$PYTHON3_BIN" ]; then
  log_line "Python3: $PYTHON3_BIN (array change detection enabled)"
elif [ "$ALL_MODE" = "true" ] && [ "$JAMF_MODE" != "true" ]; then
  printf "WARNING: Xcode Command Line Tools not installed — Python3 unavailable\n"
  printf "Without Python3: array/dict changes and PlistBuddy commands will not be detected\n"
  printf "For full detection, install Xcode CLT:\n"
  printf "  xcode-select --install\n"
  printf "\n"
  printf "Continue with limited detection? (y/n) "
  read -r _py_answer </dev/tty 2>/dev/null || _py_answer="y"
  case "$_py_answer" in
    [Yy]*) printf "Continuing with limited detection — only simple key changes will be reported\n" ;;
    *)
      printf "Install Command Line Tools first, then re-run PrefWatch:\n"
      printf "  xcode-select --install\n"
      exit 1
      ;;
  esac
else
  log_line "WARNING: ${_py_warn:-Python3 not available}"
  log_line "TIP: Run 'xcode-select --install' to enable array change detection"
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
  log_line "NOTE: $DOMAIN is normally excluded in ALL mode, but monitoring as explicitly requested"
fi

# Try to open Console.app
launch_console

# Start monitoring in background
if [ "$ALL_MODE" = "true" ]; then
  start_watch_all &
else
  start_watch &
fi
WATCH_PID=$!

if is_console_running; then
  while is_console_running; do
    sleep 1
  done
  log_line "Console.app closed — stopping monitoring"
  kill -TERM "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  exit 0
else
  log_line "Console not detected — continuing monitoring (Ctrl+C to stop)"
  wait "$WATCH_PID" 2>/dev/null || true
  exit 0
fi
