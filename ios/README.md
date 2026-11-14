# PVE Hub pour iOS

App native SwiftUI, construite sous Linux avec [xtool](https://github.com/xtool-org/xtool). Elle utilise l'API de ton
serveur PVE Hub telle quelle : rien à changer côté serveur. Mêmes écrans que la version web : Serveur, Machines
(fiche, ressources, snapshots, sauvegardes), Horaires, Apps et Store, Commandes et crontab, Maintenance, Journal,
Hermes (réponses en direct, actions, autorisations) et Réglages.

## Prérequis (une seule fois)

1. Swift 6.4 : `paru -S swift-bin`
2. Xcode 27.1 (`Xcode_27.1.xip`) depuis https://developer.apple.com/download/all/?q=Xcode, avec ton Apple ID
3. `xtool setup` : connexion Apple ID, puis chemin du `.xip` (xtool en tire le SDK iOS)
4. iPhone branché en USB, **Mode développeur** activé (Réglages → Confidentialité et sécurité)

## Compiler et installer

```bash
cd ios
xtool dev build   # compile seulement
xtool dev         # compile, signe et installe sur l'iPhone branché
```

Au premier lancement : adresse du serveur (`http://IP:8080` ou ton adresse Tailscale en `https://`) et mot de passe.
La session est gardée dans le trousseau de l'iPhone.

## TestFlight (compte Apple Developer payant)

Pas besoin de câble ni de réinstaller chaque semaine : l'app s'installe et se met à jour depuis l'app TestFlight.
xtool ne produit pas une build acceptée par l'App Store ; le workflow `.github/workflows/ios.yml` la compile avec Xcode
sur un Mac de GitHub (projet généré par XcodeGen depuis `project.yml`, même code que pour xtool). Une fois pour toutes :

1. Sur [developer.apple.com](https://developer.apple.com/account/resources/identifiers/list) → *Identifiers* → *+* →
   *App IDs* : enregistrer `com.lbouzac.pvehub` avec la capacité *Push Notifications*.
2. Sur [App Store Connect](https://appstoreconnect.apple.com) : *Apps* → *+* → nouvelle app iOS, identifiant
   `com.lbouzac.pvehub`. Le nom doit être unique sur l'App Store : si « PVE Hub » est pris, mets-en un autre
   (le nom sous l'icône reste « PVE Hub »).
3. Dans les secrets du dépôt GitHub (*Settings* → *Secrets and variables* → *Actions*), les mêmes que pour Patate :
   `APPLE_TEAM_ID` (`776JL5KQTK`), `ASC_KEY_ID`, `ASC_ISSUER_ID` et `ASC_KEY` (tout le contenu du `.p8`, rôle Admin).

Ensuite, *Actions* → *iOS TestFlight* → *Run workflow*. La build arrive dans TestFlight en une quinzaine de minutes,
numérotée automatiquement. Dans App Store Connect → *TestFlight* → *Tests internes*, ajoute-toi au groupe, puis
installe depuis l'app TestFlight de l'iPhone. Chaque build reste installable 90 jours : relance le workflow pour une
nouvelle version.

## Notifications sur l'iPhone (APNs)

Le serveur envoie les alertes à Apple avec une clé du compte développeur. Une fois pour toutes :

1. Sur [developer.apple.com](https://developer.apple.com/account/resources/authkeys/list) → *Keys* → *+* : cocher
   *Apple Push Notifications service (APNs)*, environnement *Production*, puis télécharger `AuthKey_XXXXXXXXXX.p8`.
2. Depuis le PC, envoyer la clé sur le Proxmox (mot de passe root demandé) :

   ```bash
   scp ~/.config/asc/AuthKey_XXXXXXXXXX.p8 root@IP_DU_PROXMOX:/tmp/apns.p8
   ```

3. Dans le Shell du Proxmox (`pct list` donne le numéro du conteneur PVE Hub) : la clé va dans le conteneur, les
   identifiants dans `.env`, et `curl` est installé (APNs n'accepte que HTTP/2) :

   ```bash
   CT=100
   pct push $CT /tmp/apns.p8 /opt/pvehub/data/apns.p8 && rm /tmp/apns.p8
   pct exec $CT -- sh -c 'chown pvehub /opt/pvehub/data/apns.p8 && chmod 600 /opt/pvehub/data/apns.p8 &&
     printf "APNS_KEY_ID=XXXXXXXXXX\nAPNS_TEAM_ID=776JL5KQTK\n" >> /opt/pvehub/.env &&
     apk add -q --no-cache curl && rc-service pvehub restart'
   ```

4. Mettre PVE Hub à jour (*Réglages* → *Mise à jour*) si ce n'est pas déjà fait : le serveur doit savoir parler à APNs.

L'app demande l'autorisation à la connexion ; *Réglages* → *Notifications* indique si l'iPhone est abonné.

## Vérifier la logique sous Linux

```bash
cd ios && swiftc Sources/PVEHub/Logic.swift Checks/main.swift -o /tmp/pvehub-check && /tmp/pvehub-check
```

## Limites

- **Notifications** : seulement avec la build TestFlight (pas avec `xtool dev`), et si le serveur a la clé APNs (voir
  ci-dessous). Sinon, les alertes arrivent sur la version web installée depuis Safari.
- **Installée avec `xtool dev`** : le profil peut expirer au bout de 7 jours ; relance `xtool dev`, ou passe par
  TestFlight.
- Pas de « Quoi de neuf » ni des fonds teinté et contrasté, propres à la version web.
