#!/usr/bin/env bash
# PVE Hub — installation en une commande, à lancer sur l'hôte Proxmox (root).
#   bash pvehub-install.sh             → crée le conteneur Alpine, le jeton API et démarre l'app
#   bash pvehub-install.sh update ID   → met à jour l'app dans le conteneur ID (garde la config)
#   bash pvehub-install.sh migrate ID  → remplace le conteneur ID (ancien, Debian) par un conteneur Alpine,
#                                        avec la même config et la même adresse réseau
#   bash pvehub-install.sh tailscale ID → accès depuis l'extérieur en HTTPS via Tailscale
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "Lance ce script en root sur l'hôte Proxmox."; exit 1; }
command -v pct >/dev/null || { echo "pct introuvable : ce script doit tourner sur l'hôte Proxmox."; exit 1; }

say() { printf '\n\033[1;33m▶ %s\033[0m\n' "$*"; }
# sans terminal (lancé depuis l'onglet Commandes) : on prend la valeur par défaut sans rien demander
ask() { local q=$1 d=${2:-} v=""; if (exec </dev/tty) 2>/dev/null; then read -r -p "$q${d:+ [$d]} : " v </dev/tty || true; fi; echo "${v:-$d}"; }
ctsh() { local id=$1; shift; pct exec "$id" -- sh -c "$*"; }  # Alpine n'a pas bash : sh partout dans le conteneur

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
  base64 -d > "$WORK/static/sw.js"                 <<'B64'
@@SW@@
B64
}

push_app() {  # $1 = CTID
  ctsh "$1" "mkdir -p /opt/pvehub/static /opt/pvehub/data"
  pct push "$1" "$WORK/server.py" /opt/pvehub/server.py
  # VERSION et CTID servent au bouton « Mettre à jour » de l'app
  echo "@@VERSION@@" > "$WORK/VERSION"; echo "$1" > "$WORK/CTID"
  pct push "$1" "$WORK/VERSION" /opt/pvehub/VERSION; pct push "$1" "$WORK/CTID" /opt/pvehub/CTID
  for f in index.html manifest.webmanifest icon.svg sw.js; do pct push "$1" "$WORK/static/$f" "/opt/pvehub/static/$f"; done
}

# Redémarrage différé de 3 s : lancé depuis l'onglet Commandes, la réponse arrive avant la coupure.
# Gère Alpine (OpenRC) et les anciens conteneurs Debian (systemd).
restart_app() {  # $1 = CTID
  ctsh "$1" "if command -v rc-service >/dev/null; then setsid sh -c 'sleep 3; rc-service pvehub restart' >/dev/null 2>&1 </dev/null &
    else U=/etc/systemd/system/pvehub.service  # ancien conteneur Debian : /opt est en lecture seule sauf data/
      grep -q '^ReadWritePaths' \$U || { sed -i '/^ProtectSystem/a ReadWritePaths=/opt/pvehub/data' \$U && systemctl daemon-reload; }
      systemd-run --quiet --on-active=3 systemctl restart pvehub; fi"
  echo "PVE Hub redémarre dans 3 secondes."
}

ct_ip() { ctsh "$1" "ip -4 addr show eth0" | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}'; }

# Droit réseau (SDN.Use) : nécessaire pour qu'un nouveau conteneur créé par le Store se branche sur vmbr0.
# Le rôle PVESDNUser n'existe pas avant Proxmox 8 : on ignore l'erreur.
grant_sdn() { pveum acl modify / --users pvehub@pve --roles PVESDNUser 2>/dev/null || true; }

