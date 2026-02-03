#!/bin/zsh
# Nom: watch-preferences.sh
# Description: Observe et logge les changements d'un domaine de préférences macOS
# Version: 2.3.0
# Paramètres Jamf:
#   $4 = Domaine (ex: com.apple.finder, ALL ou *)
#   $5 = Chemin du log (fichier unique). Défaut:
#        - ALL/*: /var/log/preferences.watch.log
#        - Domaine: /var/log/<domaine>.prefs.log
#   $6 = INCLUDE_SYSTEM (true/false) — en mode ALL, inclure les préférences système (défaut: true)
#   $7 = ONLY_CMDS (true/false) — filtre pour n'afficher que les commandes utiles (defaults, PlistBuddy, plutil) sans messages de debug (défaut: true)
#   $8 = EXCLUDE_DOMAINS — liste d'exclusions (glob) séparées par des virgules
#        Exemple: ContextStoreAgent*,com.jamf*,com.jamfsoftware*,com.launchdarkly*
#   $9 = EXCLUDE_COMMANDS — motifs (glob) des domaines defaults à ignorer
#        Exemple: com.jamf*,com.jamfsoftware*,ContextStoreAgent*,com.launchdarkly*,com.adobe.*

# Sécurisation exécution (zsh)
set -e
set -u
set -o pipefail

# Paramètres Jamf / défauts
DOMAIN="${4:-ALL}"
# ONLY_CMDS peut être passé en env var (ONLY_CMDS=1) ou en $7
ONLY_CMDS_RAW="${ONLY_CMDS:-${7:-true}}"
INCLUDE_SYSTEM_RAW="${6:-true}"

# Normalisation booléenne
to_bool() {
  case "$(printf "%s" "${1:-}" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on|enable|enabled|oui|vrai) echo "true";;
    *) echo "false";;
  esac
}
ONLY_CMDS=$(to_bool "$ONLY_CMDS_RAW")
INCLUDE_SYSTEM=$(to_bool "$INCLUDE_SYSTEM_RAW")

# Si ONLY_CMDS est actif, désactive un éventuel xtrace hérité (bruit "kv=…")
if [ "${ONLY_CMDS:-false}" = "true" ]; then
  set +x 2>/dev/null || true
  unsetopt xtrace 2>/dev/null || true
fi

