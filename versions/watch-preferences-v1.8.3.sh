#!/bin/zsh
# Nom: watch-preferences.sh
# Description: Observe et logge les changements d’un domaine de préférences macOS
# Version: 1.8.3
# Paramètres Jamf:
#   $4 = Domaine (ex: com.apple.finder, ALL ou *)
#   $5 = Chemin du log (fichier unique). Défaut:
#        - ALL/*: /var/log/preferences.watch.log
#        - Domaine: /var/log/<domaine>.prefs.log
#   $6 = INCLUDE_SYSTEM (true/false) — en mode ALL, inclure les préférences système (défaut: false)
#   $7 = ONLY_CMDS (true/false) — n'affiche/log que les commandes defaults (défaut: false)

# Sécurisation exécution (zsh)
set -e
set -u
set -o pipefail

# Paramètres Jamf / défauts
DOMAIN="${4:-ALL}"
# ONLY_CMDS peut être passé en env var (ONLY_CMDS=1) ou en $7
ONLY_CMDS_RAW="${ONLY_CMDS:-${7:-false}}"
INCLUDE_SYSTEM_RAW="${6:-false}"

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
{ printf "[init] Log file: %s\n" "$LOGFILE"; } | { cat; cat >> "$LOGFILE" 2>/dev/null || true; }
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
    # Affiche en console et append dans le fichier (sans tee pour éviter des anomalies d'écriture)
    printf "%s\n" "$out"
    printf "%s\n" "$out" >> "$LOGFILE" 2>/dev/null || true
    /usr/bin/logger -t "watch-preferences[$DOMAIN_TAG]" -- "$out"
    return 0
  fi
  # Console (stdout) + fichier
  local line="[$ts] $msg"
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
    printf "%s\n" "$out"
    printf "%s\n" "$out" >> "$LOGFILE" 2>/dev/null || true
    /usr/bin/logger -t "watch-preferences[user]" -- "$out"
    return 0
  fi
  local line="[$ts] $msg"
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
    printf "%s\n" "$out"
    printf "%s\n" "$out" >> "$LOGFILE" 2>/dev/null || true
    /usr/bin/logger -t "watch-preferences[system]" -- "$out"
    return 0
  fi
  local line="[$ts] $msg"
  printf "%s\n" "$line"
  printf "%s\n" "$line" >> "$LOGFILE" 2>/dev/null || true
  /usr/bin/logger -t "watch-preferences[system]" -- "$msg"
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

hash_path() { # hash_path <path>
  local p="$1"
  if command -v /sbin/md5 >/dev/null 2>&1; then
    /sbin/md5 -qs "$p" 2>/dev/null || echo "$p" | /usr/bin/cksum | awk '{print $1}'
  else
    echo "$p" | /usr/bin/cksum | awk '{print $1}'
  fi
}

