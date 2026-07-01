#!/bin/sh
# notdienst-watchdog: fuettert /dev/watchdog, solange der Proxy gesund ist.
#
# Faellt /healthz wiederholt aus (oder stirbt dieser Prozess selbst), wird NICHT
# mehr gefuettert -> das WDT-Modul (mit nowayout=1 geladen) loest einen Hardware-
# Reset des GENE aus. Damit heilt sich die Schaufenster-Kiste selbst, genau wie
# frueher ApoShow ueber den Super-I/O-Watchdog.
#
# Kein Flash-Verschleiss: nur Loopback-HTTP + Schreiben aufs Watchdog-Device.
#
# Aufruf ueber den OpenRC-Dienst notdienst-watchdog (siehe setup-watchdog.sh).

WDT_DEV="${WDT_DEV:-/dev/watchdog}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:8080/healthz}"
PET_INTERVAL="${PET_INTERVAL:-10}"   # Sekunden zwischen zwei "Fuetterungen"
FAIL_LIMIT="${FAIL_LIMIT:-6}"        # so viele healthz-Fehler in Folge -> Reset
GRACE="${GRACE:-120}"                # Anlauf-Schonzeit: erst mal nur fuettern

log() { echo "notdienst-watchdog: $*"; }

if [ ! -c "$WDT_DEV" ]; then
    log "FEHLER: $WDT_DEV nicht vorhanden (WDT-Modul nicht geladen?)"
    exit 1
fi

# fd 3 offen halten = Watchdog scharf. Ein '.' fuettert unkritisch; ein 'V' ist
# der Magic-Close und schaltet den Dog ab (greift nur bei nowayout=0).
exec 3>"$WDT_DEV" || { log "FEHLER: $WDT_DEV nicht beschreibbar"; exit 1; }
pet() { printf '.' >&3 2>/dev/null; }

# Sauberer Stopp (z.B. 'rc-service notdienst-watchdog stop' oder Reboot):
# Magic-'V' schreiben und beenden -> bei nowayout=0 wird der Watchdog abgeschaltet,
# es folgt KEIN Reset. Damit ist Wartung ohne Zwangs-Reboot moeglich. Bei
# nowayout=1 ignoriert der Kernel das 'V' -> Reset nach Timeout (dokumentiert).
graceful_stop() {
    log "Stopp angefordert -> Watchdog abschalten (Magic-Close)"
    printf 'V' >&3 2>/dev/null
    exit 0
}
trap graceful_stop TERM INT

start="$(cut -d. -f1 /proc/uptime)"
fails=0
log "aktiv (dev=$WDT_DEV health=$HEALTH_URL pet=${PET_INTERVAL}s limit=$FAIL_LIMIT grace=${GRACE}s)"

while :; do
    now="$(cut -d. -f1 /proc/uptime)"
    if [ "$((now - start))" -lt "$GRACE" ]; then
        # Anlaufphase: Proxy startet evtl. noch -> nur fuettern, nicht bewerten.
        pet
    elif wget -q -T 5 -O /dev/null "$HEALTH_URL" 2>/dev/null; then
        fails=0
        pet
    else
        fails=$((fails + 1))
        log "healthz fehlgeschlagen ($fails/$FAIL_LIMIT)"
        if [ "$fails" -ge "$FAIL_LIMIT" ]; then
            # Grenze erreicht: NICHT beenden (Close wuerde den Dog bei nowayout=0
            # abschalten). Stattdessen aufhoeren zu fuettern und das Device offen
            # halten -> Timeout laeuft ab -> Hardware-Reset. Ein Wartungs-Stopp
            # (SIGTERM) bricht das ueber graceful_stop bewusst ab.
            log "Grenze erreicht -> keine Fuetterung mehr, Hardware-Reset in <=Timeout"
            while :; do sleep 3600; done
        fi
        pet          # bis zum Limit weiter fuettern
    fi
    sleep "$PET_INTERVAL"
done
