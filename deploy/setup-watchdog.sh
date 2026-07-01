#!/bin/sh
# setup-watchdog.sh -- Hardware-Watchdog fuer die Notdienst-Kiste einrichten.
#
# Auf dem Alpine-Zielgeraet (GENE-5315) als root ausfuehren, NACH setup-kiosk.sh.
# Erkennt das passende Watchdog-Kernelmodul, laedt es mit nowayout=1 und richtet
# einen OpenRC-Feeder ein, der /dev/watchdog nur fuettert, solange der Proxy
# ueber /healthz gesund antwortet. Faellt Proxy oder System aus -> Hardware-
# Reset (Selbstheilung, wie frueher ApoShow ueber den Super-I/O-Watchdog).
#
# Aufruf:  sh deploy/setup-watchdog.sh
set -e

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DST_DIR="/opt/notdienst-proxy"
TIMEOUT="${WDT_TIMEOUT:-60}"     # Hardware-Timeout in Sekunden (Haenger-Toleranz)
# nowayout=0 (Default): Watchdog laesst sich sauber abschalten -> Wartung ohne
#   Zwangs-Reboot ('rc-service notdienst-watchdog stop' deaktiviert ihn).
# nowayout=1: bombensicher (auch kill -9/OOM des Feeders -> Reset), aber jeder
#   Stopp fuehrt nach <=Timeout zum Reboot.
NOWAYOUT="${WDT_NOWAYOUT:-0}"

echo "== 1) Watchdog-Kernelmodul erkennen =="
# Kandidaten fuer AAEON/Geode-Boards. geodewdt ist bewusst NICHT dabei: es
# braucht cs5535_mfgpt, das setup-kiosk.sh absichtlich blacklistet (Geode-Timer-
# Fallstrick). Die ApoShow-Config nutzte den Super-I/O-Watchdog an Port
# 0x370/0x371 (= Winbond) -> Winbond-Treiber zuerst. Die Treiber pruefen die
# Chip-ID und verweigern bei fremdem Chip, Durchprobieren ist daher gefahrlos.
CANDIDATES="w83627hf_wdt w83977f_wdt w83877f_wdt f71808e_wdt it87_wdt sch311x_wdt sbc60xxwdt pc87413_wdt"

WDT_MODULE="none"
if [ -c /dev/watchdog ]; then
    echo "  /dev/watchdog existiert bereits (Modul schon geladen)."
else
    for m in $CANDIDATES; do
        # erst mit Parametern versuchen, dann ohne (nicht jedes Modul kennt 'timeout')
        if modprobe "$m" nowayout="$NOWAYOUT" timeout="$TIMEOUT" 2>/dev/null && [ -c /dev/watchdog ]; then
            WDT_MODULE="$m"; break
        fi
        if modprobe "$m" 2>/dev/null && [ -c /dev/watchdog ]; then
            WDT_MODULE="$m"; break
        fi
        modprobe -r "$m" 2>/dev/null || true
    done
    if [ ! -c /dev/watchdog ]; then
        echo "  Kein Hardware-Watchdog erkannt -> Fallback softdog (rein Software)."
        echo "  ! softdog kann einen KOMPLETTEN Kernel-Hang NICHT abfangen."
        modprobe softdog nowayout="$NOWAYOUT" soft_margin="$TIMEOUT" 2>/dev/null \
            || modprobe softdog 2>/dev/null || true
        [ -c /dev/watchdog ] && WDT_MODULE="softdog"
    fi
fi
[ -c /dev/watchdog ] || { echo "FEHLER: konnte keinen Watchdog aktivieren."; exit 1; }

IDENT="$(cat /sys/class/watchdog/watchdog0/identity 2>/dev/null || echo '?')"
echo "  Aktiv: Modul=${WDT_MODULE} Identity='$IDENT' Timeout=${TIMEOUT}s"

echo "== 2) Modul-Optionen + Autoload persistieren =="
# Optionen fest verankern, damit sie auch nach Reboot beim Autoload greifen.
if [ "$WDT_MODULE" = "softdog" ]; then
    echo "options softdog nowayout=$NOWAYOUT soft_margin=$TIMEOUT" > /etc/modprobe.d/notdienst-wdt.conf
elif [ "$WDT_MODULE" != "none" ]; then
    echo "options $WDT_MODULE nowayout=$NOWAYOUT timeout=$TIMEOUT" > /etc/modprobe.d/notdienst-wdt.conf
fi

echo "== 3) Feeder + Dienst installieren =="
mkdir -p "$DST_DIR"
cp "$SRC_DIR/deploy/watchdog-feed.sh" "$DST_DIR/watchdog-feed.sh"
chmod +x "$DST_DIR/watchdog-feed.sh"

cat > /etc/notdienst-watchdog.conf <<EOF
# Konfiguration fuer den notdienst-watchdog-Feeder (von setup-watchdog.sh erzeugt)
WDT_MODULE="$WDT_MODULE"
WDT_DEV="/dev/watchdog"
HEALTH_URL="http://127.0.0.1:8080/healthz"
PET_INTERVAL="10"
FAIL_LIMIT="6"
GRACE="120"
EOF

install -m755 "$SRC_DIR/deploy/notdienst-watchdog.openrc" /etc/init.d/notdienst-watchdog
rc-update add notdienst-watchdog default
rc-service notdienst-watchdog restart || rc-service notdienst-watchdog start

echo "== 4) Persistenz (Diskless) =="
ROOTFS="$(awk '$2=="/"{print $3; exit}' /proc/mounts)"
if [ "$ROOTFS" = "tmpfs" ] && command -v lbu >/dev/null 2>&1; then
    lbu add "$DST_DIR/watchdog-feed.sh" 2>/dev/null || true
    lbu add /etc/notdienst-watchdog.conf 2>/dev/null || true
    lbu commit -d || echo "  ! lbu commit fehlgeschlagen (LBU_MEDIA gesetzt?) - manuell pruefen."
else
    echo "  Sys-Installation (Root=$ROOTFS) -> Aenderungen liegen bereits auf Platte."
fi

echo
echo "FERTIG. Watchdog aktiv (Modul: $WDT_MODULE, Timeout ${TIMEOUT}s, nowayout=$NOWAYOUT)."
if [ "$NOWAYOUT" = "0" ]; then
    echo "Wartung: 'rc-service notdienst-watchdog stop' schaltet den Watchdog"
    echo "         sauber ab (kein Reboot). 'start' aktiviert ihn wieder."
else
    echo "ACHTUNG: nowayout=1 -> 'stop' loest nach <=${TIMEOUT}s einen Reset aus."
fi