show_plist_diff() { # show_plist_diff <USER|SYSTEM> <plist_path>
  local kind="$1" path="$2"
  [ -f "$path" ] || return 0
  init_cache
  local key prev curr
  key=$(hash_path "$path")
  prev="$CACHE_DIR/${key}.prev"
  curr="$CACHE_DIR/${key}.curr"
  dump_plist "$path" "$curr"
  if [ -s "$prev" ]; then
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
      local kv keyname val snippet
      kv=$(printf '%s' "$dline" | /usr/bin/sed -nE 's/^[+-][[:space:]]*"([^"]+)"[[:space:]]*=>[[:space:]]*(.*)$/\1|\2/p')
      if [ -n "$kv" ]; then
        keyname="${kv%%|*}"
        val="${kv#*|}"
        # Raccourcit la valeur pour console
        snippet=$(printf '%s' "$val" | /usr/bin/tr '\n' ' ' | /usr/bin/awk '{s=$0; if(length(s)>160) {print substr(s,1,157) "..."} else {print s}}')
        if [ "$kind" = "USER" ]; then
          log_user "Key: ${keyname} | Item: ${snippet}"
        else
          log_system "Key: ${keyname} | Item: ${snippet}"
        fi
        # Génère une commande defaults pour la nouvelle valeur ('+' seulement)
        case "$dline" in
          +*)
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
              cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }<type> <value>"
            fi
            if [ "$kind" = "USER" ]; then
              log_user "Cmd: $cmd"
            else
              log_system "Cmd: $cmd"
            fi
            ;;
        esac
      fi
    done
  else
    # Premier snapshot: optionnellement émettre des commandes pour toutes les clés présentes
    if [ "$kind" = "USER" ]; then
      log_user "Snapshot initial: $path"
    else
      log_system "Snapshot initial: $path"
    fi
    # Génère des commandes pour chaque ligne "Key" => value du snapshot actuel
    /usr/bin/sed -nE 's/^[[:space:]]*("[^"]+"[[:space:]]*=>[[:space:]]*.*)$/\1/p' "$curr" | while IFS= read -r kvline; do
      [ -n "$kvline" ] || continue
      keyname=$(printf '%s' "$kvline" | /usr/bin/sed -nE 's/^"([^"]+)"[[:space:]]*=>[[:space:]]*(.*)$/\1/p')
      val=$(printf '%s' "$kvline" | /usr/bin/sed -nE 's/^"([^"]+)"[[:space:]]*=>[[:space:]]*(.*)$/\2/p')
      [ -n "${keyname:-}" ] || continue
      # Déduire le domaine depuis le chemin
      base="$(/usr/bin/basename "$path")"; dom="${base%.plist}"; hostflag=""
      if printf '%s' "$path" | /usr/bin/grep -q "/ByHost/"; then
        hostflag="-currentHost"
        dom="$(printf '%s' "$dom" | /usr/bin/sed -E 's/\.[0-9A-Fa-f-]{8,}$//')"
      fi
      trimmed=$(printf '%s' "$val" | /usr/bin/sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
      if printf '%s' "$trimmed" | /usr/bin/grep -Eq '^".*"$'; then
        noquotes="${trimmed#\"}"; noquotes="${noquotes%\"}"; str=$(printf '%s' "$noquotes" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g')
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
        cmd="defaults write ${dom} \"${keyname}\" ${hostflag:+$hostflag }<type> <value>"
      fi
      if [ "$kind" = "USER" ]; then
        log_user "Cmd: $cmd"
      else
        log_system "Cmd: $cmd"
      fi
    done
  fi
  /bin/mv -f "$curr" "$prev" 2>/dev/null || /bin/cp -f "$curr" "$prev" 2>/dev/null || :
}

# Diff du domaine (export texte)
show_domain_diff() { # show_domain_diff <domain>
  local dom="$1"
  init_cache
  local key prev curr tmpplist
  key=$(hash_path "domain:${CONSOLE_USER}:${dom}")
  prev="$CACHE_DIR/${key}.prev"
  curr="$CACHE_DIR/${key}.curr"
  tmpplist="$CACHE_DIR/${key}.plist"
  # Export brut du domaine vers un fichier puis rendu texte stable
  "${RUN_AS_USER[@]}" /usr/bin/defaults export "$dom" - > "$tmpplist" 2>/dev/null || :
  if [ -s "$tmpplist" ]; then
    /usr/bin/plutil -p "$tmpplist" > "$curr" 2>/dev/null || /bin/cat "$tmpplist" > "$curr" 2>/dev/null || :
  else
    : > "$curr" 2>/dev/null || true
  fi
  if [ -s "$prev" ]; then
    /usr/bin/diff -u "$prev" "$curr" 2>/dev/null | /usr/bin/awk 'NR>2 && ($0 ~ /^\+/ || $0 ~ /^-/) && $0 !~ /^\+\+\+|^---/' |
    while IFS= read -r dline; do
      [ -n "$dline" ] || continue
      log_line "Diff $dom: $dline"
      # Extraction clé + valeur (aperçu)
      local kv keyname val snippet
      kv=$(printf '%s' "$dline" | /usr/bin/sed -nE 's/^[+-][[:space:]]*"([^"]+)"[[:space:]]*=>[[:space:]]*(.*)$/\1|\2/p')
      if [ -n "$kv" ]; then
        keyname="${kv%%|*}"
        val="${kv#*|}"
        snippet=$(printf '%s' "$val" | /usr/bin/tr '\n' ' ' | /usr/bin/awk '{s=$0; if(length(s)>160) {print substr(s,1,157) "..."} else {print s}}')
        log_line "Key: ${keyname} | Item: ${snippet}"
        case "$dline" in
          +*)
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
              cmd="defaults write ${dom} \"${keyname}\" <type> <value>"
            fi
            log_line "Cmd: $cmd"
            ;;
        esac
      fi
    done
  else
    log_line "Snapshot initial domaine: $dom"
    # Émettre des commandes pour le snapshot initial du domaine
    /usr/bin/sed -nE 's/^[[:space:]]*("[^"]+"[[:space:]]*=>[[:space:]]*.*)$/\1/p' "$curr" | while IFS= read -r kvline; do
      [ -n "$kvline" ] || continue
      keyname=$(printf '%s' "$kvline" | /usr/bin/sed -nE 's/^"([^"]+)"[[:space:]]*=>[[:space:]]*(.*)$/\1/p')
      val=$(printf '%s' "$kvline" | /usr/bin/sed -nE 's/^"([^"]+)"[[:space:]]*=>[[:space:]]*(.*)$/\2/p')
      [ -n "${keyname:-}" ] || continue
      trimmed=$(printf '%s' "$val" | /usr/bin/sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
      if printf '%s' "$trimmed" | /usr/bin/grep -Eq '^".*"$'; then
        noquotes="${trimmed#\"}"; noquotes="${noquotes%\"}"; str=$(printf '%s' "$noquotes" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g')
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
        cmd="defaults write ${dom} \"${keyname}\" <type> <value>"
      fi
      log_line "Cmd: $cmd"
    done
  fi
  /bin/mv -f "$curr" "$prev" 2>/dev/null || /bin/cp -f "$curr" "$prev" 2>/dev/null || :
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
is_console_running() { /usr/bin/pgrep -x "Console" >/dev/null 2>&1; }
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
    local last_sum=""
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
    /usr/bin/find "$prefs_user" -type f -name "*.plist" 2>/dev/null | while IFS= read -r f; do
      [ -n "$f" ] && show_plist_diff USER "$f"
    done
  fi
  if [ "$INCLUDE_SYSTEM" = "true" ] && [ -d "$prefs_system" ]; then
    /usr/bin/find "$prefs_system" -type f -name "*.plist" 2>/dev/null | while IFS= read -r f; do
      [ -n "$f" ] && show_plist_diff SYSTEM "$f"
    done
  fi

  fs_watch() {
    # Lancement fs_usage; on force un pseudo‑TTY si possible pour un flux non bufferisé
    local FS_CMD
    FS_CMD=(/usr/sbin/fs_usage -w -f filesys)
  if command -v script >/dev/null 2>&1; then
    script -q /dev/null "${FS_CMD[@]}" 2>/dev/null |
    /usr/bin/sed -nE 's|.*(/.*Library/(Group Containers|Containers|Preferences)/.*\.plist).*|\1|p' |
    /usr/bin/awk -v pu="${prefs_user}" -v ps="${prefs_system}" -v incsys="${INCLUDE_SYSTEM}" '{
      path=$0;
      if (index(path, pu)==1)      { print "USER " path }
      else if (index(path, ps)==1) { print "SYSTEM " path }
      else                          { print "OTHER " path }
    }' | while IFS= read -r line; do
      cat_type="${line%% *}"; plist="${line#* }"
      [ -z "$plist" ] && continue
      if [ "$cat_type" = "SYSTEM" ] && [ "${INCLUDE_SYSTEM}" != "true" ]; then
        continue
      fi
      if [ "$cat_type" = "USER" ]; then
        log_user "FS change: $plist"; show_plist_diff USER "$plist"; dom=$(domain_from_plist_path "$plist"); [ -n "$dom" ] && show_domain_diff "$dom"
      else
        log_system "FS change: $plist"; show_plist_diff SYSTEM "$plist"; dom=$(domain_from_plist_path "$plist"); [ -n "$dom" ] && show_domain_diff "$dom"
      fi
    done
  else
    /usr/sbin/fs_usage -w -f filesys 2>/dev/null |
    /usr/bin/sed -nE 's|.*(/.*Library/(Group Containers|Containers|Preferences)/.*\.plist).*|\1|p' |
    /usr/bin/awk -v pu="${prefs_user}" -v ps="${prefs_system}" -v incsys="${INCLUDE_SYSTEM}" '{
      path=$0;
      if (index(path, pu)==1)      { print "USER " path }
      else if (index(path, ps)==1) { print "SYSTEM " path }
      else                          { print "OTHER " path }
    }' | while IFS= read -r line; do
      cat_type="${line%% *}"; plist="${line#* }"
      [ -z "$plist" ] && continue
      if [ "$cat_type" = "SYSTEM" ] && [ "${INCLUDE_SYSTEM}" != "true" ]; then
        continue
      fi
      if [ "$cat_type" = "USER" ]; then
        log_user "FS change: $plist"; show_plist_diff USER "$plist"; dom=$(domain_from_plist_path "$plist"); [ -n "$dom" ] && show_domain_diff "$dom"
      else
        log_system "FS change: $plist"; show_plist_diff SYSTEM "$plist"; dom=$(domain_from_plist_path "$plist"); [ -n "$dom" ] && show_domain_diff "$dom"
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
          [ -n "$f" ] && { log_user "POLL change: $f"; show_plist_diff USER "$f"; dom=$(domain_from_plist_path "$f"); [ -n "$dom" ] && show_domain_diff "$dom"; }
        done
      fi
      if [ "${INCLUDE_SYSTEM}" = "true" ] && [ -d "$prefs_system" ] && [ "$(id -u)" -eq 0 ]; then
        /usr/bin/find "$prefs_system" -type f -name "*.plist" -newer "$marker_sys" 2>/dev/null | while IFS= read -r f; do
          [ -n "$f" ] && { log_system "POLL change: $f"; show_plist_diff SYSTEM "$f"; dom=$(domain_from_plist_path "$f"); [ -n "$dom" ] && show_domain_diff "$dom"; }
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
