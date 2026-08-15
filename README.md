# Cabasse Remote

Petite app **barre de menu macOS** pour piloter un amplificateur **Cabasse Abyss / AMP 240 S**
(plateforme StreamUnlimited, la même électronique que l'app officielle *StreamCONTROL*, mais
native, légère et instantanée).

100 % frameworks Apple (SwiftUI, Network, URLSession) — **aucune dépendance externe**.

## Ce que ça fait

- **Découverte automatique** de l'ampli sur le réseau (Bonjour `_cabasse-api._tcp`).
- **Now playing** temps réel : titre, fournisseur, pochette, état lecture.
- **Transport** : lecture/pause, précédent, suivant.
- **Volume + mute** avec slider (échelle 0–100), reflète aussi les changements faits
  depuis la télécommande physique.
- **Sélection de source** (DLNA, Bluetooth, Analog 1/2, Optical, TV, AirPlay, Roon…). Les sources
  Tidal, Qobuz et Alexa sont volontairement masquées.
- **Favoris radios illimités** (pas les 9 slots de l'ampli) avec **filtre grep instantané**
  (multi-termes, insensible casse/accents). Ajout depuis « la radio en cours » (★) ou depuis
  le catalogue. Stockés dans `~/Library/Application Support/CabasseRemote/favorites.json`.
- **Recherche grep dans tout le catalogue vTuner** : la fenêtre Catalogue indexe localement
  les stations (par défaut « <pays> · toutes les stations », ~2400 pour la France) et cherche
  dedans instantanément (multi-termes, casse/accents ignorés). L'index se construit en tâche de
  fond dès la connexion, les résultats apparaissent au fil de l'indexation, puis il est mis en
  cache (lancements suivants instantanés). On peut étendre la couverture avec « Indexer ce
  dossier » sur n'importe quelle liste (autre pays, genre…). Navigation hiérarchique also dispo.
- **Son** : profil **DEAP affiché en lecture seule** (modèle d'enceinte + position) et
  **EQ tonalité grave/aigu** réglable (−9…+9).
- **Statistiques du flux** (fenêtre dédiée, bouton ⌇ à côté de la lecture) :
  - Qualité : codec, débit, échantillonnage, résolution, canaux, format.
  - Santé en direct (`/System/AudioHub/Stats.json`, ~1×/s) : secondes bufferisées, débit réseau
    réel et taux d'alimentation, avec sparklines et un voyant stable/sous-tension.
  - Temps d'écoute écoulé sur la station.
  - Un badge qualité compact (« AAC · 237 kbps · 48 kHz ») est aussi affiché sous la lecture.

  Note : l'ampli n'expose **pas** le titre du morceau ICY en cours pour les webradios (le champ
  reste le nom de la station). Récupérer le morceau nécessiterait de lire les métadonnées ICY
  directement depuis le flux — non implémenté.

## Premier lancement — autorisation « réseau local »

Le pilotage média (parcourir/jouer les radios) passe par **UPnP**, qui nécessite une
découverte **SSDP multicast**. macOS demande donc l'accès **« réseau local »** au premier
lancement — **il faut l'accepter** (comme pour n'importe quelle app DLNA), sinon le catalogue
et la lecture des favoris restent indisponibles (le reste — transport, volume, EQ — fonctionne
via l'API REST unicast). Une fois les services UPnP découverts, ils sont mis en cache
(`upnp.json`) pour des lancements suivants instantanés.

## Build & lancement

```sh
./build.sh
open /Applications/CabasseRemote.app
```

`build.sh` compile, signe avec l'identité de dev stable et **installe dans `/Applications`**.
Important : lancer l'app **depuis `/Applications`**, pas depuis `build/` — un binaire recréé à
chaque build à un emplacement volatil fait révoquer par macOS l'autorisation « réseau local »,
et l'app ne trouve plus l'ampli. Depuis `/Applications` + signature stable, l'autorisation tient.
Au tout premier lancement, accepter les invites **« réseau local »** et **pare-feu**. Si, juste
après un rebuild, l'app ne se connecte pas, la quitter et la rouvrir une fois (macOS revalide le
binaire fraîchement signé).

Pour voir les logs de diagnostic :

```sh
CABASSE_DEBUG=1 build/CabasseRemote.app/Contents/MacOS/CabasseRemote
```

L'app apparaît dans la barre de menu (icône haut-parleur), sans icône Dock (`LSUIElement`).

## L'API de l'ampli (rétro-ingénierie)

L'ampli sert son propre dashboard web (Vue.js) sur `http://<ip>:34000/dashboard2/`.
Tout le pilotage passe par une **API REST JSON locale, non authentifiée**, dont le client
JS (`route`, ~187 endpoints) a servi de spec. Points saillants :

| Fonction        | Appel                                                                 |
|-----------------|-----------------------------------------------------------------------|
| État lecture    | `GET /Player/State.json` (métadonnées abrégées : `ti`=titre, `mp`=fournisseur, `thumbnail_uri`) |
| Transport       | `PUT /Player/Play.json` \| `Pause` \| `Stop` \| `Next` \| `Previous`  |
| Sources         | `GET`/`POST /Player/SourceSelection.json` (`{id:N}`)                   |
| Volume / mute   | `GET`/`POST /Zone/State.json` — voir ci-dessous                        |
| Power           | `GET`/`POST /System/PowerState.json` (`{state:bool}`)                  |
| Infos device    | `GET /System/DeviceInfo.json`                                         |

**Temps réel** : long-polling par ETag. On envoie `If-None-Match: <etag>` +
`Prefer: wait=<s>` ; le serveur répond dès que l'état change (ou 304 au bout du délai).
Le champ `version` de `Player/State.json` = la valeur d'ETag.

**Volume / mute** : lecture-modification-écriture de l'état de zone complet.
`GET /Zone/State.json` renvoie `{generation:N, rendering_zones:[{volume:0-100, muted:bool}]}`.
Pour écrire : incrémenter `generation`, modifier `rendering_zones[0].volume` (ou `.muted`),
puis `POST /Zone/State.json` avec l'objet entier et l'en-tête `If-None-Match: <generation>`.
Un `412` = conflit (quelqu'un d'autre a écrit) → on relit et on réessaie.

## Le média : UPnP (pas l'API REST)

L'API REST (:34000) ne sait ni parcourir ni jouer une radio arbitraire — c'est du contrôle pur.
Le média passe par les services UPnP de l'ampli, découverts par SSDP :

- **MediaServer** (`ContentDirectory`) : catalogue vTuner navigable. Chaque station est un item
  DIDL-Lite avec titre, genre, logo et l'URL de flux `<res>`.
- **MediaRenderer** (`AVTransport`) : `SetAVTransportURI(url) + Play` pour jouer n'importe quelle
  station.

### Pourquoi un index local plutôt qu'une recherche serveur

L'amplificateur n'expose **aucune recherche texte fonctionnelle** :
- UPnP ContentDirectory `Search` / `FreeFormQuery` : factices (renvoient les sous-dossiers en
  ignorant le critère ; `FFQCapabilities` vide).
- API vTuner cloud (`awox.vtuner.com/.../BrowseXML/Search.asp`) : répond `Content-Length: 0`
  sans session — elle exige une authentification de compte que l'app officielle établit et
  qu'un outil local ne peut pas reproduire.

D'où l'approche retenue : parcourir les listes plates de stations via la ContentDirectory de
l'ampli (qui gère l'auth vTuner pour nous), **construire un index local** et le **greper**
instantanément. Bénéfice : recherche hors-ligne, instantanée, sur tout ce qui est indexé.

## Structure

```
Sources/
  Models.swift          Modèles Codable (player, sources, zone, EQ, DEAP…)
  CabasseClient.swift   Client REST async (transport, volume, EQ, long-poll)
  Discovery.swift       Découverte Bonjour + résolution IPv4
  UPnP.swift            SSDP + ContentDirectory (browse) + AVTransport (play) + cache
  Favorites.swift       Store de favoris illimité (JSON)
  AmpController.swift    État observable + boucles long-poll + actions
  App.swift              Scènes : MenuBarExtra + fenêtre Catalogue
  Views.swift            Vues SwiftUI (menu, favoris, son, catalogue)
Info.plist              LSUIElement, ATS local, Bonjour, usage réseau local
build.sh                Compile un .app autonome avec swiftc
```

## Pistes « en mieux » (suite)

- Raccourcis clavier globaux et intégration *Now Playing* / Centre de contrôle.
- Réordonnancement / renommage des favoris, tags.
- Multi-ampli / multiroom (plusieurs zones découvertes).
- Marche/arrêt et minuteries de veille.
