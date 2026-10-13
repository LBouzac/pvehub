# PVE Hub

Petite app web pour piloter ton Proxmox depuis le téléphone, avec Hermes intégré.

- Tableau de bord : CPU, RAM, disque, stockage, graphique de la dernière heure
- Machines (VM et CT) : démarrer, éteindre, redémarrer, forcer l'arrêt
- Snapshots : créer, restaurer, supprimer
- Sauvegardes : lancer maintenant, restaurer
- Apps : tes services web (Home Assistant, Jellyfin…) en grille d'icônes, détectés automatiquement, avec un point vert s'ils répondent ;
  renommer, changer l'adresse, masquer, ou ajouter tes propres liens (bouton Modifier)
- Commandes : lancer une commande sur l'hôte, dans un conteneur ou une VM (agent QEMU requis) et voir le résultat
- Tâches planifiées : la crontab de root de l'hôte et de chaque conteneur, en clair (« Tous les jours à 03:00 ») ;
  ajouter, modifier, activer/désactiver, supprimer, lancer tout de suite
- Hermes : il reçoit l'état du serveur à chaque message et peut proposer des actions, que tu valides d'un tap
- Autorisations : Hermes te demande la permission avant ses commandes sensibles (Autoriser / Pour la session / Toujours / Refuser),
  et tu peux l'autoriser d'avance à démarrer, éteindre, redémarrer, snapshoter ou sauvegarder (bouton bouclier dans l'onglet Hermes)

Ultra léger : un conteneur Alpine Linux (64 Mo de RAM, 1 Go de disque, environ 30 Mo réellement utilisés en RAM),
Python seul, aucune dépendance, aucun build.
L'app ne rafraîchit les données que lorsqu'elle est ouverte à l'écran.

## Installation (sur l'hôte Proxmox, en root)

Dans le Shell du nœud (interface web → ton nœud → Shell) :

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/LBouzac/pvehub/main/pvehub-install.sh)
```

Le script pose 5 questions (Entrée = valeur par défaut), puis :
1. crée l'utilisateur `pvehub@pve` et un jeton API (rôles PVEVMAdmin, PVEDatastoreUser, PVEAuditor) ;
2. crée un conteneur Alpine non privilégié (1 cœur, 64 Mo, 1 Go) ;
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
ou plus tard dans `/opt/pvehub/.env` du conteneur, suivi de `rc-service pvehub restart`.

Hermes ne touche jamais Proxmox directement depuis l'app : il propose un bloc d'action, l'app te demande
confirmation, puis l'exécute avec son propre jeton.

## Mettre à jour

Depuis l'app : quand une nouvelle version existe, un bandeau apparaît sur l'onglet Serveur (et un point rouge sur la
roue dentée). Un tap l'installe. Il faut que la section Commandes soit activée.

Ou depuis le Shell de Proxmox :

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/LBouzac/pvehub/main/pvehub-install.sh) update <ID-du-conteneur>
```

La mise à jour demande si tu veux la section Commandes : « o » crée une clé SSH dans le conteneur et l'autorise
en root sur l'hôte ; « n » la retire. Lancée depuis l'onglet Commandes, elle garde le réglage actuel sans rien demander.

## Passer d'un ancien conteneur Debian à Alpine

Les installations d'avant octobre 2026 utilisaient Debian. Pour passer à Alpine (moins de RAM et de disque),
depuis le Shell de Proxmox (pas depuis l'onglet Commandes) :

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/LBouzac/pvehub/main/pvehub-install.sh) migrate <ID-du-conteneur>
```

Le script crée un nouveau conteneur Alpine avec la même configuration (mot de passe, clé Hermes, clé SSH)
et la même adresse MAC, donc la même adresse IP. En cas d'échec, l'ancien conteneur redémarre tout seul.
À la fin, il propose de supprimer l'ancien.

## Dépannage

- Journal de l'app : `pct exec <ID> -- tail -n 50 /var/log/pvehub.log`
- Redémarrer l'app : `pct exec <ID> -- rc-service pvehub restart`

## Sécurité

- Section Commandes : la clé SSH du conteneur donne un accès root à l'hôte. Quiconque a le mot de passe de l'app peut donc
  tout faire sur le serveur. Choisis un mot de passe solide, ou réponds « n » pour désactiver.

- Accès protégé par mot de passe (cookie de session 30 jours).
- Fait pour le réseau local. Pour y accéder de l'extérieur, passe par un VPN (Tailscale, WireGuard) plutôt que d'ouvrir un port.
- L'API de Hermes donne accès à son terminal : garde sa clé secrète et ne l'expose pas sur Internet.

## Développement

Sources dans `app/`. `python3 build.py` régénère `pvehub-install.sh`. Tests : `python3 app/test_server.py`.
Lancer en local : `PVE_URL=https://IP:8006 PVE_TOKEN='user@pve!id=secret' APP_PASSWORD=x python3 app/server.py`.

## Licence

MIT — voir [LICENSE](LICENSE).

Icône « réglages » adaptée de [Feather Icons](https://feathericons.com) (MIT, © Cole Bemis).

PVE Hub est un projet indépendant, sans lien avec Proxmox Server Solutions GmbH ni avec Nous Research.
Proxmox est une marque déposée de Proxmox Server Solutions GmbH.