# Exclusions par défaut (glob), séparées par des virgules. Surcharges via env EXCLUDE_DOMAINS ou $8.
EXCLUDE_DOMAINS_RAW="${EXCLUDE_DOMAINS:-${8:-ContextStoreAgent*,com.jamf*,com.jamfsoftware*,com.launchdarkly*,com.apple.loginwindow,com.apple.Console,com.apple.knowledge-agent,com.apple.spaces,com.apple.networkextension,com.apple.xpc.activity2}}"
typeset -a EXCLUDE_PATTERNS _raw_excl
IFS=',' read -rA _raw_excl <<< "$EXCLUDE_DOMAINS_RAW"
EXCLUDE_PATTERNS=()
for p in "${_raw_excl[@]}"; do
  # Trim des espaces autour des motifs
  p=$(printf '%s' "$p" | /usr/bin/sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  [ -n "$p" ] && EXCLUDE_PATTERNS+=("$p")
done

# Motifs d'exclusion pour les commandes defaults (override via env EXCLUDE_COMMANDS ou $9)
EXCLUDE_COMMANDS_RAW="${EXCLUDE_COMMANDS:-${9:-com.jamf*,com.jamfsoftware*,ContextStoreAgent*,com.launchdarkly*,com.adobe.*}}"
typeset -a EXCLUDE_DEFAULTS_PATTERNS _raw_cmd_excl
IFS=',' read -rA _raw_cmd_excl <<< "$EXCLUDE_COMMANDS_RAW"
EXCLUDE_DEFAULTS_PATTERNS=()
for p in "${_raw_cmd_excl[@]}"; do
  p=$(printf '%s' "$p" | /usr/bin/sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  [ -n "$p" ] && EXCLUDE_DEFAULTS_PATTERNS+=("$p")
done

is_excluded_domain() {
  local d="$1" p
  for p in "${EXCLUDE_PATTERNS[@]}"; do
    [[ -z "$p" ]] && continue
    # En zsh, utiliser ${~p} pour interpréter la valeur comme motif glob
    if [[ "$d" == ${~p} ]]; then
      return 0
    fi
  done
  return 1
}

# Détecte les commandes defaults visant les domaines exclus (com.jamf*, ContextStoreAgent)
is_excluded_defaults_cmd() {
  local text="$1"
  # Détecte la présence d'une commande defaults write
  if printf '%s' "$text" | /usr/bin/grep -Eq 'defaults([[:space:]]+-[^[:space:]]+)*[[:space:]]+write'; then
    local domain
    domain=$(printf '%s' "$text" | /usr/bin/sed -nE 's/.*defaults([[:space:]]+-[^[:space:]]+)*[[:space:]]+write([[:space:]]+-[^[:space:]]+)*[[:space:]]+["]?([^"[:space:]]+).*/\3/p')
    [ -z "$domain" ] && domain=$(printf '%s' "$text" | /usr/bin/sed -nE "s/.*defaults([[:space:]]+-[^[:space:]]+)*[[:space:]]+write([[:space:]]+-[^[:space:]]+)*[[:space:]]+'([^'[:space:]]+)'.*/\\3/p")
    if [ -n "$domain" ]; then
      local dom_lower=${domain:l} pat
      for pat in "${EXCLUDE_DEFAULTS_PATTERNS[@]}"; do
        [[ -z "$pat" ]] && continue
        local pat_lower=${pat:l}
        if [[ "$dom_lower" == ${~pat_lower} ]]; then
          return 0
        fi
      done
    else
      local lower
      lower=$(printf '%s' "$text" | /usr/bin/tr '[:upper:]' '[:lower:]')
      for pat in "${EXCLUDE_DEFAULTS_PATTERNS[@]}"; do
        [[ -z "$pat" ]] && continue
        local pat_lower=${pat:l}
        if [[ "$lower" == *${~pat_lower}* ]]; then
          return 0
        fi
      done
    fi
  fi
  return 1
}

# Filtre les clés bruyantes (metadata interne) qui ne sont pas des modifications utilisateur intentionnelles
is_noisy_key() {
  local domain="$1" keyname="$2"
  # Filtres spécifiques au Dock: clés de metadata interne
  if [ "$domain" = "com.apple.dock" ]; then
    case "$keyname" in
      parent-mod-date|file-mod-date|mod-count|file-label|file-type)
        return 0  # C'est une clé bruyante, ignorer
        ;;
    esac
  fi
  return 1  # Pas une clé bruyante, la garder
}

# Filtre les commandes defaults non utiles (valeurs qui changent trop souvent)
is_noisy_command() {
  local cmd="$1"

  # Filtre les commandes invalides avec <type> <value>
  if printf '%s' "$cmd" | /usr/bin/grep -q '<type> <value>'; then
    return 0  # Commande invalide, ignorer
  fi

  # Filtre les commandes avec -float (timestamps, positions, etc.)
  if printf '%s' "$cmd" | /usr/bin/grep -q '\-float'; then
    return 0  # C'est une commande bruyante, ignorer
  fi

  # Filtre les clés connues qui changent souvent
  case "$cmd" in
    *"NSWindow Frame"*|*"NSToolbar Configuration"*|*"NSNavPanel"*|*"NSSplitView"*)
      return 0  # Positions/configurations de fenêtres, ignorer
      ;;
  esac

  return 1  # Pas une commande bruyante, la garder
}

