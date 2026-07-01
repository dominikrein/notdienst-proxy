#!/bin/sh
# setup-kiosk.sh  --  Zero-Touch-Boot fuer die Notdienst-Anzeige einrichten.
#
# Einmalig auf dem Alpine-Zielgeraet (GENE-5315) als root ausfuehren.
# Danach bootet das Geraet ohne Tastatur direkt in den Vollbild-Kiosk.
#
# Macht folgendes:
#   0) HARDWARE-SCHUTZ: Alpine 3.18 erzwingen (Geode LX ohne NOPL/SSE2)
#   1) apk-Repos geraderuecken (v3.18 community AN, edge AUS) + apk update
#   2) Pakete: python3, agetty, X11 (xf86-video-vesa, OHNE mesa)
#  2b) NetSurf aus Quelltext bauen (in 3.18/x86 nicht paketiert)
#   3) Proxy nach /opt/notdienst-proxy kopieren (falls von hier ausgefuehrt)
#   4) OpenRC-Dienst installieren + aktivieren
#   5) Autologin auf tty1 (agetty --autologin root)
#   6) /root/.profile: startet auf tty1 automatisch den Kiosk
#   7) Konsolen-Blanking aus, Geode-Modul blacklisten
#   8) Bei Diskless-Installation: 'lbu commit' -> Overlay auf CF persistieren
#
# Laeuft sowohl in der QEMU-Bake-VM (Sys-Install) als auch direkt auf dem GENE.
#
# Aufruf:  sh deploy/setup-kiosk.sh
set -e

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DST_DIR="/opt/notdienst-proxy"

echo "== 0) Hardware-Schutz: Alpine 3.18 erzwingen =="
# Der Geode LX ist i586-Klasse OHNE NOPL/SSE2. edge und neuere x86-Builds
# emittieren NOPL (0F 1F) -> auf echter Hardware "Illegal Instruction". Nur
# 3.18 ist erprobt. Eine Bake-VM auf modernem Host wuerde den Crash NICHT zeigen.
REL="$(cat /etc/alpine-release 2>/dev/null || echo unknown)"
case "$REL" in
    3.18.*) echo "  Alpine $REL - ok." ;;
    *) echo "  !! Alpine '$REL' statt 3.18.x -> ABBRUCH."
       echo "     Auf dem Geode ist 3.18 Pflicht (edge = NOPL = Illegal Instruction)."
       echo "     Basis mit der 3.18-ISO neu aufsetzen, dann erneut ausfuehren."
       exit 1 ;;
esac

echo "== 1) apk-Repos: v3.18 community AN, edge AUS =="
# community freischalten (auskommentierte .../community-Zeile entkommentieren).
sed -i 's|^#\(.*/community\)$|\1|' /etc/apk/repositories
# edge deaktivieren: mischen mit 3.18 zieht Riesenpakete UND NOPL-Binaries.
sed -i 's|^\([^#].*/edge/.*\)$|#\1|' /etc/apk/repositories
apk update

echo "== 2) X11-Stack (VESA, ohne mesa/llvm) =="
# Kein Geode-Framebuffer im Kernel (kein /dev/fb0) UND kein xf86-video-geode in
# Alpine -> X11 mit xf86-video-vesa (VESA-BIOS/int10). BEWUSST OHNE
# 'setup-xorg-base' (das zoege mesa-dri-gallium + llvm ~150 MB). Kein WM noetig:
# NetSurf oeffnet per Choices direkt in Panelgroesse (640x480) = Vollbild.
apk add --no-cache python3 agetty openssh \
    xorg-server xf86-video-vesa xf86-input-libinput xinit \
    xset xrandr ttf-dejavu font-misc-misc
rc-update add sshd default 2>/dev/null || true

