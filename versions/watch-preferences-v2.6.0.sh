#!/bin/zsh
# ============================================================================
# Script: watch-preferences.sh
# Version: 2.6.0
# Description: Monitor and log changes to macOS preference domains
# ============================================================================
# Usage:
#
# CLI Mode (direct execution):
#   ./watch-preferences.sh [domain] [OPTIONS]
#
#   Arguments:
#     [domain]              Preference domain (default: "ALL")
#                           Examples: com.apple.dock, com.apple.finder, ALL
#
#   Options:
#     -l, --log <path>      Custom log file path (default: auto-generated)
#     -s, --include-system  Include system preferences in ALL mode (default)
#     --no-system           Exclude system preferences in ALL mode
#     -v, --verbose         Show detailed debug output with timestamps
#     -q, --only-cmds       Show only executable commands (default)
#     -e, --exclude <glob>  Comma-separated glob patterns to exclude
#     -h, --help            Show this help message
#
#   Examples:
#     ./watch-preferences.sh                    # Monitor ALL (default)
#     ./watch-preferences.sh -v                 # Monitor ALL verbose
#     ./watch-preferences.sh --log /tmp/all.log # Monitor ALL with custom log
#     ./watch-preferences.sh com.apple.dock     # Monitor specific domain
#     ./watch-preferences.sh com.apple.finder -v # Specific domain verbose
#
# Jamf Pro Mode (automatic detection):
#   When run via Jamf Pro, parameters are automatically shifted.
#   $1-$3 are Jamf reserved (mount_point, computer_name, username)
#
#   Jamf Parameters:
#     $4 = Domain (e.g., com.apple.finder, ALL or *)
#     $5 = Log path (optional). Default:
#          - ALL: /var/log/preferences.watch.log
#          - Domain: /var/log/<domain>.prefs.log
#     $6 = INCLUDE_SYSTEM (true/false) — include system preferences (default: true)
#     $7 = ONLY_CMDS (true/false) — show only commands without debug (default: true)
#     $8 = EXCLUDE_DOMAINS — comma-separated glob patterns to exclude
#          Example: ContextStoreAgent*,com.jamf*,com.adobe.*
# ============================================================================

# ============================================================================
# SECTION 1: CONFIGURATION & SECURITY
# ============================================================================

# Execution security (zsh)
set -e
set -u
set -o pipefail

# Help message
show_help() {
  cat << 'EOF'
Usage: watch-preferences.sh [domain] [OPTIONS]

Monitor and log changes to macOS preference domains in real-time.

Arguments:
  [domain]              Preference domain to monitor (default: "ALL")
                        Examples: com.apple.dock, com.apple.finder, ALL

Options:
  -l, --log <path>      Custom log file path (default: auto-generated)
  -s, --include-system  Include system preferences in ALL mode (default: enabled)
  --no-system           Exclude system preferences in ALL mode
  -v, --verbose         Show detailed debug output with timestamps
  -q, --only-cmds       Show only executable commands (default)
  -e, --exclude <glob>  Comma-separated glob patterns to exclude
  -h, --help            Show this help message

Examples:
  # Monitor all domains (default behavior)
  ./watch-preferences.sh
  ./watch-preferences.sh -v
  ./watch-preferences.sh --log /tmp/all-prefs.log

  # Monitor a specific domain
  ./watch-preferences.sh com.apple.dock
  ./watch-preferences.sh com.apple.finder -v

  # Monitor with exclusions
  ./watch-preferences.sh -v --exclude "com.apple.Safari*,ContextStoreAgent*"

  # Monitor without system preferences
  ./watch-preferences.sh --no-system

Jamf Pro Mode:
  When run via Jamf Pro, use positional parameters:
    $4 = Domain
    $5 = Log path
    $6 = INCLUDE_SYSTEM (true/false)
    $7 = ONLY_CMDS (true/false)
    $8 = EXCLUDE_DOMAINS

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

# If ONLY_CMDS is active, disable any inherited xtrace (noisy "kv=…")
if [ "${ONLY_CMDS:-false}" = "true" ]; then
  set +x 2>/dev/null || true
  unsetopt xtrace 2>/dev/null || true
fi

# Default exclusions (glob patterns), comma-separated
EXCLUDE_DOMAINS_RAW="${EXCLUDE_DOMAINS:-ContextStoreAgent*,com.bjango.istatmenus.status,com.apple.systempreferences,com.apple.systemsettings.extensions,com.apple.CrashReporter,com.apple.CloudKit,com.apple.DuetExpertCenter.AppPredictionExpert,com.jamf*,com.jamfsoftware*,com.launchdarkly*,com.apple.loginwindow,com.apple.Console,com.apple.knowledge-agent,com.apple.spaces,com.apple.networkextension,com.apple.xpc.activity2,com.apple.cfprefsd.daemon,com.apple.notificationcenterui,com.apple.Spotlight,com.apple.CoreGraphics,com.apple.Safari.SafeBrowsing,com.apple.LaunchServices,com.apple.bird,com.apple.cloudd,com.apple.security*,com.apple.appstored,com.apple.dock.extra}"

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

# Log file configuration
if [ -n "$LOG_FILE_PARAM" ]; then
  LOGFILE="$LOG_FILE_PARAM"
else
  if [ "$ALL_MODE" = "true" ]; then
    LOGFILE="/var/log/preferences.watch.log"
  else
    LOGFILE="/var/log/${DOMAIN}.prefs.log"
  fi
fi

# Console user (to target active user preferences)
get_console_user() {
  /usr/bin/stat -f %Su /dev/console 2>/dev/null || /usr/bin/id -un
}
CONSOLE_USER="${CONSOLE_USER:-$(get_console_user)}"

# Execution prefix as console user if script runs as root
RUN_AS_USER=()
if [ "$(id -u)" -eq 0 ] && [ "$CONSOLE_USER" != "root" ]; then
  RUN_AS_USER=(/usr/bin/sudo -u "$CONSOLE_USER" -H)
fi

# Optimization: Detect date binary at startup
HAVE_BIN_DATE="false"
[ -x /bin/date ] && HAVE_BIN_DATE="true"

# Python3 detection
PYTHON3_BIN=""
if command -v /usr/bin/python3 >/dev/null 2>&1; then
  PYTHON3_BIN="/usr/bin/python3"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON3_BIN="$(command -v python3)"
fi

# Cache for optimizing repeated exclusion checks
typeset -A _EXCLUSION_CACHE

# Cache for plist diffs (WATCH_ALL)
CACHE_DIR=""

DOMAIN_TAG="$DOMAIN"
[ "$ALL_MODE" = "true" ] && DOMAIN_TAG="all"

# ============================================================================
# SECTION 2: BASIC UTILITY FUNCTIONS
# ============================================================================

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
    printf '%s' "~/Library/Preferences/${domain}.plist"
  fi
}

