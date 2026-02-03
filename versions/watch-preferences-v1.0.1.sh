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

if has_defaults_watch; then
  # Surveille et journalise les événements via defaults watch
  /usr/bin/defaults watch "$DOMAIN" 2>&1 | while read -r line; do
    log_line "$line"
  done
else
  # Fallback: boucle de polling qui exporte et compare l'état du domaine
  log_line "defaults watch indisponible — bascule en mode polling (1s)"
  tmp_dir=$(mktemp -d "/tmp/watchprefs.XXXXXX")
  prev="$tmp_dir/prev.plist"
  curr="$tmp_dir/curr.plist"
  # État initial
  /usr/bin/defaults export "$DOMAIN" - > "$prev" 2>/dev/null || :
  while true; do
    /usr/bin/defaults export "$DOMAIN" - > "$curr" 2>/dev/null || :
    if ! cmp -s "$prev" "$curr"; then
      log_line "Changement détecté pour $DOMAIN"
      # Journalise un diff lisible si possible
      if command -v diff >/dev/null 2>&1; then
        # Évite l'échec du script si diff retourne non‑zéro
        diff -u "$prev" "$curr" 2>/dev/null | sed '1,2d' | while IFS= read -r dline; do
          [ -n "$dline" ] && log_line "$dline" || true
        done || true
      fi
      mv "$curr" "$prev" 2>/dev/null || cp "$curr" "$prev" 2>/dev/null || :
    fi
    sleep 1
  done
fi
