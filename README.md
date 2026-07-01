# Notdienst-Proxy für alte Anzeige-Hardware (GENE-5315 / Geode LX)

Zeigt die Apotheken-Notdienstdaten der sberg.net-XML-Schnittstelle auf einem
**AAEON GENE-5315 Rev. B** (AMD Geode LX 800, **kein SSE2**, 512 MB RAM,
4 GB CompactFlash) an.

## Warum ein Proxy?

Die Original-Webseite ist eine moderne JavaScript-SPA und lädt ihre Daten per
HTTPS (TLS 1.2/1.3, Let's-Encrypt-Kette über *ISRG Root X1*). Der Geode LX kann
**keine modernen Browser** ausführen (Firefox/Chrome brauchen seit Jahren SSE2,
das die CPU nicht hat), und ein alter Browser scheitert zusätzlich an TLS und
JavaScript.

Der Proxy löst beides serverseitig:

- Er holt die Daten über die **XML-Schnittstelle** (TLS erledigt modernes
  OpenSSL auf dem Gerät) und
- liefert **ultrakonservatives HTML 4.01** ohne JavaScript, ohne modernes CSS,
  mit `<meta refresh>` zur Selbst-Aktualisierung.

Das rendert selbst ein winziger Browser wie **NetSurf** – ganz ohne SSE2.

## Architektur (autark auf dem GENE)

```
GENE-5315  ──  Alpine Linux x86 (32-bit)
                 ├─ server.py   → OpenRC-Dienst, http://localhost:8080/
                 │                 holt XML per HTTPS von notdienst.sberg.net
                 └─ NetSurf (X11-Kiosk, xf86-video-vesa) → http://localhost:8080/
```

Alles läuft auf einem einzigen Gerät. Kein zweiter Rechner nötig.

## Warum Alpine + NetSurf?

- **Alpine Linux x86** läuft nachweislich auf Geode-LX-Boards (die PC-Engines-
  *ALIX* nutzt denselben Chip; es gibt eine offizielle Alpine-Anleitung dafür).
  Winzig, modernes OpenSSL, aktuelles Python 3.
- **NetSurf** ist extrem genügsam (~16 MB RAM), braucht kein SSE2 **und
  unterstützt `<meta refresh>`**. Dillo wäre noch kleiner, ignoriert aber
  bewusst Meta-Refresh mit Verzögerung – daher NetSurf.

## Installation auf dem GENE

### 0. Bootmedium vorbereiten (CompactFlash am PC)

Mit einem **CF-Kartenleser** ist das der zuverlässigste Weg – ganz ohne
USB-Boot-Glücksspiel: Die CF wird am normalen PC bespielt und fertig in den GENE
gesteckt. Der GENE bootet direkt von seiner CF (er sieht sie als PATA-Platte).

**Alpine x86 herunterladen:** die *Extended*- oder *Standard*-ISO von
<https://alpinelinux.org/downloads/> aus der Spalte **x86** (32-bit, **nicht**
x86_64!).

**CF bespielen** (CF im Reader am PC). Ziel ist eine **beschreibbare
FAT32-CF**, weil der empfohlene **Diskless-Betrieb** (Schritt 1) seine
Konfiguration direkt auf die CF zurückschreibt:

- **Windows (empfohlen):** [Rufus](https://rufus.ie), Ziel = CF, die
  Alpine-x86-ISO auswählen. Fragt Rufus „ISO-Image- oder DD-Image-Modus?", den
  **ISO-Image-Modus** wählen – der entpackt die Dateien auf eine **beschreibbare
  FAT32-Partition** und installiert den Bootloader (syslinux). Genau das braucht
  Diskless.
  - *Nur zum schnellen Boot-Test* ginge auch der **DD-Modus** – der erzeugt aber
    ein **schreibgeschütztes** Live-System (Konfig geht beim Neustart verloren),
    also nicht für den Dauerbetrieb.
- **Linux:** am einfachsten aus einem laufenden Alpine heraus
  `apk add syslinux dosfstools && setup-bootable -v <iso> /dev/sdX` (formatiert
  FAT32, installiert syslinux, kopiert die ISO). `/dev/sdX` = die CF prüfen!

**CF in den GENE, einschalten.** Im BIOS/Setup (meist `Entf`/`F2`) ggf. die
CF bzw. „IDE"/„HDD" als erstes Bootgerät setzen. Erscheint der Alpine-Login
(`root`, kein Passwort) → geschafft, weiter mit Schritt 1.

*USB-Stick als Alternative:* Falls du doch per Stick bootest, gilt dasselbe
Schreibverfahren (Ziel = Stick). Ob der alte Geode-BIOS von USB bootet, ist aber
nicht garantiert; der CF-Weg oben umgeht das. Notnagel, wenn USB gar nicht geht:
[PLoP Boot Manager](https://www.plop.at/de/bootmanager/) von CD/Diskette.

### 1. Alpine Linux x86 installieren

Nach dem ersten Boot von der CF als `root` anmelden. **Empfohlen: Diskless-Modus**
(System läuft aus dem RAM, die Konfiguration wird als `*.apkovl.tar.gz` auf die
FAT32-CF zurückgeschrieben – schont die CF).

**Diskless einrichten:**

```sh
setup-alpine
```

Beim Assistenten:

- Tastatur, Hostname, **Netzwerk** (wird gebraucht, um python3/netsurf zu laden).
- **„Which disk(s) would you like to use?" → `none`** eingeben. Das ist der
  entscheidende Schritt: `none` = kein Festplatten-Install, Gerät bleibt diskless.
- **„Enter where to store configs" →** die CF-Bootpartition auswählen (z. B.
  `sda1`; der GENE sieht die CF als PATA-Platte). Dorthin schreibt `lbu` später
  das Overlay.
- **„Enter apk cache directory" →** dieselbe CF-Partition wählen (z. B.
  `/media/sda1/cache`) – **wichtig**, damit python3/netsurf lokal auf der CF
  liegen und das Gerät auch offline/ohne schnelles Netz zuverlässig hochkommt.

Danach den Proxy + Kiosk einspielen (Schritt 2–4). `deploy/setup-kiosk.sh` erkennt
Diskless automatisch und führt am Ende `lbu commit` aus – erst damit sind alle
Änderungen dauerhaft auf der CF. **Faustregel: nach jeder Änderung `lbu commit`.**

> **Alternative – `sys`-Installation:** Falls die beschreibbare CF nicht bootet
> oder du es einfacher willst: `setup-alpine` und beim Disk-Schritt die CF mit
> Modus **`sys`** wählen. Installiert Alpine fest auf die CF wie auf eine
> Festplatte – kein `lbu` nötig, Änderungen liegen sofort auf Platte. Etwas mehr
> Schreibzugriffe, was bei der geringen Schreiblast dieses Kiosks aber
> unkritisch ist.

Geode-Fallstricke (unbedingt beachten):

- **Alpine-Version: zwingend 3.18 (x86).** Der Geode LX ist i586-Klasse **ohne
  NOPL/SSE2**. edge und neuere x86-Builds emittieren NOPL (`0F 1F`) → auf echter
  Hardware **„Illegal Instruction"**. 3.18 ist EOL, aber die einzige erprobte
  Basis. **Niemals `apk upgrade` auf edge.** Eine Bake-VM auf modernem Host
  zeigt den Crash nicht – nur der echte GENE.
- Problematisches Modul blacklisten:
  ```
  echo "blacklist cs5535_mfgpt" > /etc/modprobe.d/geode.conf
  ```
- Grafik: **X11 mit `xf86-video-vesa`.** Der Alpine-lts-Kernel bringt für den
  Geode LX **keinen Framebuffer** mit (kein `lxfb`/`gxfb`/`vesafb` → `/dev/fb0`
  fehlt), und **`xf86-video-geode` gibt es in Alpine nicht**. Also X11 über den
  VESA-BIOS-Treiber (int10) – braucht kein `/dev/fb0`, kein DRM/KMS, kein mesa.

### 2. Pakete

Der ganze Software-Teil steckt in **`deploy/setup-kiosk.sh`** (Repos, X11-Stack,
NetSurf-Build, Dienst, Autologin – siehe unten). Was dabei passiert:

```sh
# X11 schlank (KEIN setup-xorg-base -> das zöge mesa-dri-gallium + llvm ~150 MB):
apk add python3 xorg-server xf86-video-vesa xf86-input-libinput xinit \
        xset xrandr ttf-dejavu font-misc-misc
```

> **NetSurf ist in 3.18/x86 nicht paketiert** (nur in edge – und edge scheidet
> wegen NOPL aus). Deshalb baut `deploy/build-netsurf.sh` NetSurf **aus
> Quelltext** auf der 3.18-Toolchain; das Binary erbt die Geode-sichere Baseline
> (kein NOPL/SSE2) und unterstützt `<meta refresh>`. Ergebnis:
> `/usr/local/bin/netsurf-gtk3`. Ein Fenstermanager ist nicht nötig – NetSurf
> öffnet per `Choices`-Datei direkt in Panelgröße (640×480).

