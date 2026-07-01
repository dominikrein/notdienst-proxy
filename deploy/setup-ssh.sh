#!/bin/sh
# setup-ssh.sh  --  SSH-Fernzugang (root, Passwort) fuer die Notdienst-Anzeige.
#
# Zwei Betriebsarten:
#
#   A) NON-INTERAKTIV (fuer die Image-/Serien-Bake, empfohlen):
#        INIT_ROOT_PW='DeinInitialPasswort' sh deploy/setup-ssh.sh
#      Setzt das Passwort ohne Rueckfrage. So kann das Setup Teil des goldenen
#      Overlays werden: Image auf CF schreiben -> booten -> sshd laeuft ->
#      Anmeldung mit dem Initial-Passwort. Danach am Geraet aendern:  passwd
#      (optional Wechsel bei Erstanmeldung erzwingen: FORCE_PW_CHANGE=1).
#
#   B) INTERAKTIV (direkt auf einem laufenden Geraet):
#        sh deploy/setup-ssh.sh
#      Fragt das root-Passwort per 'passwd' ab.
#
# Macht in beiden Faellen:
#   1) openssh installieren, sshd-Dienst aktivieren
#   2) Root-Login per Passwort erlauben (PermitRootLogin yes)
#   3) root-Passwort setzen -> Hash in /etc/shadow
#   4) Bei Diskless: 'lbu commit' -> sshd-Config + Passwort-Hash + Host-Keys
#      ins Overlay auf der CF persistieren
#
# SICHERHEIT: Root-Login mit Passwort ueber SSH wird im Netz brute-force-
# gescannt. Nur in einem vertrauenswuerdigen internen LAN betreiben, NICHT ins
# Internet forwarden. Das Initial-Passwort ist bewusst ein Startwert -> nach der
# ersten Anmeldung aendern. Sicherer waere Key-Auth (siehe README).
set -e

echo "== 1) Paket + Dienst =="
apk add --no-cache openssh >/dev/null
rc-update add sshd default

echo "== 2) Root-Login per Passwort erlauben =="
# idempotent: vorhandene (auch auskommentierte) Zeile umbiegen, sonst anhaengen
if grep -qE '^#*[[:space:]]*PermitRootLogin' /etc/ssh/sshd_config; then
    sed -i 's/^#*[[:space:]]*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
else
    echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
fi
if grep -qE '^#*[[:space:]]*PasswordAuthentication' /etc/ssh/sshd_config; then
    sed -i 's/^#*[[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
else
    echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
fi

echo "== 3) root-Passwort setzen =="
if [ -n "$INIT_ROOT_PW" ]; then
    # non-interaktiv; SHA512 bevorzugen, sonst busybox-Default
    if ! echo "root:$INIT_ROOT_PW" | chpasswd -c SHA512 2>/dev/null; then
        echo "root:$INIT_ROOT_PW" | chpasswd
    fi
    echo "  Initial-Passwort gesetzt (aus \$INIT_ROOT_PW)."
    if [ "$FORCE_PW_CHANGE" = "1" ]; then
        # Wechsel bei Erstanmeldung erzwingen (best effort, je nach Tooling)
        if passwd -e root 2>/dev/null || chage -d 0 root 2>/dev/null; then
            echo "  Passwortwechsel bei Erstanmeldung erzwungen."
        else
            echo "  ! Konnte Passwortwechsel nicht erzwingen (Tooling fehlt) - ignoriert."
        fi
    fi
else
    echo "  Bitte ein starkes Passwort vergeben (wird als Hash gespeichert):"
    passwd root
fi

echo "== 4) Dienst starten =="
# Host-Keys sicherstellen (fuer die Bake auf einem laufenden Geraet unkritisch;
# im Overlay landen sie via lbu commit, sind also nach dem Klonen stabil).
ssh-keygen -A >/dev/null 2>&1 || true
rc-service sshd restart || rc-service sshd start || true

echo "== 5) Persistenz =="
if command -v lbu >/dev/null 2>&1 && [ -f /etc/lbu/lbu.conf ]; then
    echo "  Diskless erkannt -> lbu commit (sshd-Config + /etc/shadow + Host-Keys auf CF)"
    lbu commit -d
else
    echo "  Sys-Installation -> Aenderungen liegen bereits auf Platte."
fi

echo
echo "FERTIG. Nach dem Booten Anmeldung von einem anderen Rechner im LAN:"
echo "  ssh root@<IP-des-Geraets>"