# Derive a "defaults" domain from a .plist path
domain_from_plist_path() {
  local p="$1" base dom
  base="$(/usr/bin/basename "$p")"
  dom="${base%.plist}"
  printf '%s\n' "$dom" | /usr/bin/sed -E 's/\.[0-9A-Fa-f-]{8,}$//' || printf '%s\n' "$dom"
}

# Hash a path for cache file naming
hash_path() {
  local p="$1"
  if command -v /sbin/md5 >/dev/null 2>&1; then
    /sbin/md5 -qs "$p" 2>/dev/null || echo "$p" | /usr/bin/cksum | awk '{print $1}'
  else
    echo "$p" | /usr/bin/cksum | awk '{print $1}'
  fi
}

# Initialize cache directory
init_cache() {
  if [ -z "$CACHE_DIR" ]; then
    CACHE_DIR=$(/usr/bin/mktemp -d "/tmp/watchprefs-cache.${$}.XXXXXX") || CACHE_DIR="/tmp/watchprefs-cache.${$}"
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

# ============================================================================
# SECTION 3: FILTERING & EXCLUSION FUNCTIONS
# ============================================================================

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

# Filter noisy keys (internal metadata)
is_noisy_key() {
  local domain="$1" keyname="$2"
  if [ "$domain" = "com.apple.dock" ]; then
    case "$keyname" in
      parent-mod-date|file-mod-date|mod-count|file-label|file-type)
        return 0
        ;;
    esac
  fi
  return 1
}

# Filter non-useful defaults commands
is_noisy_command() {
  local cmd="$1"

  # Filter invalid commands with <type> <value>
  if printf '%s' "$cmd" | /usr/bin/grep -q '<type> <value>'; then
    return 0
  fi

  # Filter commands with -float (timestamps, positions, etc.)
  if printf '%s' "$cmd" | /usr/bin/grep -q '\-float'; then
    return 0
  fi

  # Filter known keys that change frequently
  case "$cmd" in
    *"NSWindow Frame"*|*"NSToolbar Configuration"*|*"NSNavPanel"*|*"NSSplitView"*)
      return 0
      ;;
  esac

  return 1
}

# ============================================================================
# SECTION 4: LOGGING FUNCTIONS
# ============================================================================

# General log
log_line() {
  local msg="$1"
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

    if printf '%s' "$out" | /usr/bin/grep -Eq 'defaults[[:space:]]+write[[:space:]]+'; then
      local _cmd_dom
      _cmd_dom=$(printf '%s' "$out" | /usr/bin/sed -nE 's/.*defaults[[:space:]]+write[[:space:]]+([^[:space:]]+).*/\1/p')
      if [ -n "$_cmd_dom" ] && is_excluded_domain "$_cmd_dom"; then
        return 0
      fi
    fi

    printf "%s\n" "$out"
    printf "%s\n" "$out" >> "$LOGFILE" 2>/dev/null || true
    /usr/bin/logger -t "watch-preferences[$DOMAIN_TAG]" -- "$out"
    return 0
  fi

  local line="[$ts] $msg"
  if printf '%s' "$msg" | /usr/bin/grep -Eq '(Cmd: |CMD: )?defaults[[:space:]]+write[[:space:]]+'; then
    local _raw _cmd_dom
    _raw=$(printf '%s' "$msg" | /usr/bin/sed -E 's/^(Cmd: |CMD: )//')
    _cmd_dom=$(printf '%s' "$_raw" | /usr/bin/sed -nE 's/.*defaults[[:space:]]+write[[:space:]]+([^[:space:]]+).*/\1/p')
    if [ -n "$_cmd_dom" ] && is_excluded_domain "$_cmd_dom"; then
      return 0
    fi
  fi

  printf "%s\n" "$line"
  printf "%s\n" "$line" >> "$LOGFILE" 2>/dev/null || true
  /usr/bin/logger -t "watch-preferences[$DOMAIN_TAG]" -- "$msg"
}