### 3. Zero-Touch-Boot einrichten (ein Befehl)

Vorher die `.env` mit dem Zugangs-Token neben `server.py` anlegen (siehe
Abschnitt **Konfiguration**), sonst startet der Proxy nicht.

```sh
sh deploy/setup-kiosk.sh
```

Das Skript richtet **alles** ein: Proxy nach `/opt/notdienst-proxy` kopieren,
OpenRC-Dienst installieren + starten, Autologin auf tty1, Kiosk-Autostart,
Konsolen-Blanking aus, Geode-Modul geblacklistet – und bei Diskless-Installation
`lbu commit`, damit alles auf der CF persistiert. Danach: reboot → Anzeige.

### 4. Testen

```sh
wget -qO- http://127.0.0.1:8080/healthz   # -> ok
```

> **Hinweis Bind-Adresse:** Der Proxy lauscht per Default nur auf `127.0.0.1`
> (IPv4-Loopback), da Anzeige und Proxy auf demselben Gerät laufen – so ist
> nichts unnötig im Netz offen. Deshalb `127.0.0.1` statt `localhost` testen
> (`localhost` kann via `/etc/hosts` auf `::1`/IPv6 zeigen und dann ins Leere
> laufen). Soll die Anzeige von einem **anderen** Rechner im LAN geholt werden:
> `NOTDIENST_BIND=0.0.0.0` in der `.env` setzen.

> **Manuell statt per Skript** (Fallback / zum Verständnis – nicht nötig, wenn
> `setup-kiosk.sh` gelaufen ist):
>
> ```sh
> install -d /opt/notdienst-proxy
> cp server.py /opt/notdienst-proxy/
> cp deploy/kiosk.sh /opt/notdienst-proxy/
> cp deploy/xinitrc-kiosk /opt/notdienst-proxy/   # nur für X11-Variante
> install -m755 deploy/notdienst-proxy.openrc /etc/init.d/notdienst-proxy
> rc-update add notdienst-proxy default
> rc-service notdienst-proxy start
> ```

### 5. Fernzugang per SSH (optional, ins Image gebacken)

Ziel: **Image auf CF schreiben → booten → sshd läuft → Anmeldung mit einem
Initial-Passwort**, ganz ohne Tastatur am Gerät. Dazu läuft das SSH-Setup schon
beim Bauen des goldenen Overlays mit – non-interaktiv, das Passwort kommt als
`INIT_ROOT_PW` einmal zur Build-Zeit rein und landet als **Hash** im Overlay:

```sh
INIT_ROOT_PW='DeinInitialPasswort' sh deploy/setup-ssh.sh
```

Das installiert `openssh`, erlaubt Root-Login **per Passwort**, setzt das
Passwort und persistiert im Diskless-Modus via `lbu commit` alles auf die CF
(Passwort-Hash, sshd-Config, Host-Keys). Das so erzeugte `*.apkovl.tar.gz` ist
Teil des Provisioning-Images (siehe **Stufe 2** unten) – jede damit bespielte CF
bootet mit laufendem sshd und du meldest dich an mit:

```sh
ssh root@<IP-des-Geräts>      # Initial-Passwort, danach am Gerät: passwd
```

> **Passwortwechsel erzwingen (optional):** `FORCE_PW_CHANGE=1` zusätzlich
> setzen, dann muss das Initial-Passwort bei der ersten Anmeldung geändert
> werden.
>
> **Interaktiv statt gebacken:** ohne `INIT_ROOT_PW` fragt das Skript das
> Passwort per `passwd` am Gerät ab.

> **Sicherheit:** Root-Login mit Passwort über SSH wird im Netz brute-force-
> gescannt, und das Initial-Passwort steckt (als Hash) auf jeder geklonten CF.
> Nur in einem vertrauenswürdigen **internen LAN** betreiben, **nicht** ins
> Internet forwarden, und das Passwort nach der ersten Anmeldung ändern.
> Sicherer ist Key-Auth – dann statt Passwort:
>
> ```sh
> sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
> mkdir -p /root/.ssh && chmod 700 /root/.ssh
> echo "ssh-ed25519 AAAA... dein-key" > /root/.ssh/authorized_keys
> chmod 600 /root/.ssh/authorized_keys
> lbu commit -d
> ```
>
> **Serie mit eindeutigen Host-Keys:** Beim Overlay-Klonen teilen sich alle
> Geräte die Host-Keys aus dem Image. Für eindeutige Keys pro Gerät auf jeder
> Klon-CF vor dem Erst-Boot `/etc/ssh/ssh_host_*` löschen – sshd erzeugt sie
> beim Booten neu.

