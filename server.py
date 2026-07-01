#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Notdienst-Proxy fuer alte Anzeige-Hardware (z.B. AAEON GENE-5315 / AMD Geode LX
ohne SSE2). Holt die Apotheken-Notdienstdaten von der XML-Schnittstelle der
sberg.net-API und liefert sie als extrem einfaches, selbst-aktualisierendes
HTML 4.01 aus - ganz ohne JavaScript, ohne modernes CSS und ohne modernes TLS
auf der Anzeigeseite.

- Der Proxy uebernimmt HTTPS/TLS gegenueber sberg.net.
- Die Anzeige (alter Browser) spricht nur einfaches HTTP mit diesem Proxy.
- Kein SSE2, keine JS-Engine, kein Flexbox/Grid noetig.

Keine externen Abhaengigkeiten - nur Python-3-Standardbibliothek.

Start:  python3 server.py
Dann im Browser der Anzeige:  http://<IP-des-Proxy>:8080/
"""

import os
import sys
import time
import html
import threading
import datetime as dt
import xml.etree.ElementTree as ET
from urllib.request import Request, urlopen
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# --------------------------------------------------------------------------
# Konfiguration (per Umgebungsvariable / .env-Datei ueberschreibbar)
# --------------------------------------------------------------------------

_HERE = os.path.dirname(os.path.abspath(__file__))


def _load_dotenv(path):
    """Minimaler .env-Loader (KEY=VALUE), ohne externe Abhaengigkeit.
    Echte, bereits gesetzte Umgebungsvariablen haben Vorrang."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                os.environ.setdefault(key.strip(),
                                      val.strip().strip('"').strip("'"))
    except FileNotFoundError:
        pass


_load_dotenv(os.path.join(_HERE, ".env"))

# XML-Schnittstelle - MUSS via .env oder Umgebung gesetzt werden. Kein Default
# im Code, da die URL den geheimen Zugangs-Token enthaelt (nicht ins Repo!).
XML_URL = os.environ.get("NOTDIENST_XML_URL", "").strip()

# TCP-Port des Proxy
PORT = int(os.environ.get("NOTDIENST_PORT", "8080"))

# Lausch-Adresse. Default 127.0.0.1: Proxy und Anzeige-Browser laufen auf
# demselben Geraet, es muss also nichts ins Netz. Nur bewusst auf "0.0.0.0"
# setzen, wenn die Anzeige von einem anderen Rechner im LAN geholt wird.
BIND = os.environ.get("NOTDIENST_BIND", "127.0.0.1").strip()

# Logging an/aus. NOTDIENST_LOG=0 (oder false/no/off) schaltet alle Ausgaben
# ab - sinnvoll, damit /var/log/notdienst-proxy.log nicht unbegrenzt waechst.
LOG_ENABLED = os.environ.get("NOTDIENST_LOG", "1").strip().lower() \
    not in ("0", "false", "no", "off", "")

# Wie oft die XML frisch von sberg geholt wird (Sekunden). Der Dienstplan
# aendert sich nur taeglich - alle 2 h reicht und schont die Schnittstelle.
FETCH_INTERVAL = int(os.environ.get("NOTDIENST_FETCH_INTERVAL", "7200"))  # 2 h

# Schnell-Retry, solange noch KEINE Daten vorliegen (Sekunden). Wichtig nach
# Stromausfall: der Cache liegt im Betrieb auf tmpfs (nach Reboot leer) und der
# Router braucht oft laenger als der GENE. Mit dem normalen Abruf-Intervall
# wuerde der healthz-gekoppelte Watchdog (Grace 120s + 6x10s Fehlversuche +
# 60s HW-Timeout ~ 4 min) die Kiste hart resetten, bevor der zweite Abruf
# ueberhaupt drankommt -> Reset-Schleife, bis das Netz zufaellig steht.
FETCH_RETRY_NODATA = int(os.environ.get("NOTDIENST_FETCH_RETRY", "30"))

