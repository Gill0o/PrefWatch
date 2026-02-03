#!/bin/zsh
# Nom: watch-preferences.sh
# Description: Observe et logge les changements d’un domaine de préférences macOS
# Usage Jamf: $4 (domaine), $5 (fichier log)

# Sécurisation exécution (zsh)
set -e
set -u
set -o pipefail

# Paramètres Jamf / défauts
DOMAIN="${4:-com.apple.finder}"
LOGFILE="${5:-/var/log/${DOMAIN}.prefs.log}"

# Prépare le dossier de log
mkdir -p "$(dirname "$LOGFILE")"

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

# Surveille et journalise les événements
/usr/bin/defaults watch "$DOMAIN" 2>&1 | while read -r line; do
  log_line "$line"
done
