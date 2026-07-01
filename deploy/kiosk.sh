#!/bin/sh
# Kiosk-Start fuer die Notdienst-Anzeige auf dem GENE-5315 (Geode LX, kein SSE2).
#
# Zeigt die lokale Proxy-Seite im Vollbild mit NetSurf an.
# NetSurf unterstuetzt <meta refresh> (anders als Dillo) -> die Seite
# aktualisiert sich von selbst; ein Reload-Trick ist nicht noetig.
#
# Anzeige ueber X11. Der Alpine-lts-Kernel bringt fuer den Geode LX KEINEN
# Framebuffer mit (kein lxfb/gxfb/vesafb -> kein /dev/fb0), und einen
# xf86-video-geode-Treiber gibt es in Alpine nicht. Deshalb X11 mit
# xf86-video-vesa (VESA-BIOS/int10) - braucht kein /dev/fb0 und kein DRM/KMS.
#
# Aufruf am Ende von /etc/local.d oder aus dem Autologin-Profil:
#   sh /opt/notdienst-proxy/kiosk.sh

# Bewusst 127.0.0.1 statt "localhost": der Proxy lauscht nur auf IPv4-Loopback
# (NOTDIENST_BIND=127.0.0.1). "localhost" koennte via /etc/hosts auf ::1 (IPv6)
# aufloesen und dann ins Leere laufen.
URL="http://127.0.0.1:8080/"

# Auf den Proxy warten, bis er antwortet (max ~60s).
i=0
while [ $i -lt 60 ]; do
    if wget -q -O /dev/null "$URL"; then
        break
    fi
    i=$((i + 1))
    sleep 1
done

# FLASH-SCHUTZ (Stufe 1): X-Authority-Datei auf tmpfs (/run) statt nach
# $HOME/.Xauthority (= Flash). startx/xinit erzeugt und beschreibt diese Datei
# bei jedem Start - im RAM verschleisst das keinen Flash. /run ist auf Alpine
# immer tmpfs. XDG-Cache/Config von NetSurf werden in der xinitrc umgeleitet.
export XAUTHORITY=/run/kiosk-xauth

# --- Anzeige: X11 (VESA), ohne Fenstermanager ------------------------------
# Benoetigt (via setup-kiosk.sh): xorg-server xf86-video-vesa xinit + das aus
# Quelltext gebaute netsurf-gtk3. startx nimmt sich die aktuelle Konsole (tty1),
# deshalb aus dem Autologin auf tty1 aufrufen. Die xinitrc-kiosk setzt die
# Panelgroesse und startet netsurf-gtk3 im Vollbild.
exec startx /opt/notdienst-proxy/xinitrc-kiosk