echo "== 2a) DPMS/Blanking im X-Server dauerhaft AUS =="
# Warum hier UND per xset (kiosk): der VESA-int10-Treiber kann das Panel nach
# einem DPMS-Off NICHT zuverlaessig wieder aufwecken -> Schirm bliebe schwarz
# (kommt auch bei Tastendruck nicht zurueck). Deshalb Blanking/DPMS gar nicht
# erst zulassen. xset allein ist fragil (fehlt das Paket, greift nichts); diese
# ServerFlags/Monitor-Config setzt es fest beim X-Start und ist die robuste
# Absicherung. /etc/X11/xorg.conf.d wird auch ohne setup-xorg-base gelesen.
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-noblank.conf <<'EOF'
Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection

Section "Monitor"
    Identifier "Monitor0"
    Option     "DPMS" "false"
EndSection

Section "Device"
    Identifier "Card0"
    Driver     "vesa"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device     "Card0"
    Monitor    "Monitor0"
EndSection
EOF

echo "== 2b) NetSurf bauen (nicht in 3.18/x86 paketiert; Build = NOPL-safe) =="
# NetSurf gibt es fuer x86 nur in edge (NOPL -> scheidet aus). Loesung: auf der
# 3.18-Toolchain bauen -> das Binary erbt die Geode-sichere Baseline.
if command -v netsurf-gtk3 >/dev/null 2>&1; then
    echo "  netsurf-gtk3 bereits vorhanden -> ueberspringe Build."
else
    sh "$SRC_DIR/deploy/build-netsurf.sh"
fi

echo "== 3) Proxy nach $DST_DIR =="
mkdir -p "$DST_DIR"
# Wird das Script BEREITS aus dem Zielverzeichnis ausgefuehrt (z.B. aus
# /opt/notdienst-proxy/deploy), dann ist SRC_DIR == DST_DIR und 'cp' wuerde die
# Dateien auf sich selbst kopieren ("are the same file") -> mit set -e Abbruch.
# In dem Fall sind die Dateien schon am Ziel; wir ueberspringen das Kopieren.
if [ "$SRC_DIR" -ef "$DST_DIR" ]; then
    echo "  Laeuft bereits aus $DST_DIR -> Kopieren uebersprungen."
else
    cp "$SRC_DIR/server.py" "$DST_DIR/"
    cp "$SRC_DIR/deploy/kiosk.sh" "$DST_DIR/"
    [ -f "$SRC_DIR/deploy/xinitrc-kiosk" ] && cp "$SRC_DIR/deploy/xinitrc-kiosk" "$DST_DIR/"

    # Logo/Assets (rotes Apotheken-A) mitnehmen
    if [ -d "$SRC_DIR/assets" ]; then
        mkdir -p "$DST_DIR/assets"
        cp "$SRC_DIR/assets/"* "$DST_DIR/assets/" 2>/dev/null || true
    fi

    # .env mit dem Zugangs-Token mitnehmen (ist nicht im Repo!)
    if [ -f "$SRC_DIR/.env" ]; then
        cp "$SRC_DIR/.env" "$DST_DIR/.env"
        chmod 600 "$DST_DIR/.env"
    fi
fi
chmod +x "$DST_DIR/kiosk.sh" 2>/dev/null || true

# .env am Ziel pruefen (egal ob gerade kopiert oder schon vorhanden)
if [ -f "$DST_DIR/.env" ]; then
    chmod 600 "$DST_DIR/.env"
else
    echo "  ! Keine .env in $DST_DIR gefunden. Lege sie aus .env.example an,"
    echo "    sonst startet der Proxy nicht (NOTDIENST_XML_URL fehlt)."
fi

echo "== 4) OpenRC-Dienst =="
install -m755 "$SRC_DIR/deploy/notdienst-proxy.openrc" /etc/init.d/notdienst-proxy
rc-update add notdienst-proxy default
rc-service notdienst-proxy restart || rc-service notdienst-proxy start

