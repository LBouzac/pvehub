# PVE Hub

Petite app web pour piloter ton Proxmox depuis le téléphone, avec Hermes intégré.

- Tableau de bord : CPU, RAM, disque, stockage, graphique de la dernière heure
- Machines (VM et CT) : démarrer, éteindre, redémarrer, forcer l'arrêt
- Snapshots : créer, restaurer, supprimer
- Sauvegardes : lancer maintenant, restaurer
- Hermes : il reçoit l'état du serveur à chaque message et peut proposer des actions, que tu valides d'un tap

Ultra léger : un conteneur Debian de 128 Mo, Python seul, aucune dépendance, aucun build.
L'app ne rafraîchit les données que lorsqu'elle est ouverte à l'écran.

## Installation (sur l'hôte Proxmox, en root)

Dans le Shell du nœud (interface web → ton nœud → Shell) :

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/LBouzac/pvehub/main/pvehub-install.sh)
```

Le script pose 5 questions (Entrée = valeur par défaut), puis :
1. crée l'utilisateur `pvehub@pve` et un jeton API (rôles PVEVMAdmin, PVEDatastoreUser, PVEAuditor) ;
2. crée un conteneur Debian non privilégié (1 cœur, 128 Mo, 2 Go) ;
3. installe l'app comme service et affiche l'adresse et le mot de passe.

Sur le téléphone : ouvre l'adresse, puis « Ajouter à l'écran d'accueil ».

## Brancher Hermes

Sur la machine où tourne Hermes, dans `~/.hermes/.env` :

```bash
API_SERVER_ENABLED=true
API_SERVER_HOST=0.0.0.0
API_SERVER_KEY=une-cle-longue-et-secrete
```

Puis redémarre `hermes gateway`. Donne l'URL (`http://IP-de-hermes:8642`) et la clé au script d'installation,
ou plus tard dans `/opt/pvehub/.env` du conteneur, suivi de `systemctl restart pvehub`.

Hermes ne touche jamais Proxmox directement depuis l'app : il propose un bloc d'action, l'app te demande
confirmation, puis l'exécute avec son propre jeton.

## Mettre à jour

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/LBouzac/pvehub/main/pvehub-install.sh) update <ID-du-conteneur>
```

## Sécurité

- Accès protégé par mot de passe (cookie de session 30 jours).
- Fait pour le réseau local. Pour y accéder de l'extérieur, passe par un VPN (Tailscale, WireGuard) plutôt que d'ouvrir un port.
- L'API de Hermes donne accès à son terminal : garde sa clé secrète et ne l'expose pas sur Internet.

## Développement

Sources dans `app/`. `python3 build.py` régénère `pvehub-install.sh`.
Lancer en local : `PVE_URL=https://IP:8006 PVE_TOKEN='user@pve!id=secret' APP_PASSWORD=x python3 app/server.py`.