# Ab wann die Anzeige vor veralteten Daten warnt: zwei Abruf-Intervalle
# (= mindestens ein Abruf fehlgeschlagen), aber nie unter 2 h. Bewusst
# Ganzzahl-Arithmetik (siehe Float-Problem auf der Geode-VM).
STALE_AFTER_H = max(2 * FETCH_INTERVAL, 7200) // 3600

# Wie oft der Anzeige-Browser die Seite neu laedt (Sekunden, meta-refresh)
PAGE_REFRESH = int(os.environ.get("NOTDIENST_PAGE_REFRESH", "300"))  # 5 min

# Wie viele der naechstgelegenen diensthabenden Apotheken angezeigt werden
# (Default 5 - passt auf das 6,5"-Panel AUO G065VN01 V2 mit 640x480)
MAX_ENTRIES = int(os.environ.get("NOTDIENST_MAX_ENTRIES", "5"))

# Pixel-Shift gegen Image-Persistence ("Burn-in"). Das Panel (TFT-LCD) laeuft
# 24/7 mit praktisch statischem Inhalt; roter Balken/Logo/Kartenkanten stehen
# sonst monatelang auf denselben Pixeln -> Ghosting/ungleiche Alterung. DPMS-
# Abschaltung ist hier gesperrt (VESA weckt das Panel nicht wieder auf), also
# verschieben wir den gesamten Seiteninhalt bei jedem Refresh um wenige Pixel.
# NOTDIENST_PIXELSHIFT=0 (false/no/off) schaltet es ab.
PIXEL_SHIFT = os.environ.get("NOTDIENST_PIXELSHIFT", "1").strip().lower() \
    not in ("0", "false", "no", "off", "")

# Ergaenzung zum Pixel-Shift: Hintergrund-Ton pro Refresh minimal variieren.
# Der Shift bewegt v.a. Kanten/Text; die grosse einfarbige Hintergrundflaeche
# erreicht er NICHT (ein weisser Pixel bleibt beim Verschieben weiss). Ein
# leicht wechselnder Ton bewegt genau diese Flaeche und beugt so dem DC-Bias
# vor. Bewusst extrem dezent, damit die Anzeige sauber bleibt.
# NOTDIENST_BGCYCLE=0 (false/no/off) schaltet es ab.
BG_CYCLE = os.environ.get("NOTDIENST_BGCYCLE", "1").strip().lower() \
    not in ("0", "false", "no", "off", "")

# Datei fuer die letzte funktionierende Antwort (ueberlebt Neustart/Ausfall)
CACHE_FILE = os.environ.get(
    "NOTDIENST_CACHE_FILE",
    os.path.join(_HERE, "last_good.xml"),
)

# Zeitzone fuer die Anzeige. zoneinfo ab Python 3.9; sonst fester Offset.
try:
    from zoneinfo import ZoneInfo
    LOCAL_TZ = ZoneInfo(os.environ.get("NOTDIENST_TZ", "Europe/Berlin"))
except Exception:  # pragma: no cover - Fallback fuer sehr alte Python-Versionen
    LOCAL_TZ = dt.timezone(dt.timedelta(hours=2))  # CEST-Naeherung

# Rotes Apotheken-Logo (wird unter /apo-logo.png ausgeliefert)
LOGO_PATH = os.environ.get("NOTDIENST_LOGO", os.path.join(_HERE, "assets", "apo-logo.png"))
try:
    with open(LOGO_PATH, "rb") as _f:
        LOGO_BYTES = _f.read()
except Exception:
    LOGO_BYTES = None

# --------------------------------------------------------------------------
# Daten holen + zwischenspeichern
# --------------------------------------------------------------------------

_lock = threading.Lock()
_state = {
    "xml": None,          # bytes der letzten erfolgreichen Antwort
    "fetched_at": None,   # datetime der letzten erfolgreichen Antwort
    "last_error": None,   # Text des letzten Fehlers
    "last_try_at": None,  # datetime des letzten Versuchs
}