# User log
log_user() {
  local msg="$1"; local ts
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

    if printf '%s' "$out" | /usr/bin/grep -Eq 'defaults[[:space:]]+write[[:space:]]+'; then
      local _cmd_dom
      _cmd_dom=$(printf '%s' "$out" | /usr/bin/sed -nE 's/.*defaults[[:space:]]+write[[:space:]]+([^[:space:]]+).*/\1/p')
      if [ -n "$_cmd_dom" ] && is_excluded_domain "$_cmd_dom"; then
        return 0
      fi
    fi

    printf "%s\n" "$out"
    printf "%s\n" "$out" >> "$LOGFILE" 2>/dev/null || true
    /usr/bin/logger -t "watch-preferences[user]" -- "$out"
    return 0
  fi

  local line="[$ts] $msg"
  if printf '%s' "$msg" | /usr/bin/grep -Eq '(Cmd: |CMD: )?defaults[[:space:]]+write[[:space:]]+'; then
    local _raw _cmd_dom
    _raw=$(printf '%s' "$msg" | /usr/bin/sed -E 's/^(Cmd: |CMD: )//')
    _cmd_dom=$(printf '%s' "$_raw" | /usr/bin/sed -nE 's/.*defaults[[:space:]]+write[[:space:]]+([^[:space:]]+).*/\1/p')
    if [ -n "$_cmd_dom" ] && is_excluded_domain "$_cmd_dom"; then
      return 0
    fi
  fi

  printf "%s\n" "$line"
  printf "%s\n" "$line" >> "$LOGFILE" 2>/dev/null || true
  /usr/bin/logger -t "watch-preferences[user]" -- "$msg"
}

# System log
log_system() {
  local msg="$1"; local ts
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

    if printf '%s' "$out" | /usr/bin/grep -Eq 'defaults[[:space:]]+write[[:space:]]+'; then
      local _cmd_dom
      _cmd_dom=$(printf '%s' "$out" | /usr/bin/sed -nE 's/.*defaults[[:space:]]+write[[:space:]]+([^[:space:]]+).*/\1/p')
      if [ -n "$_cmd_dom" ] && is_excluded_domain "$_cmd_dom"; then
        return 0
      fi
    fi

    printf "%s\n" "$out"
    printf "%s\n" "$out" >> "$LOGFILE" 2>/dev/null || true
    /usr/bin/logger -t "watch-preferences[system]" -- "$out"
    return 0
  fi

  local line="[$ts] $msg"
  if printf '%s' "$msg" | /usr/bin/grep -Eq '(Cmd: |CMD: )?defaults[[:space:]]+write[[:space:]]+'; then
    local _raw _cmd_dom
    _raw=$(printf '%s' "$msg" | /usr/bin/sed -E 's/^(Cmd: |CMD: )//')
    _cmd_dom=$(printf '%s' "$_raw" | /usr/bin/sed -nE 's/.*defaults[[:space:]]+write[[:space:]]+([^[:space:]]+).*/\1/p')
    if [ -n "$_cmd_dom" ] && is_excluded_domain "$_cmd_dom"; then
      return 0
    fi
  fi

  printf "%s\n" "$line"
  printf "%s\n" "$line" >> "$LOGFILE" 2>/dev/null || true
  /usr/bin/logger -t "watch-preferences[system]" -- "$msg"
}

# Snapshot log
snapshot_notice() {
  local msg="$1"; local ts
  ts="$([ -x /bin/date ] && /bin/date '+%Y-%m-%d %H:%M:%S' || date '+%Y-%m-%d %H:%M:%S')"
  local line="[$ts] [snapshot] $msg"
  printf "%s\n" "$line"
  printf "%s\n" "$line" >> "$LOGFILE" 2>/dev/null || true
  /usr/bin/logger -t "watch-preferences[snapshot]" -- "$msg"
}

# ============================================================================
# SECTION 5: PLIST MANIPULATION FUNCTIONS
# ============================================================================

# Stable text output of a plist
dump_plist() {
  local src="$1" out="$2"
  if /usr/bin/plutil -p "$src" >/dev/null 2>&1; then
    /usr/bin/plutil -p "$src" > "$out" 2>/dev/null || /bin/cat "$src" > "$out" 2>/dev/null || :
  else
    /bin/cat "$src" > "$out" 2>/dev/null || :
  fi
}