AUTH=/root/.ssh/authorized_keys
setup_exec() {  # $1 = CTID — section Commandes : clé SSH du conteneur autorisée en root sur l'hôte
  local pub host
  if [ "$(ask "Activer la section Commandes ? (accès root à l'hôte par SSH) o/n" "o")" != o ]; then
    pub=$(ctsh "$1" "cat /opt/pvehub/ssh/id_ed25519.pub 2>/dev/null" || true)
    [ -n "$pub" ] && grep -vF "$pub" "$AUTH" > "$WORK/ak" && cat "$WORK/ak" > "$AUTH"
    ctsh "$1" "rm -rf /opt/pvehub/ssh"
    echo "Commandes désactivées."; return
  fi
  ctsh "$1" "command -v ssh >/dev/null || { if command -v apk >/dev/null; then apk add -q --no-cache openssh-client-default openssh-keygen;
      else apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-client >/dev/null; fi; }
    mkdir -p /opt/pvehub/ssh/.ssh && cd /opt/pvehub/ssh
    command -v usermod >/dev/null && usermod -d /opt/pvehub/ssh pvehub  # ssh veut un ~/.ssh existant, sinon il râle
    [ -f id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C pvehub -f id_ed25519"
  pub=$(ctsh "$1" "cat /opt/pvehub/ssh/id_ed25519.pub")
  # restrict : pas de redirection de ports ni d'agent, seulement des commandes
  grep -qF "$pub" "$AUTH" 2>/dev/null || echo "restrict $pub" >> "$AUTH"
  host=$(ctsh "$1" "sed -n 's|^PVE_URL=https\?://\([^:/]*\).*|\1|p' /opt/pvehub/.env")
  ssh-keyscan -t ed25519 "$host" 2>/dev/null > "$WORK/kh"
  [ -s "$WORK/kh" ] || { echo "❌ Impossible de lire la clé SSH de l'hôte $host."; return 1; }
  pct push "$1" "$WORK/kh" /opt/pvehub/ssh/known_hosts
  ctsh "$1" "chown -R pvehub /opt/pvehub/ssh && chmod 700 /opt/pvehub/ssh && chmod 600 /opt/pvehub/ssh/id_ed25519"
  echo "Commandes activées."
}

# Crée et prépare un conteneur Alpine avec Python, l'utilisateur pvehub, l'app et son service (non démarré).
# $1 = CTID, $2 = stockage, $3 = options réseau net0
provision() {
  local id=$1 store=$2 net=$3 arch tpl
  say "Modèle Alpine"
  pveam update >/dev/null
  arch=$(dpkg --print-architecture)
  tpl=$(pveam available --section system | awk '{print $2}' | grep -E "^alpine-3\.[0-9]+-default_.*_${arch}\.tar" | sort -V | tail -1)
  [ -n "$tpl" ] || { echo "❌ Aucun modèle Alpine pour l'architecture $arch."; return 1; }
  pveam list local | grep -q "$tpl" || pveam download local "$tpl"

  say "Création du conteneur $id (1 cœur, 64 Mo de RAM, 1 Go de disque)"
  pct create "$id" "local:vztmpl/$tpl" --hostname pvehub --cores 1 --memory 64 --swap 64 \
    --rootfs "$store:1" --net0 "$net" --unprivileged 1 --onboot 1 \
    --description "PVE Hub — interface Proxmox + Hermes"
  # pct create --start n'échoue pas si le démarrage rate : on démarre à part pour s'arrêter net
  pct start "$id" || { echo "❌ Le conteneur $id ne démarre pas. Détail : pct start $id --debug"; return 1; }

  say "Attente du réseau"
  for _ in $(seq 30); do ctsh "$id" "nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1" && break; sleep 2; done

  say "Installation de Python (seule dépendance)"
  ctsh "$id" "apk add -q --no-cache python3 py3-cryptography tzdata && adduser -S -D -H -h /opt/pvehub/ssh -s /sbin/nologin pvehub"
  push_app "$id"
  cat > "$WORK/initd" <<'EOF'
#!/sbin/openrc-run
name="PVE Hub"
command="/usr/bin/python3"
command_args="/opt/pvehub/server.py"
command_user="pvehub"
supervisor="supervise-daemon"
respawn_delay=3
output_log="/var/log/pvehub.log"
error_log="/var/log/pvehub.log"
depend() { need net; }
start_pre() { checkpath -f -o pvehub -m 0640 /var/log/pvehub.log; }
EOF
  pct push "$id" "$WORK/initd" /etc/init.d/pvehub --perms 755
  ctsh "$id" "rc-update add pvehub default >/dev/null"
}

start_and_check() {  # $1 = CTID — démarre le service et vérifie qu'il répond
  ctsh "$1" "chown -R pvehub /opt/pvehub && rc-service pvehub start >/dev/null"
  for _ in $(seq 10); do
    ctsh "$1" "wget -q -O /dev/null http://127.0.0.1:8080/ 2>/dev/null" && return 0; sleep 1
  done
  echo "❌ L'app ne répond pas. Journal :"; ctsh "$1" "tail -n 20 /var/log/pvehub.log" || true; return 1
}

unpack

case "${1:-}" in
tailscale)
  CTID=${2:?usage : bash pvehub-install.sh tailscale <CTID>}
  # le conteneur redémarre et la connexion demande d'ouvrir un lien : impossible depuis l'onglet Commandes
  (exec </dev/tty) 2>/dev/null || { echo "❌ Lance cette commande depuis le Shell de Proxmox, pas depuis l'onglet Commandes."; exit 1; }
  pct config "$CTID" >/dev/null || { echo "❌ Conteneur $CTID introuvable."; exit 1; }
  ctsh "$CTID" "command -v apk >/dev/null" || { echo "❌ Ce conteneur n'est pas sous Alpine : fais d'abord « migrate $CTID »."; exit 1; }

  if ! pct config "$CTID" | grep -q '/dev/net/tun'; then
    say "Accès au réseau virtuel (/dev/net/tun) pour le CT $CTID"
    for i in $(seq 0 9); do pct config "$CTID" | grep -q "^dev$i:" || { pct set "$CTID" "--dev$i" /dev/net/tun; break; }; done
    echo "Redémarrage du conteneur pour appliquer le réglage…"
    pct reboot "$CTID"
    for _ in $(seq 30); do ctsh "$CTID" "nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1" 2>/dev/null && break; sleep 2; done
  fi

  say "Installation de Tailscale"
  ctsh "$CTID" "apk add -q --no-cache tailscale && rc-update add tailscale default >/dev/null && rc-service tailscale start >/dev/null"

  say "Connexion à ton compte Tailscale"
  KEY=$(ask "Clé d'authentification Tailscale (vide = un lien à ouvrir)" "")
  if [ -n "$KEY" ]; then
    [[ "$KEY" =~ ^tskey-[A-Za-z0-9_-]+$ ]] || { echo "❌ Clé invalide (elle commence par tskey-)."; exit 1; }
    ctsh "$CTID" "tailscale up --hostname=pvehub --auth-key=$KEY"
  else
    echo "Ouvre le lien qui va s'afficher (sur ton téléphone ou ton ordinateur) et connecte-toi."
    ctsh "$CTID" "tailscale up --hostname=pvehub"
  fi

  say "Adresse HTTPS"
  echo "Si un lien s'affiche, ouvre-le pour autoriser HTTPS sur ton réseau Tailscale (une seule fois)."
  ctsh "$CTID" "tailscale serve --bg 8080"
  NAME=$(ctsh "$CTID" "tailscale status --json" | python3 -c "import json,sys; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))")
  say "C'est prêt"
  echo "  Adresse à distance : https://$NAME"
  echo
  echo "  Sur ton téléphone : installe l'app Tailscale, connecte-toi avec le même compte,"
  echo "  puis ouvre l'adresse et « Ajouter à l'écran d'accueil »."
  exit 0 ;;

update)
  CTID=${2:?usage : bash pvehub-install.sh update <CTID>}
  say "Mise à jour de PVE Hub dans le CT $CTID"
  push_app "$CTID"
  # notifications (chiffrement) et fuseaux horaires (rapport du matin) ; déjà là = rien à faire
  ctsh "$CTID" "if command -v apk >/dev/null; then apk add -q --no-cache py3-cryptography tzdata;
    else DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-cryptography tzdata >/dev/null; fi" || echo "⚠️  Modules optionnels non installés (le reste fonctionne)."
  setup_exec "$CTID" || true
  grant_sdn
  ctsh "$CTID" "chown -R pvehub /opt/pvehub"
  restart_app "$CTID"
  echo "✅ Mis à jour."; exit 0 ;;