### 6. Selbstheilung per Hardware-Watchdog (optional)

Damit sich die Schaufenster-Kiste bei einem Absturz **selbst neu startet** –
genau wie es das alte ApoShow-System über den Super-I/O-Watchdog tat. Nach
`setup-kiosk.sh` ausführen:

```sh
sh deploy/setup-watchdog.sh
```

Das Skript erkennt das passende Watchdog-Kernelmodul automatisch (probiert die
Super-I/O-Treiber durch, fällt notfalls auf `softdog` zurück), lädt es und
richtet den OpenRC-Dienst **`notdienst-watchdog`** ein. Dessen Feeder
(`watchdog-feed.sh`) füttert `/dev/watchdog` nur, solange der Proxy über
`/healthz` gesund antwortet.

> **`geodewdt` scheidet aus:** Die Geode-eigene Watchdog-Variante braucht
> `cs5535_mfgpt`, das in Schritt 1 bewusst geblacklistet ist. Genutzt wird
> daher der Super-I/O-Watchdog (den ApoShow schon über Port 0x370/0x371 ansprach).

**Was abgefangen wird:** Ein kompletter Box-Hänger (Kernel/X eingefroren) und
ein toter Proxy bzw. einer ohne Daten (`healthz` 503) führen zum Hardware-Reset.
Fällt nur der Upstream-Datenserver aus, passiert bewusst **nichts** – die Daten
bleiben gecacht. Nicht erkannt wird eine eingefrorene NetSurf-**Anzeige**,
solange `server.py` noch antwortet (`healthz` prüft nur den Proxy, nicht das
Bild).

**Wartung / abschalten** (Default `nowayout=0`):

```sh
rc-service notdienst-watchdog stop     # Watchdog sofort aus, KEIN Reboot
# ... Wartung ...
rc-service notdienst-watchdog start    # wieder scharf
```

Der Feeder fängt das Stopp-Signal ab und schaltet den Watchdog sauber ab
(Magic-Close). Der Health-Gate-Reset funktioniert trotzdem, weil der Feeder bei
totem Proxy aufhört zu füttern und das Device dabei **offen hält**.

**Optionen** (beim Einrichten als Umgebungsvariablen):

| Variable | Bedeutung | Default |
|---|---|---|
| `WDT_TIMEOUT` | Hardware-Timeout in s (Hänger-Toleranz) | `60` |
| `WDT_NOWAYOUT` | `1` = bombensicher (auch `kill -9`/OOM → Reset), aber `stop` = Reboot | `0` |

```sh
# Beispiel: mehr Puffer + kompromisslos
WDT_TIMEOUT=120 WDT_NOWAYOUT=1 sh deploy/setup-watchdog.sh
```

## Zero-Touch: die zwei Stufen

**Stufe 1 – Zero-Touch-Boot** (einmal einrichten, dann bei jedem Einschalten
automatisch): erledigt `setup-kiosk.sh` (siehe oben). Ablauf beim Booten:

```
Power on → Alpine → Autologin root@tty1 → /root/.profile → kiosk.sh
         → wartet auf Proxy → NetSurf Vollbild → Anzeige
```

Der Proxy selbst startet unabhängig davon als OpenRC-Dienst.

**Stufe 2 – Zero-Touch-Provisioning** (fertiges Abbild, nur noch auf CF spielen).
Empfohlen für die CF-Schonung ist der **Diskless-Modus** (System läuft aus dem
RAM, minimale Schreibzugriffe – wichtig für die Lebensdauer der CompactFlash):

- Alpine einmal aufsetzen, `setup-kiosk.sh` laufen lassen. Für SSH im Image
  zusätzlich `INIT_ROOT_PW='…' sh deploy/setup-ssh.sh` (siehe Schritt 5).
  Danach `lbu commit`.
- Das erzeugte `*.apkovl.tar.gz` auf der CF ist die komplette Konfiguration –
  inkl. sshd + Passwort-Hash, falls Schritt 5 mitgelaufen ist.