def _load_cache_from_disk():
    try:
        with open(CACHE_FILE, "rb") as f:
            data = f.read()
        if data:
            # Kaputten Cache (z.B. Stromausfall beim Schreiben, defekte CF)
            # nicht uebernehmen - parse_entries wirft dann und der generische
            # except unten faengt es ("Konnte Cache nicht laden").
            parse_entries(data)
            ts = dt.datetime.fromtimestamp(os.path.getmtime(CACHE_FILE), LOCAL_TZ)
            _state["xml"] = data
            _state["fetched_at"] = ts
            log("Cache von Platte geladen (Stand %s)" % ts.isoformat())
    except FileNotFoundError:
        pass
    except Exception as e:  # pragma: no cover
        log("Konnte Cache nicht laden: %r" % e)


def _save_cache_to_disk(data):
    try:
        tmp = CACHE_FILE + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, CACHE_FILE)
    except Exception as e:  # pragma: no cover
        log("Konnte Cache nicht speichern: %r" % e)


def fetch_once():
    """Holt die XML einmal. Aktualisiert bei Erfolg den Cache."""
    _state["last_try_at"] = dt.datetime.now(LOCAL_TZ)
    try:
        req = Request(XML_URL, headers={"User-Agent": "notdienst-proxy/1.0"})
        with urlopen(req, timeout=20) as resp:
            data = resp.read()
        # Plausibilitaetscheck: Container-Struktur vorhanden UND vollstaendig
        # parse-/auswertbar? Wirft bei kaputtem XML -> der Abruf gilt als
        # Fehler und der letzte gute Stand bleibt erhalten. render_page kann
        # sich dadurch darauf verlassen, dass _state["xml"] auswertbar ist.
        if b"<container" not in data:
            raise ValueError("Antwort enthaelt kein <container>-Element")
        entries, _ = parse_entries(data)
        current_and_upcoming(entries, dt.datetime.now(LOCAL_TZ))
        with _lock:
            # Nur schreiben, wenn sich die Daten geaendert haben. Schont die
            # CF-Karte: der Notdienst wechselt ~1x/Tag, ein bedingungsloses
            # Schreiben alle 10 min waere zu ~99% ueberfluessiger Flash-Verschleiss.
            unchanged = data == _state.get("xml")
            _state["xml"] = data
            _state["fetched_at"] = dt.datetime.now(LOCAL_TZ)
            _state["last_error"] = None
        if not unchanged:
            _save_cache_to_disk(data)
            log("XML aktualisiert (%d Bytes)" % len(data))
        else:
            log("XML unveraendert, kein Schreibvorgang")
        return True
    except Exception as e:
        with _lock:
            _state["last_error"] = "%s" % e
        log("Fehler beim Abruf: %r" % e)
        return False


def fetch_loop():
    while True:
        fetch_once()
        with _lock:
            have_data = _state["xml"] is not None
        # Ohne Daten (Erststart/Stromausfall) haeufiger versuchen, damit die
        # Anzeige schnell kommt und der Watchdog nicht vorher resettet.
        time.sleep(FETCH_INTERVAL if have_data else FETCH_RETRY_NODATA)


# --------------------------------------------------------------------------
# XML parsen
# --------------------------------------------------------------------------

def _parse_dt(text):
    """Robust ISO-8601 mit Millisekunden + Offset parsen, versionsunabhaengig.
    Zeitstempel OHNE Offset werden als Lokalzeit interpretiert - naive
    datetimes wuerden sonst beim Vergleich mit dem tz-aware 'now' in
    current_and_upcoming einen TypeError ausloesen."""
    d = _parse_dt_raw(text)
    if d is not None and d.tzinfo is None:
        d = d.replace(tzinfo=LOCAL_TZ)
    return d


