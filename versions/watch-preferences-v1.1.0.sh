#!/bin/zsh
# Nom: watch-preferences.sh
# Description: Observe et logge les changements d’un domaine de préférences macOS
# Version: 1.1.0
# Usage Jamf: $4 (domaine), $5 (fichier log)

# Sécurisation exécution (zsh)
set -e
set -u
set -o pipefail

# Paramètres Jamf / défauts
DOMAIN="${4:-com.apple.finder}"
LOGFILE="${5:-/var/log/${DOMAIN}.prefs.log}"

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

# Prépare le dossier de log et fallback si non inscriptible
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
if ! ( : > "$LOGFILE" ) 2>/dev/null; then
  LOGFILE="/tmp/${DOMAIN}.prefs.log"
  mkdir -p "/tmp" 2>/dev/null || true
  : > "$LOGFILE" 2>/dev/null || true
fi

log_line() {
  local msg="$1"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  # Console (stdout) + fichier
  echo "[$ts] $msg" | tee -a "$LOGFILE"
  # App Console (Unified Log)
  /usr/bin/logger -t "watch-preferences[$DOMAIN]" -- "$msg"
}

log_line "Démarrage de la surveillance sur $DOMAIN"

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
  if supports_defaults_watch; then
    if command -v script >/dev/null 2>&1; then
      log_line "Mode: defaults watch (pty)"
      script -q /dev/null "${RUN_AS_USER[@]}" /usr/bin/defaults watch "$DOMAIN" 2>&1 | while read -r line; do
        log_line "$line"
      done
    else
      log_line "Mode: defaults watch (pipe)"
      "${RUN_AS_USER[@]}" /usr/bin/defaults watch "$DOMAIN" 2>&1 | while read -r line; do
        log_line "$line"
      done
    fi
  else
    log_line "defaults watch indisponible — bascule en mode polling (1s)"
    local tmp_dir prev curr
    tmp_dir=$(mktemp -d "/tmp/watchprefs.XXXXXX") || exit 0
    prev="$tmp_dir/prev.plist"
    curr="$tmp_dir/curr.plist"
    cleanup() { rm -rf "$tmp_dir" 2>/dev/null || true; }
    trap cleanup EXIT
    "${RUN_AS_USER[@]}" /usr/bin/defaults export "$DOMAIN" - > "$prev" 2>/dev/null || :
    while true; do
      "${RUN_AS_USER[@]}" /usr/bin/defaults export "$DOMAIN" - > "$curr" 2>/dev/null || :
      if ! cmp -s "$prev" "$curr"; then
        log_line "Changement détecté pour $DOMAIN"
        if command -v diff >/dev/null 2>&1; then
          diff -u "$prev" "$curr" 2>/dev/null | sed '1,2d' | while IFS= read -r dline; do
            [ -n "$dline" ] && log_line "$dline" || true
          done || true
        fi
        mv "$curr" "$prev" 2>/dev/null || cp "$curr" "$prev" 2>/dev/null || :
      fi
      sleep 1
    done
  fi
}

# Tente d'ouvrir Console.app
launch_console

# Démarre la surveillance en arrière-plan et retient son PID
start_watch &
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
