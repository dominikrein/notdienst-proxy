#!/bin/sh
# build-netsurf.sh  --  NetSurf (GTK3) aus Quelltext bauen.
#
# WARUM aus Quelltext? NetSurf ist fuer x86 (32-bit) nur in Alpine-edge
# paketiert. edge scheidet auf dem Geode LX aber aus: dessen CPU kennt kein
# NOPL (0F 1F) -> edge-Binaries crashen mit "Illegal Instruction". Baut man
# NetSurf auf der Alpine-3.18-Toolchain, erbt das Binary die Geode-sichere
# Baseline (kein NOPL/SSE2) -> laeuft.
#
# NetSurf ist bewusst gewaehlt: eigene, schlanke Rendering-Engine (kein WebKit,
# kein SSE2 noetig) und unterstuetzt <meta refresh> -> die Proxy-Seite
# aktualisiert sich selbst, ganz ohne Reload-Trick.
#
# Ergebnis:  /usr/local/bin/netsurf-gtk3   (+ Ressourcen unter /usr/local/share)
#
# Aufruf (als root):  sh deploy/build-netsurf.sh
# Version override:   NETSURF_VERSION=3.10 sh deploy/build-netsurf.sh
set -e

VER="${NETSURF_VERSION:-3.11}"
TARBALL="netsurf-all-${VER}.tar.gz"
URL="https://download.netsurf-browser.org/netsurf/releases/source-full/${TARBALL}"
WORK="${TMPDIR:-/tmp}/netsurf-build"

echo "== Runtime-Bibliotheken (bleiben nach dem Build) =="
# Explizit installieren, damit sie nicht als verwaiste Build-Dep entfernt werden.
apk add --no-cache ca-certificates wget \
    gtk+3.0 libcurl libpng libjpeg-turbo libwebp lcms2

echo "== Build-Abhaengigkeiten (virtuell -> am Ende entfernbar) =="
# coreutils WICHTIG: NetSurfs Buildsystem nutzt 'install -C' (GNU-Flag), das
# BusyBox-install nicht kennt -> ohne coreutils bricht der Build ab.
apk add --no-cache --virtual .nsbuild \
    build-base coreutils pkgconf perl flex bison gperf \
    gtk+3.0-dev curl-dev openssl-dev libpng-dev libjpeg-turbo-dev \
    libwebp-dev lcms2-dev

echo "== Quelltext holen: $URL =="
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"
wget -q "$URL"
tar xzf "$TARBALL"
cd "netsurf-all-${VER}"

echo "== Workaround: 'to-pixdata' aus GResource entfernen =="
# glib-compile-resources kann die XPM-Icons per to-pixdata nicht konvertieren
# (gdk-pixbuf-Loader fehlt) -> Build bricht ab. to-pixdata ist ohnehin von glib
# deprecated. Raus damit: die Bytes werden roh eingebettet, Icons laden zur
# Laufzeit (auf dem Vollbild-Kiosk ohnehin unsichtbar).
find netsurf/frontends/gtk/res -name '*.gresource.xml' \
    -exec sed -i 's/ preprocess="to-pixdata"//g' {} + 2>/dev/null || true

# HINWEIS: Kein Ausblenden von Statuszeile/Scrollbalken per tabcontents.ui-Patch!
# Wir haben es probiert (vscrollbar + hpaned1 auf visible=False/no_show_all) ->
# NetSurf rendert dann eine WEISSE Seite (die Layout-Flaeche bekommt keine
# Groesse mehr). Also bewusst NICHT gepatcht. Statuszeile/Scrollbalken werden
# stattdessen zur Laufzeit per GTK-CSS auf 0px kollabiert (gtk.css, geschrieben
# von der xinitrc-kiosk); Toolbar/Menue via Choices bar_show:none.

echo "== Bauen (TARGET=gtk3) - dauert ein paar Minuten =="
make TARGET=gtk3

echo "== Installieren nach /usr/local =="
make TARGET=gtk3 PREFIX=/usr/local install

echo "== Aufraeumen =="
cd /
rm -rf "$WORK"
# Build-Deps wieder entfernen (Runtime-Libs oben bleiben erhalten).
# Auf grossen Medien optional; spart auf der CF Platz.
apk del .nsbuild 2>/dev/null || true

if command -v netsurf-gtk3 >/dev/null 2>&1; then
    echo "FERTIG: $(command -v netsurf-gtk3)"
else
    echo "!! netsurf-gtk3 nicht im PATH - Build fehlgeschlagen? Log oben pruefen." >&2
    exit 1
fi