def _parse_dt_raw(text):
    if not text:
        return None
    t = text.strip()
    # 'Z' -> '+00:00'
    if t.endswith("Z"):
        t = t[:-1] + "+00:00"
    try:
        return dt.datetime.fromisoformat(t)
    except ValueError:
        pass
    # Fallback: Millisekunden entfernen (".xyz")
    try:
        if "." in t:
            head, rest = t.split(".", 1)
            # rest = "689+00:00" -> Offset abtrennen
            off = ""
            for sep in ("+", "-"):
                idx = rest.find(sep)
                if idx > 0:
                    off = rest[idx:]
                    break
            t2 = head + off
            return dt.datetime.fromisoformat(t2)
    except Exception:
        pass
    return None


def parse_entries(xml_bytes):
    """Gibt (entries, meta) zurueck. entries = Liste von dict."""
    root = ET.fromstring(xml_bytes)
    meta = {
        "code": (root.findtext("code") or "").strip(),
        "created": _parse_dt(root.findtext("created")),
    }
    entries = []
    for e in root.findall("./entries/entry"):
        def g(tag):
            v = e.findtext(tag)
            return v.strip() if v else ""
        # Entfernung als GANZZAHL Meter parsen - KEIN float()!
        # Auf dem Geode (musl/x87, i586 ohne SSE2) ist float()-Parsen von
        # Zahlen-Strings defekt: float("15844.0") liefert dort nan und selbst
        # math.isfinite() antwortet falsch. Deshalb rein ganzzahlig: den Teil
        # vor dem "." nehmen und mit int() lesen (PyLong, keine FPU).
        # dist_m = Entfernung in Metern (int) oder None.
        dist_m = None
        dtxt = g("distance")
        if dtxt:
            intpart = dtxt.split(".", 1)[0].strip()
            if intpart.lstrip("-").isdigit():
                dist_m = int(intpart)
        entries.append({
            "name": g("name"),
            "street": g("street"),
            "zip": g("zipCode"),
            "location": g("location"),
            "sub": g("subLocation"),
            "phone": g("phone"),
            "from": _parse_dt(e.findtext("from")),
            "to": _parse_dt(e.findtext("to")),
            "distance": dist_m,
        })
    return entries, meta


def current_and_upcoming(entries, now):
    """Teilt in 'jetzt im Dienst' und 'kommend', sortiert nach Entfernung."""
    current, upcoming = [], []
    for e in entries:
        f, t = e["from"], e["to"]
        if f and t and f <= now < t:
            current.append(e)
        elif f and f >= now:
            upcoming.append(e)
    dkey = lambda e: (e["distance"] is None, e["distance"] or 0)
    current.sort(key=dkey)
    upcoming.sort(key=lambda e: (e["from"], dkey(e)))
    return current, upcoming


# --------------------------------------------------------------------------
# HTML rendern (HTML 4.01, tabellenbasiert, kein JS)
# --------------------------------------------------------------------------

def esc(s):
    return html.escape(s or "")