# JSON output of a plist
dump_plist_json() {
  local src="$1" out="$2"
  if [ -f "$src" ]; then
    if /usr/bin/plutil -convert json -o "$out" "$src" 2>/dev/null; then
      :
    else
      : > "$out" 2>/dev/null || true
    fi
  else
    : > "$out" 2>/dev/null || true
  fi
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

# Extract domain from a defaults write command
extract_domain_from_defaults_cmd() {
  local text="$1"
  local domain
  domain=$(printf '%s' "$text" | /usr/bin/sed -nE 's/.*defaults([[:space:]]+-[^[:space:]]+)*[[:space:]]+write([[:space:]]+-[^[:space:]]+)*[[:space:]]+["]?([^"[:space:]]+).*/\3/p')
  [ -z "$domain" ] && domain=$(printf '%s' "$text" | /usr/bin/sed -nE "s/.*defaults([[:space:]]+-[^[:space:]]+)*[[:space:]]+write([[:space:]]+-[^[:space:]]+)*[[:space:]]+'([^'[:space:]]+)'.*/\\3/p")
  printf '%s' "$domain"
}

# ============================================================================
# SECTION 6: PLISTBUDDY CONVERSION FUNCTIONS
# ============================================================================

# Convert a defaults write -array-add command to PlistBuddy
convert_to_plistbuddy() {
  local cmd="$1"

  local domain key payload
  domain=$(printf '%s' "$cmd" | /usr/bin/sed -nE 's/defaults write ([^ ]+) .*/\1/p')
  key=$(printf '%s' "$cmd" | /usr/bin/sed -nE 's/defaults write [^ ]+ "([^"]+)" .*/\1/p')
  payload=$(printf '%s' "$cmd" | /usr/bin/sed -nE "s/.*-array-add '(.*)'/\1/p")

  [ -n "$domain" ] || return 1
  [ -n "$key" ] || return 1
  [ -n "$payload" ] || return 1

  local plist_path
  plist_path="$(get_plist_path "$domain")"

  local inside="${payload#\{ }"
  inside="${inside% \}}"

  local -a pb_cmds
  local parsing="$inside"

  while [ -n "$parsing" ]; do
    local dict_key dict_value
    dict_key=$(printf '%s' "$parsing" | /usr/bin/sed -nE 's/^[[:space:]]*"([^"]+)"[[:space:]]*=.*/\1/p')

    if [ -z "$dict_key" ]; then
      break
    fi

    dict_value=$(printf '%s' "$parsing" | /usr/bin/sed -nE 's/^[[:space:]]*"[^"]+"[[:space:]]*=[[:space:]]*([^;]+);.*/\1/p')

    if [ -z "$dict_value" ]; then
      break
    fi

    dict_value=$(printf '%s' "$dict_value" | /usr/bin/sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

    local value_type="string"
    if printf '%s' "$dict_value" | /usr/bin/grep -Eq '^[0-9]+$'; then
      value_type="integer"
    elif printf '%s' "$dict_value" | /usr/bin/grep -Eq '^(YES|NO)$'; then
      value_type="bool"
    elif printf '%s' "$dict_value" | /usr/bin/grep -Eq '^".*"$'; then
      dict_value="${dict_value#\"}"
      dict_value="${dict_value%\"}"
      value_type="string"
    fi

    pb_cmds+=("/usr/libexec/PlistBuddy -c 'Add :${key}:\$INDEX:${dict_key} ${value_type} ${dict_value}' \"${plist_path}\"")

    parsing=$(printf '%s' "$parsing" | /usr/bin/sed -E 's/^[[:space:]]*"[^"]+"[[:space:]]*=[[:space:]]*[^;]+;//')
  done

  if [ "${#pb_cmds[@]}" -gt 0 ]; then
    printf '%s\n' "${pb_cmds[@]}"
  fi
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
  if printf '%s' "$target" | /usr/bin/grep -Eq ':[^:]+:[0-9]+$'; then
    is_array_deletion=true
  fi

  if [ "$is_array_deletion" = "true" ]; then
    printf '# WARNING: Array deletion - indexes change after each deletion\n'
    printf '# For multiple deletions: execute from HIGHEST index to LOWEST\n'
  fi
  printf '/usr/libexec/PlistBuddy -c '\''Delete %s'\'' "%s"\n' "$target" "$plist_path"
  return 0
}

# ============================================================================
# SECTION 7: ARRAY OPERATIONS FUNCTIONS
# ============================================================================

# Parse an array index key (:AppleEnabledInputSources:3 -> AppleEnabledInputSources 3)
parse_array_index_key() {
  local raw="$1"
  if [[ "$raw" == :*:* ]]; then
    local inner="${raw#:}"
    local base="${inner%%:*}"
    local idx="${inner##*:}"
    if [[ -n "$base" && "$idx" == <-> ]]; then
      printf '%s %s\n' "$base" "$idx"
      return 0
    fi
  fi
  return 1
}

# Generate an array-add command for an array element
array_add_command() {
  local dom="$1" colon_key="$2"
  local parsed base idx json payload
  [ -n "$PYTHON3_BIN" ] || return 1

  if ! parsed=$(parse_array_index_key "$colon_key"); then
    return 1
  fi

  base="${parsed%% *}"
  idx="${parsed##* }"
  json=$("${RUN_AS_USER[@]}" /usr/bin/defaults export "$dom" - 2>/dev/null | /usr/bin/plutil -convert json -o - - 2>/dev/null) || return 1
  [ -n "$json" ] || return 1

  payload=$(printf '%s' "$json" | "$PYTHON3_BIN" - "$base" "$idx" <<'PY'
import json, sys
array_name = sys.argv[1]
index = int(sys.argv[2])
data = json.load(sys.stdin)
entry = None
if array_name in data and isinstance(data[array_name], list):
    arr = data[array_name]
    if 0 <= index < len(arr):
        entry = arr[index]
if entry is None:
    alt_key = f":{array_name}:{index}"
    entry = data.get(alt_key)
if entry is None:
    sys.exit(1)
def fmt_value(val):
    if isinstance(val, str):
        return '"' + val.replace('\\', '\\\\').replace('"', '\\"') + '"'
    if isinstance(val, bool):
        return 'YES' if val else 'NO'
    if isinstance(val, (int, float)):
        return str(val)
    if val is None:
        return '""'
    return '"' + str(val).replace('\\', '\\\\').replace('"', '\\"') + '"'
parts = []
for key, value in entry.items():
    escaped_key = '"' + key.replace('\\', '\\\\').replace('"', '\\"') + '"'
    parts.append(f'{escaped_key} = {fmt_value(value)};')
payload = '{ ' + ' '.join(parts) + ' }'
print(payload)
PY
) || return 1

  payload=$(printf '%s' "$payload" | /usr/bin/tr '\n' ' ' | /usr/bin/sed -E 's/[[:space:]]+/ /g')
  [ -n "$payload" ] || return 1
  printf "defaults write %s \"%s\" -array-add '%s'\n" "$dom" "$base" "$payload"
  return 0
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

def diff(prev_obj, curr_obj, path):
    if isinstance(curr_obj, dict):
        prev_dict = prev_obj if isinstance(prev_obj, dict) else {}
        for key, value in curr_obj.items():
            diff(prev_dict.get(key), value, path + [key])
    elif isinstance(curr_obj, list):
        prev_list = prev_obj if isinstance(prev_obj, list) else []
        used = [False] * len(prev_list)
        for idx, item in enumerate(curr_obj):
            matched = False
            for prev_idx, prev_item in enumerate(prev_list):
                if not used[prev_idx] and prev_item == item:
                    used[prev_idx] = True
                    matched = True
                    break
            if not matched:
                results.append((tuple(path), idx, item))
    else:
        return

def escape_string(value: str) -> str:
    return value.replace('\\', '\\\\').replace('"', '\\"')

def shell_escape_single(value: str) -> str:
    return value.replace("'", "'\"'\"'")

def format_value(obj):
    if isinstance(obj, str):
        return '"' + escape_string(obj) + '"'
    if isinstance(obj, bool):
        return 'YES' if obj else 'NO'
    if isinstance(obj, (int, float)) and not isinstance(obj, bool):
        return str(obj)
    if obj is None:
        return '""'
    if isinstance(obj, dict):
        parts = []
        for key, value in obj.items():
            parts.append('"' + escape_string(str(key)) + '" = ' + format_value(value) + ';')
        return '{ ' + ' '.join(parts) + ' }'
    if isinstance(obj, list):
        return '(' + ', '.join(format_value(item) for item in obj) + ')'
    return '"' + escape_string(str(obj)) + '"'

def build_command(array_name, index, item):
    if not isinstance(item, dict):
        return ''
    payload = format_value(item)
    payload = shell_escape_single(payload)
    escaped_array = escape_string(str(array_name))
    return f"defaults write {domain} \"{escaped_array}\" -array-add '{payload}'"

diff(prev, curr, [])

for prefix, index, item in results:
    if len(prefix) != 1:
        continue
    if not isinstance(item, dict):
        continue
    keys = ','.join(sorted(str(k) for k in item.keys()))
    command = build_command(prefix[0], index, item)
    if not command:
        continue
    print(f"{prefix[0]}\t{index}\t{keys}\t{command}")
PY
) || return 0

  [ -n "$py_output" ] || return 0

  local outputs=()
  while IFS=$'\t' read -r base idx keylist cmd; do
    [ -n "$base" ] || continue
    if [ -n "$cmd" ]; then
      if is_noisy_command "$cmd"; then
        :
      elif [ "$kind" = "DOMAIN" ] && [ "${ALL_MODE:-false}" = "true" ] && [ "${ONLY_CMDS:-false}" = "true" ]; then
        :
      else
        case "$kind" in
          USER) log_user "Cmd: $cmd" ;;
          SYSTEM) log_system "Cmd: $cmd" ;;
          DOMAIN) log_line "Cmd: $cmd" ;;
          *) log_line "Cmd: $cmd" ;;
        esac

        local pb_cmds_output
        if pb_cmds_output=$(convert_to_plistbuddy "$cmd" 2>/dev/null); then
          while IFS= read -r pb_line; do
            [ -n "$pb_line" ] || continue
            case "$kind" in
              USER) log_user "Cmd: $pb_line" ;;
              SYSTEM) log_system "Cmd: $pb_line" ;;
              DOMAIN) log_line "Cmd: $pb_line" ;;
              *) log_line "Cmd: $pb_line" ;;
            esac
          done <<< "$pb_cmds_output"
        fi
      fi
    fi
    outputs+=("$base\t$idx\t${keylist}")
  done <<< "$py_output"

  if [ "${#outputs[@]}" -gt 0 ]; then
    printf '%s\n' "${outputs[@]}"
  fi
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