- Für eine Serie: dieses Overlay sichern und auf weitere CF-Karten neben ein
  Standard-Alpine-Bootmedium legen → jedes Gerät bootet identisch, zero touch,
  sshd läuft direkt (Host-Key-Hinweis in Schritt 5 beachten).

Alternativ lässt sich mit Alpines `mkimage.sh` (aports/scripts) und einem
eigenen Profil ein vollständig gebackenes Image bauen – lohnt sich erst bei
größeren Stückzahlen.

### Kiosk-Details

`kiosk.sh` wartet, bis der Proxy antwortet, und startet dann per `startx` die
`deploy/xinitrc-kiosk`: **ohne Fenstermanager**, NetSurf (GTK, aus Quelltext
gebaut) im Vollbild über `xf86-video-vesa`. NetSurf öffnet per `Choices`-Datei
in Panelgröße (640×480). Der Framebuffer-Weg (`netsurf-fb`) ist auf dem
Stock-Alpine-Kernel mangels `/dev/fb0` nicht nutzbar.

## Konfiguration

Die Konfiguration kommt aus einer **`.env`-Datei** neben `server.py` (per
`.gitignore` vom Repo ausgeschlossen, da sie den Zugangs-Token enthält) oder
aus echten Umgebungsvariablen (diese haben Vorrang). Anlegen:

```sh
cp .env.example .env
# dann in .env die echte NOTDIENST_XML_URL eintragen
```

`server.py` liest folgende Werte (Defaults in Klammern):

| Variable | Bedeutung | Default |
|---|---|---|
| `NOTDIENST_XML_URL` | XML-Schnittstelle (**Pflicht**, enthält Token) | – |
| `NOTDIENST_BIND` | Bind-Adresse (`0.0.0.0` = im LAN erreichbar) | `127.0.0.1` |
| `NOTDIENST_PORT` | HTTP-Port des Proxy | `8080` |
| `NOTDIENST_FETCH_INTERVAL` | XML-Abruf-Intervall (s) | `600` |
| `NOTDIENST_FETCH_RETRY` | Abruf-Intervall, solange noch keine Daten da sind (s) | `30` |
| `NOTDIENST_PAGE_REFRESH` | Browser-Refresh (s) | `300` |
| `NOTDIENST_MAX_ENTRIES` | Anzahl angezeigter Apotheken | `5` |
| `NOTDIENST_PIXELSHIFT` | Anti-Burn-in-Pixelshift (`0` = aus) | `1` |
| `NOTDIENST_BGCYCLE` | Dezente Hintergrund-Tonrotation (`0` = aus) | `1` |
| `NOTDIENST_LOG` | `0` = Logging aus (Log-Datei wächst nicht) | `1` |
| `NOTDIENST_LOGO` | Pfad zum Logo-PNG (siehe Hinweis unten) | `assets/apo-logo.png` |
| `NOTDIENST_TZ` | Zeitzone | `Europe/Berlin` |

> **Logo nicht im Repo:** Das rote Apotheken-A ist eine eingetragene Marke des
> Deutschen Apothekerverbands und darf nur von Apotheken verwendet werden –
> deshalb liegt es nicht im Repo. Ein eigenes Logo als
> `assets/apo-logo.png` ablegen (oder Pfad per `NOTDIENST_LOGO` setzen);
> fehlt die Datei, liefert der Proxy dafür 404 und die Seite läuft ohne Logo.

## Robustheit

- Die letzte erfolgreiche Antwort wird auf Platte gecacht (`last_good.xml`) und
  übersteht Neustart und kurze Netzausfälle.
- Ist der Abruf fehlgeschlagen, zeigt die Seite weiter den letzten gültigen
  Stand samt „Stand: …"-Zeitstempel; ab 2 h Alter erscheint ein Warnhinweis.
- Solange noch keine Daten vorliegen (Erststart, Reboot nach Stromausfall mit
  leerem tmpfs-Cache), wird alle 30 s statt alle 10 min abgerufen – so kommt
  die Anzeige schnell und der healthz-gekoppelte Watchdog resettet nicht,
  während der Router nach einem Stromausfall noch hochfährt.
- `/healthz` liefert `ok` (200) bzw. `no-data` (503) für Monitoring.
- Optionaler **Hardware-Watchdog** startet die Kiste bei Absturz selbst neu
  (siehe Installation, Schritt 6).

## Test auf dem Entwicklungsrechner

```sh
python3 server.py
# dann http://localhost:8080/ im Browser öffnen
```

## Lizenz

[MIT](LICENSE)