migrate)
  OLD=${2:?usage : bash pvehub-install.sh migrate <CTID actuel>}
  # le conteneur actuel va s'arrêter : lancé depuis l'onglet Commandes, la migration mourrait en route
  (exec </dev/tty) 2>/dev/null || { echo "❌ Lance la migration depuis le Shell de Proxmox, pas depuis l'onglet Commandes."; exit 1; }
  pct config "$OLD" >/dev/null || { echo "❌ Conteneur $OLD introuvable."; exit 1; }
  say "Récupération de la configuration du CT $OLD"
  pct pull "$OLD" /opt/pvehub/.env "$WORK/env"
  mkdir -p "$WORK/ssh"
  for f in id_ed25519 id_ed25519.pub known_hosts; do pct pull "$OLD" "/opt/pvehub/ssh/$f" "$WORK/ssh/$f" 2>/dev/null || true; done
  mkdir -p "$WORK/data"
  for f in apps.json push.json vapid.pem alerts.json reports.json; do pct pull "$OLD" "/opt/pvehub/data/$f" "$WORK/data/$f" 2>/dev/null || true; done
  NET=$(pct config "$OLD" | sed -n 's/^net0: //p')  # même pont et même adresse MAC → même IP en DHCP
  STORE=$(pct config "$OLD" | sed -n 's/^rootfs: \([^:]*\):.*/\1/p')
  NEW=$(pvesh get /cluster/nextid)
  echo "Nouveau conteneur : $NEW (stockage $STORE, réseau : $NET)"
  [ "$(ask "Continuer ? Le CT $OLD sera arrêté pendant la migration. o/n" "o")" = o ] || exit 0

  pct stop "$OLD"
  if ! provision "$NEW" "$STORE" "$NET" || ! {
       pct push "$NEW" "$WORK/env" /opt/pvehub/.env --perms 600
       for f in apps.json push.json vapid.pem alerts.json reports.json; do [ -s "$WORK/data/$f" ] && pct push "$NEW" "$WORK/data/$f" "/opt/pvehub/data/$f"; done
       if [ -s "$WORK/ssh/id_ed25519" ]; then
         ctsh "$NEW" "mkdir -p /opt/pvehub/ssh/.ssh"
         for f in id_ed25519 id_ed25519.pub known_hosts; do [ -s "$WORK/ssh/$f" ] && pct push "$NEW" "$WORK/ssh/$f" "/opt/pvehub/ssh/$f"; done
         ctsh "$NEW" "apk add -q --no-cache openssh-client-default && chmod 700 /opt/pvehub/ssh && chmod 600 /opt/pvehub/ssh/id_ed25519"
       fi
       start_and_check "$NEW"
     }; then
    echo "❌ Migration échouée : retour à l'ancien conteneur."
    pct stop "$NEW" 2>/dev/null || true
    pct set "$NEW" --onboot 0 2>/dev/null || true
    pct start "$OLD"
    echo "Le CT $OLD tourne de nouveau. Le CT $NEW (raté) est arrêté ; supprime-le avec : pct destroy $NEW"
    exit 1
  fi
  pct set "$OLD" --onboot 0
  say "Migration réussie"
  echo "  Nouveau conteneur : $NEW — http://$(ct_ip "$NEW"):8080"
  if [ "$(ask "Supprimer définitivement l'ancien CT $OLD ? o/n" "n")" = o ]; then
    pct destroy "$OLD" && echo "CT $OLD supprimé."
  else
    echo "  Le CT $OLD est arrêté et ne redémarrera plus tout seul. Supprime-le plus tard avec : pct destroy $OLD"
  fi
  exit 0 ;;
esac

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
grant_sdn
pveum user token remove pvehub@pve app 2>/dev/null || true
TOKEN_SECRET=$(pveum user token add pvehub@pve app --privsep 0 --output-format json | grep -o '"value" *: *"[^"]*"' | cut -d'"' -f4)
[ -n "$TOKEN_SECRET" ] || { echo "Impossible de créer le jeton API."; exit 1; }

provision "$CTID" "$STORE" "name=eth0,bridge=$BRIDGE,ip=dhcp"
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
start_and_check "$CTID"

say "C'est prêt"
echo "  Adresse       : http://$(ct_ip "$CTID"):8080"
echo "  Mot de passe  : $APP_PASSWORD"
echo "  Configuration : pct enter $CTID puis vi /opt/pvehub/.env, puis rc-service pvehub restart"
echo
echo "  Sur ton téléphone : ouvre l'adresse puis « Ajouter à l'écran d'accueil »."
[ -n "$HERMES_URL" ] && echo "  Hermes doit écouter sur le réseau : API_SERVER_HOST=0.0.0.0 dans ~/.hermes/.env, puis redémarre « hermes gateway »."
exit 0