def diff_deletions(prev_obj, curr_obj, path):
    """Find deleted elements by comparing prev with curr"""
    if isinstance(prev_obj, dict):
        curr_dict = curr_obj if isinstance(curr_obj, dict) else {}
        for key, value in prev_obj.items():
            diff_deletions(value, curr_dict.get(key), path + [key])
    elif isinstance(prev_obj, list):
        curr_list = curr_obj if isinstance(curr_obj, list) else []
        used = [False] * len(curr_list)
        for prev_idx, prev_item in enumerate(prev_obj):
            matched = False
            for curr_idx, curr_item in enumerate(curr_list):
                if not used[curr_idx] and prev_item == curr_item:
                    used[curr_idx] = True
                    matched = True
                    break
            if not matched:
                results.append((tuple(path), prev_idx, prev_item))
    else:
        return

diff_deletions(prev, curr, [])

for path_tuple, index, item in results:
    if not path_tuple:
        continue
    array_name = path_tuple[-1] if path_tuple else ""
    if isinstance(item, dict):
        keys = ','.join(str(k) for k in item.keys())
    else:
        keys = ""
    print(f"{array_name}\t{index}\t{keys}")
PY
) || return 0

  [ -n "$py_output" ] || return 0

  while IFS=$'\t' read -r base idx keylist; do
    [ -n "$base" ] || continue

    local delete_cmd="defaults delete ${dom} \":${base}:${idx}\""

    if is_noisy_command "$delete_cmd"; then
      :
    elif [ "$kind" = "DOMAIN" ] && [ "${ALL_MODE:-false}" = "true" ] && [ "${ONLY_CMDS:-false}" = "true" ]; then
      :
    else
      case "$kind" in
        USER) log_user "Cmd: $delete_cmd" ;;
        SYSTEM) log_system "Cmd: $delete_cmd" ;;
        DOMAIN) log_line "Cmd: $delete_cmd" ;;
        *) log_line "Cmd: $delete_cmd" ;;
      esac

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
      fi
    fi
  done <<< "$py_output"
}