def km_num(dist_m):
    """Entfernung (Meter, int) als km-Zahl mit einer Nachkommastelle - REIN
    GANZZAHLIG (keine FPU, siehe Hinweis in parse_entries). 15844 -> '15,8'."""
    if dist_m is None:
        return ""
    tenths = (abs(dist_m) + 50) // 100      # auf Zehntel-km runden
    s = "%d,%d" % (tenths // 10, tenths % 10)
    return ("-" + s) if dist_m < 0 else s


def km(dist_m):
    if dist_m is None:
        return ""
    return km_num(dist_m) + " km"


def fmt_time(d):
    if not d:
        return ""
    return d.astimezone(LOCAL_TZ).strftime("%d.%m. %H:%M")


WEEKDAYS = ["Montag", "Dienstag", "Mittwoch", "Donnerstag",
            "Freitag", "Samstag", "Sonntag"]

# Anti-Burn-in: Muster von (top, left)-Polsterwerten in Pixeln. Der Inhalt
# laeuft ueber die Zeit ein kleines Quadrat entlang. Die jeweils andere Seite
# wird auf (BUDGET - wert) gesetzt, damit die GESAMT-Polsterung pro Achse
# konstant BUDGET (=8px, wie das bisherige padding:4px) bleibt -> der nutzbare
# Platz aendert sich nicht und es entstehen keine neuen Scrollbalken.
_SHIFT_BUDGET = 8
_SHIFT_PATTERN = [(1, 1), (4, 1), (7, 1), (7, 4),
                  (7, 7), (4, 7), (1, 7), (1, 4)]

# Sehr dezente Hintergrund-Toene rund um das bisherige #f4f4f4 (244,244,244):
# max. ~3 Einheiten Abweichung und leichte Warm/Kalt-Verschiebung. So bleibt der
# Kontrast zu den dunklen Texten und den weissen Karten (#fff) unveraendert gut,
# die Flaeche wird aber ueber die Zeit auf verschiedenen Pixelwerten betrieben.
_BG_PALETTE = ["#f4f4f4", "#f4f3f1", "#f3f4f3", "#f1f3f4",
               "#f4f2f3", "#f2f4f2", "#f3f3f4", "#f4f4f2"]


def _shift_step(now):
    """Ganzzahliger Zeitschritt, ein Schritt pro Refresh-Intervall.
    Rein integer (keine FPU, siehe Geode-Hinweis in parse_entries)."""
    return int(now.timestamp()) // max(PAGE_REFRESH, 30)


def pixel_shift_padding(now):
    """Liefert den CSS-'padding'-Shorthand (top right bottom left) fuer den
    aktuellen Zeitschritt. Ohne Pixel-Shift: feste 4px ringsum wie bisher."""
    if not PIXEL_SHIFT:
        b = _SHIFT_BUDGET // 2
        return "%dpx %dpx %dpx %dpx" % (b, b, b, b)
    top, left = _SHIFT_PATTERN[_shift_step(now) % len(_SHIFT_PATTERN)]
    bottom = _SHIFT_BUDGET - top
    right = _SHIFT_BUDGET - left
    return "%dpx %dpx %dpx %dpx" % (top, right, bottom, left)


def bg_color(now):
    """Hintergrundfarbe fuer den aktuellen Zeitschritt (dezente Rotation)."""
    if not BG_CYCLE:
        return _BG_PALETTE[0]
    return _BG_PALETTE[_shift_step(now) % len(_BG_PALETTE)]


def render_entry_row(e):
    ort = esc(e["zip"] + " " + e["location"])
    if e["sub"]:
        ort += " (" + esc(e["sub"]) + ")"
    dienst = ""
    if e["from"] and e["to"]:
        # Dienstzeit in einer Zeile: "Dienst: von"-Zeit &ndash; "bis"-Zeit
        dienst = ("Dienst: " + esc(fmt_time(e["from"]))
                  + " &ndash; " + esc(fmt_time(e["to"])))
    # Entfernung aufgeteilt in Zahl + Einheit fuer die rote Kachel-Anzeige
    dnum, dunit = "", ""
    if e["distance"] is not None:
        dnum = km_num(e["distance"])
        dunit = "km"
    return (
        '<div class="card">'
        '<table class="cardtbl" width="100%%" cellspacing="0" cellpadding="0">'
        '<tr>'
        '<td class="cinfo">'
        '<div class="name">%s</div>'
        '<div class="adr">%s, %s</div>'
        '<div class="tel">Tel. %s</div>'
        '</td>'
        '<td class="cdist">'
        '<div class="distnum">%s <span class="distunit">%s</span></div>'
        '</td>'
        '</tr>'
        '<tr>'
        '<td class="dienst" colspan="2">%s</td>'
        '</tr>'
        '</table>'
        '</div>'
    ) % (esc(e["name"]), esc(e["street"]), ort, esc(e["phone"]), dnum, dunit, dienst)


def render_page():
    now = dt.datetime.now(LOCAL_TZ)
    with _lock:
        xml_bytes = _state["xml"]
        fetched_at = _state["fetched_at"]
        last_error = _state["last_error"]

    body_rows = ""
    stale_note = ""
    header_error = ""

    if xml_bytes is None:
        header_error = ('<p class="err">Noch keine Daten verfuegbar. '
                        'Der Proxy versucht gerade, die Notdienstdaten zu laden. '
                        'Diese Seite aktualisiert sich automatisch.</p>')
    else:
        try:
            entries, meta = parse_entries(xml_bytes)
            current, _ = current_and_upcoming(entries, now)
            if current:
                for e in current[:MAX_ENTRIES]:
                    body_rows += render_entry_row(e)
            else:
                body_rows = ('<div class="card"><div class="adr">Derzeit kein '
                             'Eintrag fuer den aktuellen Zeitraum gefunden.</div></div>')
        except Exception as e:
            # Letztes Auffangnetz - sollte nicht mehr vorkommen, da das XML
            # schon bei Abruf und Cache-Load komplett validiert wird. Ehrlich
            # bleiben: hier wird NICHTS angezeigt, also das auch so sagen.
            header_error = ('<p class="err">Daten konnten nicht ausgewertet '
                            'werden (%s). Anzeige derzeit nicht moeglich; '
                            'naechster Datenabruf folgt automatisch.</p>'
                            % esc(str(e)))

    # Hinweis auf Alter der Daten
    if fetched_at is not None:
        age = now - fetched_at
        stand = fetched_at.strftime("%d.%m.%Y %H:%M")
        if age > dt.timedelta(hours=STALE_AFTER_H):
            stale_note = ('<p class="stale">Achtung: Daten sind aelter als '
                          '%d Stunden (Stand %s). Verbindung zum Server pruefen.</p>'
                          % (STALE_AFTER_H, stand))
        std_line = "Stand: %s" % stand
    else:
        std_line = "Stand: unbekannt"
    if last_error and xml_bytes is not None:
        std_line += " (letzter Abruf fehlgeschlagen)"

    heute = "%s, %s" % (WEEKDAYS[now.weekday()], now.strftime("%d.%m.%Y %H:%M"))

    page = PAGE_TEMPLATE % {
        "refresh": PAGE_REFRESH,
        "heute": esc(heute),
        "header_error": header_error,
        "stale_note": stale_note,
        "rows": body_rows,
        "stand": esc(std_line),
        "bodypad": pixel_shift_padding(now),
        "bodybg": bg_color(now),
    }
    return page.encode("utf-8")


PAGE_TEMPLATE = """<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
<meta http-equiv="refresh" content="%(refresh)d">
<title>Apotheken-Notdienst</title>
<style type="text/css">
/* Kompaktes Layout, abgestimmt auf 6,5" 640x480 (AUO G065VN01 V2) */
/* WICHTIG: NetSurf zeigt Fenster-Scrollbalken, sobald die Seite hoeher ist als
   der sichtbare Bereich (640x480 minus NetSurf-Statuszeile ~ 20px). overflow
   allein entfernt sie NICHT -> das Layout muss schlicht passen. Bei 5 Karten
   ist es knapp; wenn Scrollbalken auftauchen: NOTDIENST_MAX_ENTRIES=4 setzen. */
html, body { overflow:hidden; }
/* padding wird pro Refresh minimal variiert (Anti-Burn-in Pixel-Shift); die
   Gesamt-Polsterung bleibt je Achse konstant, damit der Platz gleich bleibt. */
body { background:%(bodybg)s; color:#1a1a1a;
       font-family:Arial,Helvetica,sans-serif; font-style:normal; margin:0; padding:%(bodypad)s; }
table.hdr { width:100%%; border-collapse:collapse; margin-bottom:4px; }
table.hdr td { vertical-align:middle; border:0; padding:0; }
.logo { height:30px; width:auto; }
.htitle { font-size:18px; font-weight:bold; color:#bb1e10; padding-left:7px; }
.hdate { font-size:11px; color:#333333; text-align:right; white-space:nowrap; }
.rule { height:3px; background:#bb1e10; font-size:1px; line-height:3px; margin:0 0 5px 0; }
h2 { font-size:12px; color:#bb1e10; margin:4px 0 3px 0; }
.card { background:#ffffff; border:1px solid #e2e2e2; border-left:5px solid #bb1e10;
        margin:0 0 4px 0; padding:3px 8px; }
table.cardtbl { border-collapse:collapse; width:100%%; }
table.cardtbl td { border:0; vertical-align:top; padding:0; }
.name { font-size:19px; font-weight:bold; font-style:normal; color:#1a1a1a; }
.adr  { font-size:14px; color:#555555; margin:2px 0; }
.tel  { font-size:18px; font-weight:bold; font-style:normal; color:#111111; }
.cdist { text-align:right; width:132px; vertical-align:top; }
.distnum { font-size:22px; font-weight:bold; font-style:normal; color:#bb1e10; white-space:nowrap; }
.distunit { font-size:13px; color:#bb1e10; font-weight:bold; font-style:normal; }
.dienst { font-size:11px; color:#999999; text-align:right; white-space:nowrap; padding-top:2px; }
.foot { margin-top:3px; font-size:9px; color:#888888; }
.err  { font-size:14px; color:#bb1e10; font-weight:bold; }
.stale{ font-size:12px; color:#bb1e10; font-weight:bold; }
</style>
</head>
<body>
<table class="hdr" cellspacing="0" cellpadding="0"><tr>
<td width="54"><img class="logo" src="/apo-logo.png" alt="Apotheke"></td>
<td class="htitle">Apotheken-Notdienst</td>
<td class="hdate">%(heute)s</td>
</tr></table>
<div class="rule"></div>
%(header_error)s
%(stale_note)s
<h2>Diensthabende Apotheke</h2>
%(rows)s
<p class="foot">%(stand)s &middot; Anzeige aktualisiert sich automatisch.</p>
</body>
</html>
"""


# --------------------------------------------------------------------------
# HTTP-Server
# --------------------------------------------------------------------------

def log(msg):
    if not LOG_ENABLED:
        return
    sys.stderr.write("[%s] %s\n" % (dt.datetime.now().strftime("%H:%M:%S"), msg))
    sys.stderr.flush()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # bewusst simpel fuer alte Clients

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html", "/notdienst"):
            try:
                body = render_page()
            except Exception as e:  # pragma: no cover
                log("Renderfehler: %r" % e)
                body = ("<html><body><h1>Fehler</h1><p>%s</p></body></html>"
                        % esc(str(e))).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=UTF-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(body)
        elif path == "/apo-logo.png":
            if LOGO_BYTES is None:
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(LOGO_BYTES)))
            self.send_header("Cache-Control", "max-age=86400")
            self.end_headers()
            self.wfile.write(LOGO_BYTES)
        elif path == "/healthz":
            with _lock:
                ok = _state["xml"] is not None
            body = (b"ok" if ok else b"no-data")
            self.send_response(200 if ok else 503)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            body = b"Not found"
            self.send_response(404)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, fmt, *args):
        # ruhiger halten; nur Fehler ueber log()
        pass


def main():
    if not XML_URL:
        log("FEHLER: NOTDIENST_XML_URL ist nicht gesetzt.")
        log("Bitte .env anlegen (Vorlage: .env.example) oder Umgebungsvariable setzen.")
        sys.exit(2)
    _load_cache_from_disk()
    # Erststart: einmal synchron holen, damit sofort Daten da sind.
    fetch_once()
    t = threading.Thread(target=fetch_loop, daemon=True)
    t.start()
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    log("Notdienst-Proxy laeuft auf http://%s:%d/" % (BIND, PORT))
    log("XML-Abruf alle %ds, Seiten-Refresh alle %ds" % (FETCH_INTERVAL, PAGE_REFRESH))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("Beende.")


if __name__ == "__main__":
    main()