echo "== 5) Autologin auf tty1 =="
# getty-Zeile fuer tty1 auf Autologin umbiegen (idempotent)
if grep -qE '^tty1::' /etc/inittab; then
    sed -i 's#^tty1::.*#tty1::respawn:/sbin/agetty --autologin root --noclear tty1 linux#' /etc/inittab
else
    echo 'tty1::respawn:/sbin/agetty --autologin root --noclear tty1 linux' >> /etc/inittab
fi

echo "== 6) Kiosk-Autostart in /root/.profile =="
MARK="# >>> notdienst-kiosk >>>"
if ! grep -qF "$MARK" /root/.profile 2>/dev/null; then
    cat >> /root/.profile <<'EOF'
# >>> notdienst-kiosk >>>
if [ "$(tty)" = "/dev/tty1" ] && [ -z "$KIOSK_STARTED" ]; then
    export KIOSK_STARTED=1
    # Konsolen-Blanking aus (Display soll dauerhaft an sein)
    setterm -blank 0 -powersave off 2>/dev/null || true
    exec sh /opt/notdienst-proxy/kiosk.sh
fi
# <<< notdienst-kiosk <<<
EOF
fi

echo "== 7) Geode-Fallstrick: cs5535_mfgpt blacklisten =="
echo "blacklist cs5535_mfgpt" > /etc/modprobe.d/geode.conf

echo "== 7b) FLASH-SCHUTZ: noatime auf Root-Dateisystem =="
# Ohne noatime schreibt der Kernel bei JEDEM Lesezugriff die Zugriffszeit auf
# den Flash zurueck (relatime = seltener, aber immer noch). Auf einer CF-Karte
# ist das der grosse Verschleiss-Treiber. noatime schaltet das komplett aus.
# Nur bei Sys-Install sinnvoll (Diskless-Root ist tmpfs, schreibt eh nichts).
# Greift nach Remount/Reboot. Idempotent: nur ergaenzen, wenn noch nicht da.
ROOTFS_NOW="$(awk '$2=="/"{print $3; exit}' /proc/mounts)"
if [ "$ROOTFS_NOW" != "tmpfs" ] && [ -f /etc/fstab ]; then
    if awk '$1!~/^#/ && $2=="/" && $4~/noatime/{f=1} END{exit !f}' /etc/fstab; then
        echo "  noatime bereits gesetzt - ok."
    else
        awk 'BEGIN{OFS="\t"}
             $1!~/^#/ && $2=="/" && $4!~/noatime/ {$4=$4",noatime"}
             {print}' /etc/fstab > /etc/fstab.new && mv /etc/fstab.new /etc/fstab
        mount -o remount,noatime / 2>/dev/null || true
        echo "  noatime in /etc/fstab ergaenzt (aktiv nach Reboot/Remount)."
    fi
else
    echo "  Root=$ROOTFS_NOW -> kein noatime noetig."
fi

echo "== 8) Persistenz =="
# Diskless zuverlaessig an Root=tmpfs erkennen (lbu/lbu.conf liegen auch auf
# Sys-Installationen herum -> taugen NICHT als Kriterium).
ROOTFS="$(awk '$2=="/"{print $3; exit}' /proc/mounts)"
if [ "$ROOTFS" = "tmpfs" ] && command -v lbu >/dev/null 2>&1; then
    echo "  Diskless (Root=tmpfs) erkannt -> lbu commit"
    lbu add /opt/notdienst-proxy 2>/dev/null || true
    lbu commit -d || echo "  ! lbu commit fehlgeschlagen (LBU_MEDIA gesetzt?) - manuell pruefen."
else
    echo "  Sys-Installation (Root=$ROOTFS) -> Aenderungen liegen bereits auf Platte."
fi

echo
echo "FERTIG. Nach einem Reboot startet das Geraet ohne Tastatur direkt in die Anzeige."
echo "Test jetzt:  wget -qO- http://127.0.0.1:8080/healthz   (erwartet: ok)"
