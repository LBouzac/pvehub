#!/usr/bin/env bash
# PVE Hub — installation en une commande, à lancer sur l'hôte Proxmox (root).
#   bash pvehub-install.sh            → crée le conteneur, le jeton API et démarre l'app
#   bash pvehub-install.sh update ID  → met à jour l'app dans le conteneur ID (garde la config)
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "Lance ce script en root sur l'hôte Proxmox."; exit 1; }
command -v pct >/dev/null || { echo "pct introuvable : ce script doit tourner sur l'hôte Proxmox."; exit 1; }

say() { printf '\n\033[1;33m▶ %s\033[0m\n' "$*"; }
ask() { local q=$1 d=${2:-} v; read -r -p "$q${d:+ [$d]} : " v </dev/tty; echo "${v:-$d}"; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
unpack() {
  mkdir -p "$WORK/static"
  base64 -d > "$WORK/server.py"                    <<'B64'
@@SERVER@@
B64
  base64 -d > "$WORK/static/index.html"            <<'B64'
@@INDEX@@
B64
  base64 -d > "$WORK/static/manifest.webmanifest"  <<'B64'
@@MANIFEST@@
B64
  base64 -d > "$WORK/static/icon.svg"              <<'B64'
@@ICON@@
B64
}

push_app() {  # $1 = CTID
  pct exec "$1" -- mkdir -p /opt/pvehub/static
  pct push "$1" "$WORK/server.py" /opt/pvehub/server.py
  for f in index.html manifest.webmanifest icon.svg; do pct push "$1" "$WORK/static/$f" "/opt/pvehub/static/$f"; done
}

AUTH=/root/.ssh/authorized_keys
setup_exec() {  # $1 = CTID — section Commandes : clé SSH du conteneur autorisée en root sur l'hôte
  local pub host
  if [ "$(ask "Activer la section Commandes ? (accès root à l'hôte par SSH) o/n" "o")" != o ]; then
    pub=$(pct exec "$1" -- cat /opt/pvehub/ssh/id_ed25519.pub 2>/dev/null || true)
    [ -n "$pub" ] && grep -vF "$pub" "$AUTH" > "$WORK/ak" && cat "$WORK/ak" > "$AUTH"
    pct exec "$1" -- rm -rf /opt/pvehub/ssh
    echo "Commandes désactivées."; return
  fi
  pct exec "$1" -- bash -c "command -v ssh >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-client >/dev/null; }
    mkdir -p /opt/pvehub/ssh/.ssh && cd /opt/pvehub/ssh
    usermod -d /opt/pvehub/ssh pvehub  # ssh veut un ~/.ssh existant, sinon il râle à chaque commande
    [ -f id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C pvehub -f id_ed25519"
  pub=$(pct exec "$1" -- cat /opt/pvehub/ssh/id_ed25519.pub)
  # restrict : pas de redirection de ports ni d'agent, seulement des commandes
  grep -qF "$pub" "$AUTH" 2>/dev/null || echo "restrict $pub" >> "$AUTH"
  host=$(pct exec "$1" -- sed -n 's|^PVE_URL=https\?://\([^:/]*\).*|\1|p' /opt/pvehub/.env)
  ssh-keyscan -t ed25519 "$host" 2>/dev/null > "$WORK/kh"
  [ -s "$WORK/kh" ] || { echo "❌ Impossible de lire la clé SSH de l'hôte $host."; return 1; }
  pct push "$1" "$WORK/kh" /opt/pvehub/ssh/known_hosts
  pct exec "$1" -- bash -c "chown -R pvehub /opt/pvehub/ssh && chmod 700 /opt/pvehub/ssh && chmod 600 /opt/pvehub/ssh/id_ed25519"
  echo "Commandes activées."
}

unpack

if [ "${1:-}" = update ]; then
  CTID=${2:?usage : bash pvehub-install.sh update <CTID>}
  say "Mise à jour de PVE Hub dans le CT $CTID"
  push_app "$CTID"
  setup_exec "$CTID" || true
  pct exec "$CTID" -- chown -R pvehub /opt/pvehub
  pct exec "$CTID" -- systemctl restart pvehub
  echo "✅ Mis à jour."; exit 0
fi

say "Réglages (Entrée = valeur par défaut)"
CTID=$(ask "ID du conteneur" "$(pvesh get /cluster/nextid)")
DEF_STORE=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active"{print $1; exit}')
STORE=$(ask "Stockage du disque" "${DEF_STORE:-local-lvm}")
BRIDGE=$(ask "Pont réseau" "vmbr0")
HERMES_URL=$(ask "URL de Hermes (ex. http://192.168.1.20:8642, vide = sans Hermes)" "")
HERMES_KEY=""; [ -n "$HERMES_URL" ] && HERMES_KEY=$(ask "Clé API de Hermes (API_SERVER_KEY)" "")
APP_PASSWORD=$(ask "Mot de passe de l'app" "$(tr -dc 'a-km-zA-HJ-NP-Z2-9' </dev/urandom | head -c 14)")

say "Utilisateur et jeton API Proxmox (pvehub@pve)"
pveum user add pvehub@pve --comment "PVE Hub" 2>/dev/null || true
pveum acl modify / --users pvehub@pve --roles PVEVMAdmin,PVEDatastoreUser,PVEAuditor
pveum user token remove pvehub@pve app 2>/dev/null || true
TOKEN_SECRET=$(pveum user token add pvehub@pve app --privsep 0 --output-format json | grep -o '"value" *: *"[^"]*"' | cut -d'"' -f4)
[ -n "$TOKEN_SECRET" ] || { echo "Impossible de créer le jeton API."; exit 1; }

say "Modèle Debian"
pveam update >/dev/null
TPL=$(pveam available --section system | awk '{print $2}' | grep -E "^debian-1[2-9]-standard_.*_$(dpkg --print-architecture)\.tar" | sort -V | tail -1)
[ -n "$TPL" ] || { echo "❌ Aucun modèle Debian pour l'architecture $(dpkg --print-architecture)."; exit 1; }
pveam list local | grep -q "$TPL" || pveam download local "$TPL"

say "Création du conteneur $CTID (1 cœur, 128 Mo de RAM, 2 Go de disque)"
pct create "$CTID" "local:vztmpl/$TPL" --hostname pvehub --cores 1 --memory 128 --swap 128 \
  --rootfs "$STORE:2" --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp" --unprivileged 1 --features nesting=1 \
  --onboot 1 --description "PVE Hub — interface Proxmox + Hermes"
# pct create --start n'échoue pas si le démarrage rate : on démarre à part pour s'arrêter net
pct start "$CTID" || { echo "❌ Le conteneur $CTID ne démarre pas. Détail : pct start $CTID --debug"; exit 1; }

say "Attente du réseau"
for _ in $(seq 30); do pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break; sleep 2; done

say "Installation de Python (seule dépendance)"
pct exec "$CTID" -- bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 >/dev/null && useradd -r -s /usr/sbin/nologin pvehub"

push_app "$CTID"
HOST_IP=$(hostname -I | awk '{print $1}')
cat > "$WORK/env" <<EOF
PVE_URL=https://$HOST_IP:8006
PVE_TOKEN=pvehub@pve!app=$TOKEN_SECRET
PVE_VERIFY_SSL=false
HERMES_URL=$HERMES_URL
HERMES_KEY=$HERMES_KEY
APP_PASSWORD=$APP_PASSWORD
APP_SECRET=$(tr -dc 'a-f0-9' </dev/urandom | head -c 64)
PORT=8080
EOF
pct push "$CTID" "$WORK/env" /opt/pvehub/.env --perms 600
setup_exec "$CTID" || true
cat > "$WORK/unit" <<'EOF'
[Unit]
Description=PVE Hub
After=network-online.target
Wants=network-online.target

[Service]
User=pvehub
ExecStart=/usr/bin/python3 /opt/pvehub/server.py
Restart=always
RestartSec=3
MemoryMax=80M
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
pct push "$CTID" "$WORK/unit" /etc/systemd/system/pvehub.service
pct exec "$CTID" -- bash -c "chown -R pvehub /opt/pvehub && systemctl daemon-reload && systemctl enable --now pvehub"

sleep 2
CT_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
say "C'est prêt"
echo "  Adresse       : http://$CT_IP:8080"
echo "  Mot de passe  : $APP_PASSWORD"
echo "  Configuration : pct enter $CTID puis nano /opt/pvehub/.env (systemctl restart pvehub)"
echo
echo "  Sur ton téléphone : ouvre l'adresse puis « Ajouter à l'écran d'accueil »."
[ -n "$HERMES_URL" ] && echo "  Hermes doit écouter sur le réseau : API_SERVER_HOST=0.0.0.0 dans ~/.hermes/.env, puis redémarre « hermes gateway »."