# ============================================================================
# SECTION 8: DIFF & COMPARISON FUNCTIONS
# ============================================================================

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

  dump_plist "$path" "$curr"
  dump_plist_json "$path" "$curr_json"

  typeset -A _skip_keys
  _skip_keys=()
  local _array_meta_raw=""

  if [ "$silent" != "true" ] && [ -n "$PYTHON3_BIN" ] && [ -s "$prev_json" ] && [ -s "$curr_json" ]; then
    _array_meta_raw=$(emit_array_additions "$kind" "$_dom" "$prev_json" "$curr_json") || _array_meta_raw=""
    if [ -n "$_array_meta_raw" ]; then
      while IFS=$'\t' read -r _array_base _array_idx _array_keys; do
        [ -n "$_array_base" ] || continue
        _skip_keys["$_array_base"]=1
        if [ -n "$_array_idx" ]; then
          _skip_keys[":${_array_base}:${_array_idx}"]=1
        fi
        if [ -n "$_array_keys" ]; then
          typeset -a _array_key_list
          IFS=',' read -rA _array_key_list <<< "$_array_keys"
          for _k in "${_array_key_list[@]}"; do
            [ -n "$_k" ] || continue
            _skip_keys["$_k"]=1
          done
        fi
      done <<< "$_array_meta_raw"
    fi

    emit_array_deletions "$kind" "$_dom" "$prev_json" "$curr_json"
  fi

  if [ -s "$prev" ] && [ "$silent" != "true" ]; then
    /usr/bin/diff -u "$prev" "$curr" 2>/dev/null | /usr/bin/awk 'NR>2 && ($0 ~ /^\+/ || $0 ~ /^-/) && $0 !~ /^\+\+\+|^---/' |
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
            local base dom hostflag cmd trimmed type_val noquotes str
            base="$(/usr/bin/basename "$path")"
            dom="${base%.plist}"
            hostflag=""
            if printf '%s' "$path" | /usr/bin/grep -q "/ByHost/"; then
              hostflag="-currentHost"
              dom="$(printf '%s' "$dom" | /usr/bin/sed -E 's/\.[0-9A-Fa-f-]{8,}$//')"
            fi
            trimmed=$(printf '%s' "$val" | /usr/bin/sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
            if printf '%s' "$trimmed" | /usr/bin/grep -Eq '^".*"$'; then
              noquotes="${trimmed#\"}"; noquotes="${noquotes%\"}"
              str=$(printf '%s' "$noquotes" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g')
              cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-string \"${str}\""
            elif printf '%s' "$trimmed" | /usr/bin/grep -Eq '^(true|false)$'; then
              type_val=$(printf '%s' "$trimmed" | /usr/bin/tr '[:lower:]' '[:upper:]')
              cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-bool ${type_val}"
            elif printf '%s' "$trimmed" | /usr/bin/grep -Eq '^(0|1)$'; then
              type_val=$( [ "$trimmed" = "1" ] && echo TRUE || echo FALSE )
              cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-bool ${type_val}"
            elif printf '%s' "$trimmed" | /usr/bin/grep -Eq '^-?[0-9]+$'; then
              cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-int ${trimmed}"
            elif printf '%s' "$trimmed" | /usr/bin/grep -Eq '^-?[0-9]*\.[0-9]+$'; then
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
                  array|dict) cmd="# Complex type ($plutil_type): defaults write ${dom} \"${keyname}\" - see plist" ;;
                  *) cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }<type> <value>" ;;
                esac
              else
                cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }<type> <value>"
              fi
            fi

            local _cmd_dom
            _cmd_dom=$(printf '%s' "$cmd" | /usr/bin/sed -nE 's/.*defaults[[:space:]]+write[[:space:]]+([^[:space:]]+).*/\1/p')
            if [ -n "$_cmd_dom" ] && is_excluded_domain "$_cmd_dom"; then
              :
            elif is_noisy_command "$cmd"; then
              :
            else
              if [ "$kind" = "USER" ]; then
                log_user "Cmd: $cmd"
              else
                log_system "Cmd: $cmd"
              fi
            fi
            ;;
          -*)
            if /usr/bin/grep -F -- "\"$keyname\"" "$curr" >/dev/null 2>&1; then
              continue
            fi
            local base dom hostflag target delete_cmd
            base="$(/usr/bin/basename "$path")"
            dom="${base%.plist}"
            hostflag=""
            if printf '%s' "$path" | /usr/bin/grep -q "/ByHost/"; then
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
              log_user "Cmd: $delete_cmd"
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
              fi
            else
              log_system "Cmd: $delete_cmd"
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
              fi
            fi
            ;;
        esac
      fi
    done
  else
    :
  fi

  /bin/mv -f "$curr" "$prev" 2>/dev/null || /bin/cp -f "$curr" "$prev" 2>/dev/null || :
  /bin/mv -f "$curr_json" "$prev_json" 2>/dev/null || /bin/cp -f "$curr_json" "$prev_json" 2>/dev/null || :
}

