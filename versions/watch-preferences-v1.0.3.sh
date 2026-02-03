#!/bin/zsh
# Nom: watch-preferences.sh
# Description: Observe et logge les changements d’un domaine de préférences macOS
# Version: 1.0.3
# Usage Jamf: $4 (domaine), $5 (fichier log)

# Sécurisation exécution (zsh)
set -e
set -u
set -o pipefail

# Paramètres Jamf / défauts
DOMAIN="${4:-com.apple.finder}"
LOGFILE="${5:-/var/log/${DOMAIN}.prefs.log}"

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

# Détecte la disponibilité de `defaults watch` (non présent sur certaines versions macOS)
has_defaults_watch() {
  /usr/bin/defaults help 2>&1 | /usr/bin/grep -qE ' watch\b'
}

# Lancement de Console.app (si possible) et arrêt quand Console est fermée
is_console_running() { /usr/bin/pgrep -x "Console" >/dev/null 2>&1; }
launch_console() {
  # Ouvre Console directement sur le fichier de log si possible
  if [ -f "$LOGFILE" ]; then
    /usr/bin/open -b com.apple.Console "$LOGFILE" >/dev/null 2>&1 || \
    /usr/bin/open -a Console "$LOGFILE" >/dev/null 2>&1 || \
    /usr/bin/open -a Console >/dev/null 2>&1 || true
  else
    /usr/bin/open -a Console >/dev/null 2>&1 || true
  fi
}

# Démarre l'observation dans un processus en arrière-plan
start_watch() {
  if has_defaults_watch; then
    /usr/bin/defaults watch "$DOMAIN" 2>&1 | while read -r line; do
      log_line "$line"
    done
  else
    log_line "defaults watch indisponible — bascule en mode polling (1s)"
    local tmp_dir prev curr
    tmp_dir=$(mktemp -d "/tmp/watchprefs.XXXXXX") || exit 0
    prev="$tmp_dir/prev.plist"
    curr="$tmp_dir/curr.plist"
    cleanup() { rm -rf "$tmp_dir" 2>/dev/null || true; }
    trap cleanup EXIT
    /usr/bin/defaults export "$DOMAIN" - > "$prev" 2>/dev/null || :
    while true; do
      /usr/bin/defaults export "$DOMAIN" - > "$curr" 2>/dev/null || :
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

# Boucle: tant que Console est ouverte, on continue
while is_console_running; do
  sleep 1
done

log_line "Console.app fermée — arrêt de la surveillance"

# Arrête proprement la surveillance
kill -TERM "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
exit 0