# Extrait le type et la valeur d'une clé avec plutil (pour types complexes)
extract_type_value_with_plutil() { # extract_type_value_with_plutil <plist_path> <key>
  local plist="$1" key="$2"
  local type value

  # Extraire la valeur en JSON pour analyse
  local json_value
  json_value=$(/usr/bin/plutil -extract "$key" json -o - "$plist" 2>/dev/null) || return 1

  # Déterminer le type basé sur le JSON
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
    # Extraire la chaîne sans les guillemets JSON et échapper
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

convert_to_plistbuddy() { # convert_to_plistbuddy <defaults_command>
  local cmd="$1"

  # Extrait le domaine, la clé et le payload du defaults write -array-add
  local domain key payload
  domain=$(printf '%s' "$cmd" | /usr/bin/sed -nE 's/defaults write ([^ ]+) .*/\1/p')
  key=$(printf '%s' "$cmd" | /usr/bin/sed -nE 's/defaults write [^ ]+ "([^"]+)" .*/\1/p')
  payload=$(printf '%s' "$cmd" | /usr/bin/sed -nE "s/.*-array-add '(.*)'/\1/p")

  [ -n "$domain" ] || return 1
  [ -n "$key" ] || return 1
  [ -n "$payload" ] || return 1

  # Détermine le chemin du plist
  local plist_path
  if [[ "$domain" =~ ^/ ]]; then
    # Chemin absolu
    plist_path="$domain"
  elif [[ "$domain" == /Library/* ]]; then
    # Préférence système
    plist_path="$domain"
  else
    # Préférence utilisateur
    plist_path="~/Library/Preferences/${domain}.plist"
  fi

  # Génère les commandes PlistBuddy
  local pb_commands=""
  pb_commands+="# Alternative PlistBuddy (plus robuste pour dictionnaires complexes):\n"
  pb_commands+="/usr/libexec/PlistBuddy -c 'Add :${key}: dict' \"${plist_path}\" 2>/dev/null\n"

  # Parse le payload pour extraire les paires clé-valeur
  # Format: { "key1" = value1; "key2" = value2; }
  local inside="${payload#\{ }"
  inside="${inside% \}}"

  # Compte les éléments pour obtenir l'index du nouveau dict
  pb_commands+="# Obtenir l'index du dernier élément ajouté:\n"
  pb_commands+="# INDEX=\$(/usr/libexec/PlistBuddy -c 'Print :${key}' \"${plist_path}\" 2>/dev/null | grep -c 'Dict')\n"
  pb_commands+="# INDEX=\$((INDEX - 1))\n"
  pb_commands+="# Puis pour chaque clé du dictionnaire:\n"

  # Parse les paires clé-valeur
  local parsing="$inside"
  while [[ -n "$parsing" ]]; do
    # Extrait la prochaine paire "key" = value;
    if [[ "$parsing" =~ \"([^\"]+)\"\ *=\ *([^;]+)\; ]]; then
      local dict_key="${BASH_REMATCH[1]}"
      local dict_value="${BASH_REMATCH[2]}"

      # Nettoie la valeur
      dict_value=$(printf '%s' "$dict_value" | /usr/bin/sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

      # Détermine le type de la valeur
      local value_type="string"
      if [[ "$dict_value" =~ ^[0-9]+$ ]]; then
        value_type="integer"
      elif [[ "$dict_value" =~ ^(YES|NO)$ ]]; then
        value_type="bool"
      elif [[ "$dict_value" =~ ^\".*\"$ ]]; then
        # String avec quotes
        dict_value="${dict_value#\"}"
        dict_value="${dict_value%\"}"
        value_type="string"
      fi

      pb_commands+="/usr/libexec/PlistBuddy -c 'Add :${key}:\$INDEX:${dict_key} ${value_type} ${dict_value}' \"${plist_path}\"\n"

      # Retire cette paire du parsing
      parsing="${parsing#*;}"
      parsing=$(printf '%s' "$parsing" | /usr/bin/sed -E 's/^[[:space:]]+//')
    else
      break
    fi
  done

  printf '%b' "$pb_commands"
  return 0
}

# Mode ALL si le domaine vaut 'ALL' ou '*'
ALL_MODE="false"
case "${DOMAIN}" in
  ALL|all|'*') ALL_MODE="true" ;;
esac

# Fichier de log unique
if [ -n "${5:-}" ]; then
  LOGFILE="${5}"
else
  if [ "$ALL_MODE" = "true" ]; then
    LOGFILE="/var/log/preferences.watch.log"
  else
    LOGFILE="/var/log/${DOMAIN}.prefs.log"
  fi
fi

# Utilisateur console (pour cibler les préférences utilisateur actives)
get_console_user() {
  /usr/bin/stat -f %Su /dev/console 2>/dev/null || /usr/bin/id -un
}
CONSOLE_USER="${CONSOLE_USER:-$(get_console_user)}"

# Préfixe d'exécution en tant qu'utilisateur console si le script tourne en root
RUN_AS_USER=()
if [ "$(id -u)" -eq 0 ] && [ "$CONSOLE_USER" != "root" ]; then
  RUN_AS_USER=(/usr/bin/sudo -u "$CONSOLE_USER" -H)
fi

# Prépare les fichiers de log (séparés en mode WATCH_ALL)
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

LOGFILE="$(prepare_logfile "$LOGFILE")"

DOMAIN_TAG="$DOMAIN"
[ "$ALL_MODE" = "true" ] && DOMAIN_TAG="all"

# Annonce le chemin de log effectivement utilisé (utile si fallback /tmp)
if [ "${ONLY_CMDS:-false}" = "true" ]; then
  printf "[init] Log file: %s\n" "$LOGFILE" >> "$LOGFILE" 2>/dev/null || true
else
  { printf "[init] Log file: %s\n" "$LOGFILE"; } | { cat; cat >> "$LOGFILE" 2>/dev/null || true; }
fi
/usr/bin/logger -t "watch-preferences[init]" -- "Log file: $LOGFILE"

log_line() {
  local msg="$1"
  local ts
  ts="$([ -x /bin/date ] && /bin/date '+%Y-%m-%d %H:%M:%S' || date '+%Y-%m-%d %H:%M:%S')"
  # Mode filtré: n'affiche/log que les commandes (sans horodatage)
  if [ "${ONLY_CMDS:-false}" = "true" ]; then
    local out
    case "$msg" in
      Cmd:\ *) out="${msg#Cmd: }" ;;
      CMD:\ *) out="${msg#CMD: }" ;;
      *) return 0 ;;
    esac
    # Garde-fou global: supprime les commandes Jamf
    if is_excluded_defaults_cmd "$out"; then
      return 0
    fi
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
    # Affiche en console et append dans le fichier (sans tee pour éviter des anomalies d'écriture)
    printf "%s\n" "$out"
    printf "%s\n" "$out" >> "$LOGFILE" 2>/dev/null || true
    /usr/bin/logger -t "watch-preferences[$DOMAIN_TAG]" -- "$out"
    return 0
  fi
  # Console (stdout) + fichier
  local line="[$ts] $msg"
  # Garde-fou global: si une ligne contient une commande defaults write Jamf ou domaine exclu, ne pas logguer
  if is_excluded_defaults_cmd "$msg"; then
    return 0
  fi
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
  # App Console (Unified Log)
  /usr/bin/logger -t "watch-preferences[$DOMAIN_TAG]" -- "$msg"
}

log_user() {
  local msg="$1"; local ts
  ts="$([ -x /bin/date ] && /bin/date '+%Y-%m-%d %H:%M:%S' || date '+%Y-%m-%d %H:%M:%S')"
  if [ "${ONLY_CMDS:-false}" = "true" ]; then
    local out
    case "$msg" in
      Cmd:\ *) out="${msg#Cmd: }" ;;
      CMD:\ *) out="${msg#CMD: }" ;;
      *) return 0 ;;
    esac
    if is_excluded_defaults_cmd "$out"; then
      return 0
    fi
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
  if is_excluded_defaults_cmd "$msg"; then
    return 0
  fi
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

log_system() {
  local msg="$1"; local ts
  ts="$([ -x /bin/date ] && /bin/date '+%Y-%m-%d %H:%M:%S' || date '+%Y-%m-%d %H:%M:%S')"
  if [ "${ONLY_CMDS:-false}" = "true" ]; then
    local out
    case "$msg" in
      Cmd:\ *) out="${msg#Cmd: }" ;;
      CMD:\ *) out="${msg#CMD: }" ;;
      *) return 0 ;;
    esac
    if is_excluded_defaults_cmd "$out"; then
      return 0
    fi
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
  if is_excluded_defaults_cmd "$msg"; then
    return 0
  fi
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

snapshot_notice() {
  local msg="$1"; local ts
  ts="$([ -x /bin/date ] && /bin/date '+%Y-%m-%d %H:%M:%S' || date '+%Y-%m-%d %H:%M:%S')"
  local line="[$ts] [snapshot] $msg"
  printf "%s\n" "$line"
  printf "%s\n" "$line" >> "$LOGFILE" 2>/dev/null || true
  /usr/bin/logger -t "watch-preferences[snapshot]" -- "$msg"
}

# Cache pour diffs de plist (WATCH_ALL)
CACHE_DIR=""
init_cache() {
  if [ -z "$CACHE_DIR" ]; then
    CACHE_DIR=$(/usr/bin/mktemp -d "/tmp/watchprefs-cache.${$}.XXXXXX") || CACHE_DIR="/tmp/watchprefs-cache.${$}"
    /bin/mkdir -p "$CACHE_DIR" 2>/dev/null || true
  fi
}

# Déduire un domaine "defaults" depuis un chemin .plist
domain_from_plist_path() {
  local p="$1" base dom
  base="$(/usr/bin/basename "$p")"
  dom="${base%.plist}"
  # Retire suffixe UUID éventuel (ByHost)
  printf '%s\n' "$dom" | /usr/bin/sed -E 's/\.[0-9A-Fa-f-]{8,}$//' || printf '%s\n' "$dom"
}

# Sortie textuelle stable d'un plist (sans modifier le fichier)
dump_plist() { # dump_plist <path> <out>
  local src="$1" out="$2"
  if /usr/bin/plutil -p "$src" >/dev/null 2>&1; then
    /usr/bin/plutil -p "$src" > "$out" 2>/dev/null || /bin/cat "$src" > "$out" 2>/dev/null || :
  else
    /bin/cat "$src" > "$out" 2>/dev/null || :
  fi
}

dump_plist_json() { # dump_plist_json <path> <out>
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

hash_path() { # hash_path <path>
  local p="$1"
  if command -v /sbin/md5 >/dev/null 2>&1; then
    /sbin/md5 -qs "$p" 2>/dev/null || echo "$p" | /usr/bin/cksum | awk '{print $1}'
  else
    echo "$p" | /usr/bin/cksum | awk '{print $1}'
  fi
}

PYTHON3_BIN=""
if command -v /usr/bin/python3 >/dev/null 2>&1; then
  PYTHON3_BIN="/usr/bin/python3"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON3_BIN="$(command -v python3)"
fi

parse_array_index_key() { # :AppleEnabledInputSources:3 -> AppleEnabledInputSources 3
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

array_add_command() { # array_add_command <domain> <colon_key>
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

emit_array_additions() { # emit_array_additions <kind> <domain> <prev_json> <curr_json>
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
      # Filtre les commandes bruyantes
      if is_noisy_command "$cmd"; then
        :
      elif [ "$kind" = "DOMAIN" ] && [ "${ALL_MODE:-false}" = "true" ] && [ "${ONLY_CMDS:-false}" = "true" ]; then
        :
      else
        # Log la commande defaults write -array-add
        case "$kind" in
          USER) log_user "Cmd: $cmd" ;;
          SYSTEM) log_system "Cmd: $cmd" ;;
          DOMAIN) log_line "Cmd: $cmd" ;;
          *) log_line "Cmd: $cmd" ;;
        esac
        # Génère et log l'alternative PlistBuddy
        local pb_alt
        if pb_alt=$(convert_to_plistbuddy "$cmd" 2>/dev/null); then
          case "$kind" in
            USER) log_user "$pb_alt" ;;
            SYSTEM) log_system "$pb_alt" ;;
            DOMAIN) log_line "$pb_alt" ;;
            *) log_line "$pb_alt" ;;
          esac
        fi
      fi
    fi
    outputs+=("$base\t$idx\t${keylist}")
  done <<< "$py_output"
  if [ "${#outputs[@]}" -gt 0 ]; then
    printf '%s\n' "${outputs[@]}"
  fi
}

show_plist_diff() { # show_plist_diff <USER|SYSTEM> <plist_path> [silent]
  local kind="$1" path="$2" mode="${3:-normal}" silent="false"
  [ "$mode" = "silent" ] && silent="true"
  [ -f "$path" ] || return 0
  # Filtre par domaine
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
  fi

  if [ -s "$prev" ] && [ "$silent" != "true" ]; then
    # Affiche uniquement les lignes +/- (ignore l'entête diff)
    /usr/bin/diff -u "$prev" "$curr" 2>/dev/null | /usr/bin/awk 'NR>2 && ($0 ~ /^\+/ || $0 ~ /^-/) && $0 !~ /^\+\+\+|^---/' |
    while IFS= read -r dline; do
      [ -n "$dline" ] || continue
      # Log de la ligne de diff brute
      if [ "$kind" = "USER" ]; then
        log_user "Diff $path: $dline"
      else
        log_system "Diff $path: $dline"
      fi
      # Extraction de la clé et d'un aperçu de valeur quand possible
      # Forme attendue (plutil -p):  "Key" => <val>
      local kv keyname val snippet pretty_key array_meta="" array_name="" array_idx="" array_cmd=""
      kv=$(printf '%s' "$dline" | /usr/bin/sed -nE 's/^[+-][[:space:]]*"([^"]+)"[[:space:]]*=>[[:space:]]*(.*)$/\1|\2/p')
      if [ -n "$kv" ]; then
        keyname="${kv%%|*}"
        val="${kv#*|}"
        if [ -n "${_skip_keys[$keyname]:-}" ]; then
          continue
        fi
        # Filtre les clés bruyantes (metadata interne)
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
        # Raccourcit la valeur pour console
        snippet=$(printf '%s' "$val" | /usr/bin/tr '\n' ' ' | /usr/bin/awk '{s=$0; if(length(s)>160) {print substr(s,1,157) "..."} else {print s}}')
        if [ "$kind" = "USER" ]; then
          log_user "Key: ${pretty_key} | Item: ${snippet}"
        else
          log_system "Key: ${pretty_key} | Item: ${snippet}"
        fi
        # Génère une commande defaults pour la nouvelle valeur ('+' seulement)
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
              # Tentative d'extraction avec plutil pour types complexes
              local plutil_result plutil_type plutil_value
              if plutil_result=$(extract_type_value_with_plutil "$path" "$keyname" 2>/dev/null); then
                plutil_type="${plutil_result%%|*}"
                plutil_value="${plutil_result#*|}"
                case "$plutil_type" in
                  string) cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-string \"${plutil_value}\"" ;;
                  bool) cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-bool ${plutil_value}" ;;
                  int) cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-int ${plutil_value}" ;;
                  float) cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }-float ${plutil_value}" ;;
                  array|dict) cmd="# Type complexe ($plutil_type): defaults write ${dom} \"${keyname}\" - voir plist" ;;
                  *) cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }<type> <value>" ;;
                esac
              else
                cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }<type> <value>"
              fi
            fi
            # Filtre simple: ne log jamais les commandes defaults write com.jamf*
            if is_excluded_defaults_cmd "$cmd"; then
              :
            else
              # Filtre final de sûreté: ne log pas de commande si le domaine est exclu
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
            else
              log_system "Cmd: $delete_cmd"
            fi
            ;;
        esac
      fi
    done
  else
    # Snapshot initial: ne rien afficher ni générer; on initialise seulement l'état de référence.
    :
  fi
  /bin/mv -f "$curr" "$prev" 2>/dev/null || /bin/cp -f "$curr" "$prev" 2>/dev/null || :
  /bin/mv -f "$curr_json" "$prev_json" 2>/dev/null || /bin/cp -f "$curr_json" "$prev_json" 2>/dev/null || :
}

# Diff du domaine (export texte)
show_domain_diff() { # show_domain_diff <domain>
  local dom="$1"
  # Filtre par domaine
  if is_excluded_domain "$dom"; then
    return 0
  fi
  init_cache
  local key prev curr tmpplist prev_json curr_json
  key=$(hash_path "domain:${CONSOLE_USER}:${dom}")
  prev="$CACHE_DIR/${key}.prev"
  curr="$CACHE_DIR/${key}.curr"
  tmpplist="$CACHE_DIR/${key}.plist}"
  # Export brut du domaine vers un fichier puis rendu texte stable
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
      # Extraction clé + valeur (aperçu)
      local kv keyname val snippet pretty_key array_meta="" array_name="" array_idx="" array_cmd=""
      kv=$(printf '%s' "$dline" | /usr/bin/sed -nE 's/^[+-][[:space:]]*"([^"]+)"[[:space:]]*=>[[:space:]]*(.*)$/\1|\2/p')
      if [ -n "$kv" ]; then
        keyname="${kv%%|*}"
        val="${kv#*|}"
        if [ -n "${_skip_keys[$keyname]:-}" ]; then
          continue
        fi
        # Filtre les clés bruyantes (metadata interne)
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
            # Construit la commande defaults pour la nouvelle valeur
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
              # Tentative d'extraction avec plutil pour types complexes
              local plutil_result plutil_type plutil_value
              if [ -f "$tmpplist" ] && plutil_result=$(extract_type_value_with_plutil "$tmpplist" "$keyname" 2>/dev/null); then
                plutil_type="${plutil_result%%|*}"
                plutil_value="${plutil_result#*|}"
                case "$plutil_type" in
                  string) cmd="defaults write ${dom} \"${keyname}\" -string \"${plutil_value}\"" ;;
                  bool) cmd="defaults write ${dom} \"${keyname}\" -bool ${plutil_value}" ;;
                  int) cmd="defaults write ${dom} \"${keyname}\" -int ${plutil_value}" ;;
                  float) cmd="defaults write ${dom} \"${keyname}\" -float ${plutil_value}" ;;
                  array|dict) cmd="# Type complexe ($plutil_type): defaults write ${dom} \"${keyname}\" - voir plist" ;;
                  *) cmd="defaults write ${dom} \"${keyname}\" <type> <value>" ;;
                esac
              else
                cmd="defaults write ${dom} \"${keyname}\" <type> <value>"
              fi
            fi
            # Filtre simple: ne log jamais les commandes defaults write com.jamf*
            if is_excluded_defaults_cmd "$cmd"; then
              :
            else
              # Filtre final de sûreté: ne log pas de commande si le domaine est exclu
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
            fi
            ;;
        esac
      fi
    done
  else
    # Snapshot initial du domaine: ne rien afficher ni générer
    :
  fi
  /bin/mv -f "$curr" "$prev" 2>/dev/null || /bin/cp -f "$curr" "$prev" 2>/dev/null || :
  /bin/mv -f "$curr_json" "$prev_json" 2>/dev/null || /bin/cp -f "$curr_json" "$prev_json" 2>/dev/null || :
}

if [ "$ALL_MODE" = "true" ]; then
  log_line "Démarrage: surveillance de TOUTES les préférences"
else
  log_line "Démarrage de la surveillance sur $DOMAIN"
fi

# Détecte la disponibilité de `defaults watch` en l'essayant brièvement
supports_defaults_watch() {
  "${RUN_AS_USER[@]}" /usr/bin/defaults watch "$DOMAIN" >/dev/null 2>&1 </dev/null &
  local pid=$!
  # Laisse le temps de démarrer; si la commande est inconnue, elle s'arrête aussitôt
  sleep 0.2
  if /bin/kill -0 "$pid" 2>/dev/null; then
    /bin/kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 0
  else
    return 1
  fi
}

# Lancement de Console.app (si possible) et arrêt quand Console est fermée
is_console_running() { /usr/bin/pgrep -x "Console" >/dev/null 2>/dev/null; }
launch_console() {
  # Ouvre Console en contexte utilisateur console (utile quand exécuté via Jamf/root)
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

# Démarre l'observation dans un processus en arrière-plan
start_watch() {
  # Lance un watcher defaults (si dispo) ET une boucle de diff en parallèle
  local DEFAULTS_PID="" POLL_PID=""

  if supports_defaults_watch; then
    if command -v script >/dev/null 2>&1; then
      log_line "Mode: defaults watch (pty)"
      script -q /dev/null "${RUN_AS_USER[@]}" /usr/bin/defaults watch "$DOMAIN" 2>&1 |
      while read -r line; do log_line "$line"; done &
      DEFAULTS_PID=$!
    else
      log_line "Mode: defaults watch (pipe)"
      "${RUN_AS_USER[@]}" /usr/bin/defaults watch "$DOMAIN" 2>&1 |
      while read -r line; do log_line "$line"; done &
      DEFAULTS_PID=$!
    fi
  else
    log_line "defaults watch indisponible — utilisation du mode polling"
  fi

  # Polling de secours + diffs
  (
    while true; do
      show_domain_diff "$DOMAIN"
      sleep 1
    done
  ) &
  POLL_PID=$!

  trap 'kill -TERM ${DEFAULTS_PID:-} ${POLL_PID:-} 2>/dev/null || true; wait ${DEFAULTS_PID:-} ${POLL_PID:-} 2>/dev/null || true; exit 0' TERM INT
  wait
}

# Surveille toutes les préférences via fs_usage (system + utilisateur)
start_watch_all() {
  log_line "Mode: surveillance TOUTES préférences (fs_usage + polling)"

  # Détermine le dossier Preferences utilisateur actif si possible
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

  # Snapshot initial: parcourt les .plist utilisateur et (optionnel) système
  if [ -d "$prefs_user" ]; then
    snapshot_notice "Snapshot initial utilisateur : début"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      local dom=""
      dom=$(domain_from_plist_path "$f")
      # Skip silencieusement les domaines exclus pendant le snapshot
      if is_excluded_domain "$dom"; then
        continue
      fi
      snapshot_notice "Snapshot USER : ${dom:-$f}"
      show_plist_diff USER "$f" silent
    done < <(/usr/bin/find "$prefs_user" -type f -name "*.plist" 2>/dev/null)
    snapshot_notice "Snapshot initial utilisateur : terminé"
    SNAPSHOT_READY="true"
  fi
  if [ "$INCLUDE_SYSTEM" = "true" ] && [ -d "$prefs_system" ]; then
    snapshot_notice "Snapshot initial système : début"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      local dom=""
      dom=$(domain_from_plist_path "$f")
      # Skip silencieusement les domaines exclus pendant le snapshot
      if is_excluded_domain "$dom"; then
        continue
      fi
      snapshot_notice "Snapshot SYSTEM : ${dom:-$f}"
      show_plist_diff SYSTEM "$f" silent
    done < <(/usr/bin/find "$prefs_system" -type f -name "*.plist" 2>/dev/null)
    snapshot_notice "Snapshot initial système : terminé"
    SNAPSHOT_READY="true"
  fi
  if [ "${SNAPSHOT_READY:-false}" = "true" ]; then
    snapshot_notice "Snapshots initiaux traités — vous pouvez effectuer vos modifications"
  fi

  fs_watch() {
    # Lancement fs_usage; on force un pseudo‑TTY si possible pour un flux non bufferisé
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

  poll_watch() {
    # Poll de sauvegarde: détecte les .plist modifiés depuis le dernier scan
    local marker_user marker_sys
    marker_user=$(/usr/bin/mktemp "/tmp/prefs-user.marker.XXXXXX")
    marker_sys=$(/usr/bin/mktemp "/tmp/prefs-sys.marker.XXXXXX")
    # Init anciens marqueurs dans le passé
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
      # Avance les marqueurs
      /bin/mv -f "$now" "$marker_user" 2>/dev/null || /usr/bin/touch "$marker_user" 2>/dev/null || true
      /usr/bin/touch -r "$marker_user" "$marker_sys" 2>/dev/null || true
      /bin/sleep 2
    done
  }

  # Démarre les deux mécanismes pour maximiser la détection
  fs_watch &
  local FS_PID=$!
  poll_watch &
  local POLL_PID=$!

  trap 'kill -TERM $FS_PID $POLL_PID 2>/dev/null || true; wait $FS_PID $POLL_PID 2>/dev/null || true; exit 0' TERM INT
  wait
}

# Interrompt si domaine explicitement exclu (mode domaine uniquement)
if [ "$ALL_MODE" != "true" ] && is_excluded_domain "$DOMAIN"; then
  log_line "Domaine exclu par défaut: $DOMAIN — arrêt de la surveillance"
  exit 0
fi

# Tente d'ouvrir Console.app
launch_console

# Démarre la surveillance en arrière-plan et retient son PID
if [ "$ALL_MODE" = "true" ]; then
  start_watch_all &
else
  start_watch &
fi
WATCH_PID=$!

if is_console_running; then
  # Boucle: tant que Console est ouverte, on continue
  while is_console_running; do
    sleep 1
  done
  log_line "Console.app fermée — arrêt de la surveillance"
  kill -TERM "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  exit 0
else
  # Si Console ne peut pas démarrer (ex: script exécuté sans session GUI), on continue le monitoring
  log_line "Console non détectée — poursuite de la surveillance (Ctrl+C pour arrêter)"
  wait "$WATCH_PID" 2>/dev/null || true
  exit 0
fi