# Domain diff (text export)
show_domain_diff() {
  local dom="$1"

  if is_excluded_domain "$dom"; then
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
    /usr/bin/plutil -convert json -o "$curr_json" "$tmpplist" 2>/dev/null || : > "$curr_json" 2>/dev/null || true
  else
    : > "$curr" 2>/dev/null || true
    curr_json="$CACHE_DIR/${key}.curr.json"
    : > "$curr_json" 2>/dev/null || true
  fi

  prev_json="$CACHE_DIR/${key}.prev.json"
  typeset -A _skip_keys
  _skip_keys=()
  local _array_meta_raw=""

  if [ -n "$PYTHON3_BIN" ] && [ -s "$prev_json" ] && [ -s "$curr_json" ]; then
    _array_meta_raw=$(emit_array_additions DOMAIN "$dom" "$prev_json" "$curr_json") || _array_meta_raw=""
    emit_array_deletions DOMAIN "$dom" "$prev_json" "$curr_json"

    if [ -n "$_array_meta_raw" ]; then
      while IFS=$'\t' read -r _array_base _array_idx _array_keys; do
        [ -n "$_array_base" ] || continue
        _skip_keys["$_array_base"]=1
        if [ -n "$_array_idx" ]; then
          _skip_keys[":${_array_base}:${_array_idx}"]=1
        fi
        if [ -n "$_array_keys" ]; then
          typeset -a _array_key_list
          IFS=',' read -rA _array_key_list <<< "$_array_keys"
          for _k in "${_array_key_list[@]}"; do
            [ -n "$_k" ] || continue
            _skip_keys["$_k"]=1
          done
        fi
      done <<< "$_array_meta_raw"
    fi
  fi

  if [ -s "$prev" ]; then
    /usr/bin/diff -u "$prev" "$curr" 2>/dev/null | /usr/bin/awk 'NR>2 && ($0 ~ /^\+/ || $0 ~ /^-/) && $0 !~ /^\+\+\+|^---/' |
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

            local trimmed type_val str noquotes cmd
            trimmed=$(printf '%s' "$val" | /usr/bin/sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
            if printf '%s' "$trimmed" | /usr/bin/grep -Eq '^".*"$'; then
              noquotes="${trimmed#\"}"; noquotes="${noquotes%\"}"
              str=$(printf '%s' "$noquotes" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g')
              cmd="defaults write ${dom} \"${keyname}\" -string \"${str}\""
            elif printf '%s' "$trimmed" | /usr/bin/grep -Eq '^(true|false)$'; then
              type_val=$(printf '%s' "$trimmed" | /usr/bin/tr '[:lower:]' '[:upper:]')
              cmd="defaults write ${dom} \"${keyname}\" -bool ${type_val}"
            elif printf '%s' "$trimmed" | /usr/bin/grep -Eq '^(0|1)$'; then
              type_val=$( [ "$trimmed" = "1" ] && echo TRUE || echo FALSE )
              cmd="defaults write ${dom} \"${keyname}\" -bool ${type_val}"
            elif printf '%s' "$trimmed" | /usr/bin/grep -Eq '^-?[0-9]+$'; then
              cmd="defaults write ${dom} \"${keyname}\" -int ${trimmed}"
            elif printf '%s' "$trimmed" | /usr/bin/grep -Eq '^-?[0-9]*\.[0-9]+$'; then
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
                  array|dict) cmd="# Complex type ($plutil_type): defaults write ${dom} \"${keyname}\" - see plist" ;;
                  *) cmd="defaults write ${dom} \"${keyname}\" <type> <value>" ;;
                esac
              else
                cmd="defaults write ${dom} \"${keyname}\" <type> <value>"
              fi
            fi

            local _cmd_dom
            _cmd_dom=$(printf '%s' "$cmd" | /usr/bin/sed -nE 's/.*defaults[[:space:]]+write[[:space:]]+([^[:space:]]+).*/\1/p')
            if [ -n "$_cmd_dom" ] && is_excluded_domain "$_cmd_dom"; then
              :
            elif is_noisy_command "$cmd"; then
              :
            else
              if [ "${ALL_MODE:-false}" = "true" ] && [ "${ONLY_CMDS:-false}" = "true" ]; then
                :
              else
                log_line "Cmd: $cmd"
              fi
            fi
            ;;
          -*)
            if /usr/bin/grep -F -- "\"$keyname\"" "$curr" >/dev/null 2>&1; then
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
              log_line "Cmd: $delete_cmd"
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
              fi
            fi
            ;;
        esac
      fi
    done
  else
    :
  fi

  /bin/mv -f "$curr" "$prev" 2>/dev/null || /bin/cp -f "$curr" "$prev" 2>/dev/null || :
  /bin/mv -f "$curr_json" "$prev_json" 2>/dev/null || /bin/cp -f "$curr_json" "$prev_json" 2>/dev/null || :
}

# ============================================================================
# SECTION 9: MONITORING (WATCH) FUNCTIONS
# ============================================================================

# Get the plist file path for a given domain
# Returns the full path to the .plist file, or empty string if not found
get_plist_path_for_domain() {
  local domain="$1"
  local plist_path=""

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
    log_line "Mode: optimized polling (mtime check on $plist_path)"

    (
      last_mtime=""
      while true; do
        if [ -f "$plist_path" ]; then
          current_mtime=$(stat -f %m "$plist_path" 2>/dev/null || echo "")

          # Only run diff if file has changed
          if [ -n "$current_mtime" ] && [ "$current_mtime" != "$last_mtime" ]; then
            if [ -n "$last_mtime" ]; then
              # File changed, run diff
              show_domain_diff "$DOMAIN"
            fi
            last_mtime="$current_mtime"
          fi
        else
          # File doesn't exist yet, wait for it
          last_mtime=""
        fi
        sleep 0.5  # More responsive than 1s, less CPU than constant polling
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

  trap 'kill -TERM ${POLL_PID:-} 2>/dev/null || true; wait ${POLL_PID:-} 2>/dev/null || true; exit 0' TERM INT
  wait
}

# Monitor all preferences via fs_usage
start_watch_all() {
  log_line "Mode: monitoring ALL preferences (fs_usage + polling)"

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

  # Initial snapshot
  if [ -d "$prefs_user" ]; then
    snapshot_notice "Initial user snapshot: starting"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      local dom=""
      dom=$(domain_from_plist_path "$f")
      if is_excluded_domain "$dom"; then
        continue
      fi
      snapshot_notice "Snapshot USER: ${dom:-$f}"
      show_plist_diff USER "$f" silent
    done < <(/usr/bin/find "$prefs_user" -type f -name "*.plist" 2>/dev/null)
    snapshot_notice "Initial user snapshot: completed"
    SNAPSHOT_READY="true"
  fi

  if [ "$INCLUDE_SYSTEM" = "true" ] && [ -d "$prefs_system" ]; then
    snapshot_notice "Initial system snapshot: starting"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      local dom=""
      dom=$(domain_from_plist_path "$f")
      if is_excluded_domain "$dom"; then
        continue
      fi
      snapshot_notice "Snapshot SYSTEM: ${dom:-$f}"
      show_plist_diff SYSTEM "$f" silent
    done < <(/usr/bin/find "$prefs_system" -type f -name "*.plist" 2>/dev/null)
    snapshot_notice "Initial system snapshot: completed"
    SNAPSHOT_READY="true"
  fi

  if [ "${SNAPSHOT_READY:-false}" = "true" ]; then
    snapshot_notice "Initial snapshots processed — you can now make your changes"
  fi

  # fs_usage monitoring function
  fs_watch() {
    local FS_CMD
    FS_CMD=(/usr/sbin/fs_usage -w -f filesys)
    if command -v script >/dev/null 2>&1; then
      script -q /dev/null "${FS_CMD[@]}" 2>/dev/null |
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
          log_user "FS change: $plist"; show_plist_diff USER "$plist"; [ -n "$dom" ] && show_domain_diff "$dom"
        else
          log_system "FS change: $plist"; show_plist_diff SYSTEM "$plist"; [ -n "$dom" ] && show_domain_diff "$dom"
        fi
      done
    else
      /usr/sbin/fs_usage -w -f filesys 2>/dev/null |
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
          log_user "FS change: $plist"; show_plist_diff USER "$plist"; [ -n "$dom" ] && show_domain_diff "$dom"
        else
          log_system "FS change: $plist"; show_plist_diff SYSTEM "$plist"; [ -n "$dom" ] && show_domain_diff "$dom"
        fi
      done
    fi
  }

  # Polling monitoring function
  poll_watch() {
    local marker_user marker_sys
    marker_user=$(/usr/bin/mktemp "/tmp/prefs-user.marker.XXXXXX")
    marker_sys=$(/usr/bin/mktemp "/tmp/prefs-sys.marker.XXXXXX")
    /usr/bin/touch -t 200001010000 "$marker_user" "$marker_sys" 2>/dev/null || true

    while true; do
      local now
      now=$(/usr/bin/mktemp "/tmp/prefs-scan.now.XXXXXX")
      if [ -d "$prefs_user" ]; then
        /usr/bin/find "$prefs_user" -type f -name "*.plist" -newer "$marker_user" 2>/dev/null | while IFS= read -r f; do
          [ -n "$f" ] || continue
          dom=$(domain_from_plist_path "$f")
          if is_excluded_domain "$dom"; then
            continue
          fi
          log_user "POLL change: $f"; show_plist_diff USER "$f"; [ -n "$dom" ] && show_domain_diff "$dom"
        done
      fi
      if [ "${INCLUDE_SYSTEM}" = "true" ] && [ -d "$prefs_system" ] && [ "$(id -u)" -eq 0 ]; then
        /usr/bin/find "$prefs_system" -type f -name "*.plist" -newer "$marker_sys" 2>/dev/null | while IFS= read -r f; do
          [ -n "$f" ] || continue
          dom=$(domain_from_plist_path "$f")
          if is_excluded_domain "$dom"; then
            continue
          fi
          log_system "POLL change: $f"; show_plist_diff SYSTEM "$f"; [ -n "$dom" ] && show_domain_diff "$dom"
        done
      fi
      /bin/mv -f "$now" "$marker_user" 2>/dev/null || /usr/bin/touch "$marker_user" 2>/dev/null || true
      /usr/bin/touch -r "$marker_user" "$marker_sys" 2>/dev/null || true
      /bin/sleep 2
    done
  }

  # Start both mechanisms
  fs_watch &
  local FS_PID=$!
  poll_watch &
  local POLL_PID=$!

  trap 'kill -TERM $FS_PID $POLL_PID 2>/dev/null || true; wait $FS_PID $POLL_PID 2>/dev/null || true; exit 0' TERM INT
  wait
}

# ============================================================================
# SECTION 10: MAIN EXECUTION
# ============================================================================

# Prepare log file
LOGFILE="$(prepare_logfile "$LOGFILE")"

# Announce the actually used log path
if [ "${ONLY_CMDS:-false}" = "true" ]; then
  printf "[init] Log file: %s\n" "$LOGFILE" >> "$LOGFILE" 2>/dev/null || true
else
  { printf "[init] Log file: %s\n" "$LOGFILE"; } | { cat; cat >> "$LOGFILE" 2>/dev/null || true; }
fi
/usr/bin/logger -t "watch-preferences[init]" -- "Log file: $LOGFILE"

if [ "$ALL_MODE" = "true" ]; then
  log_line "Starting: monitoring ALL preferences"
else
  log_line "Starting monitoring on $DOMAIN"
fi

# Stop if domain explicitly excluded (domain mode only)
if [ "$ALL_MODE" != "true" ] && is_excluded_domain "$DOMAIN"; then
  log_line "Domain excluded by default: $DOMAIN — stopping monitoring"
  exit 0
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
