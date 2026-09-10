# Cabasse Remote

Petite app **barre de menu macOS** pour piloter un amplificateur **Cabasse Abyss / AMP 240 S**
(plateforme StreamUnlimited, la même électronique que l'app officielle *StreamCONTROL*, mais
native, légère et instantanée).

100 % frameworks Apple (SwiftUI, Network, URLSession) — **aucune dépendance externe**.

## Ce que ça fait

- **Découverte automatique** de l'ampli sur le réseau (Bonjour `_cabasse-api._tcp`), avec
  **reconnexion automatique** : si l'ampli redémarre ou change d'IP (ou au réveil du Mac),
  l'app relance la découverte toute seule.
- **Marche / veille** de l'ampli depuis le menu (bouton ⏻), avec **minuteur de mise en
  veille** (15/30/60/90 min, compte à rebours affiché, annulable).
- **Now playing** temps réel : titre, fournisseur, pochette, état lecture.
- **Transport** : lecture/pause, précédent, suivant.
- **Volume + mute** avec slider (échelle 0–100), reflète aussi les changements faits
  depuis la télécommande physique. L'échelle est celle de l'ampli : la valeur affichée est
  exactement `rendering_zones[0].volume`, identique à celle de l'app officielle (vérifié en
  relevant les deux en parallèle).
- **Plafond de volume réellement appliqué** (activé par défaut à 50, réglable dans la section
  Son, désactivable). Ce n'est pas un simple repère sur le slider : la boucle de long-polling
  surveille l'état de zone et **ramène l'ampli au plafond quelle que soit l'origine du
  dépassement** — télécommande physique, app officielle, AirPlay, Bluetooth. Une note
  transitoire sous le slider dit quand le limiteur est intervenu. Réglages persistés dans
  les préférences (`volumeCapEnabled`, `volumeCap`).
- **Volume de démarrage bas** : au lancement de l'app et après un allumage commandé depuis
  l'app, si **rien n'est en lecture**, le volume est préréglé à **4** pour que l'ampli ne
  démarre jamais fort (son propre volume de démarrage peut monter à 50). Jamais appliqué
  pendant une lecture. À savoir : cela **écrase le volume courant** de l'ampli au lancement.
- **Loudness mesurée des stations (EBU R128)** : voir plus bas.
- **Sélection de source** (DLNA, Bluetooth, Analog 1/2, Optical, TV, AirPlay, Roon…). Les sources
  Tidal, Qobuz et Alexa sont volontairement masquées.
- **Favoris radios illimités** (pas les 9 slots de l'ampli) avec **filtre grep instantané**
  (multi-termes, insensible casse/accents). Ajout depuis « la radio en cours » (★) ou depuis
  le catalogue. Stockés dans `~/Library/Application Support/CabasseRemote/favorites.json`.
- **Recherche mondiale (Radio Browser) — source primaire** : la recherche du Catalogue
  interroge [radio-browser.info](https://www.radio-browser.info) (annuaire communautaire,
  ~50 000 stations, gratuit, sans clé), résultats en tête, l'index vTuner en section
  secondaire. Indispensable pour les stations que vTuner a perdues (Radio Kerne, Arvorig FM… —
  hébergées sur `stream.radios.bzh`) : l'ampli joue leur URL de flux directe (HTTP **ou HTTPS**,
  testé) via AVTransport, exactement comme une station vTuner. ★ pour mettre en favori.
  Pochettes : favicon de l'annuaire, sinon icône du site de la station via
  `icons.duckduckgo.com` (dérivée de son homepage).
- **Ajout manuel par URL** (bouton « + » dans la section Favoris) : nom + URL de flux
  directe (+ site web optionnel pour le logo) → favori. Filet de sécurité pour les radios
  absentes de tous les annuaires. (Arvorig FM, elle, a été déclarée dans Radio Browser au
  passage — la recherche la trouve désormais.)
- **Titre du morceau en cours (ICY)** : pour les webradios, l'app lit les métadonnées ICY
  directement depuis le flux (`Icy-MetaData: 1`, un bloc audio ~16 Ko toutes les 20 s, ~3 Mo/h)
  et affiche « ♪ Artiste - Titre » sous le nom de la station, ainsi que dans le Now Playing
  macOS (morceau en titre, station en artiste). Les flux sans ICY sont détectés et laissés
  tranquilles. La lecture de l'ampli n'est pas affectée (connexion séparée, côté Mac).
- **Podcasts** (onglet dédié dans la fenêtre Catalogue) : recherche dans le catalogue
  Apple (API iTunes Search, gratuite, sans clé — l'annuaire de fait du podcast), liste des
  épisodes parsée en direct depuis le flux RSS de l'émission (titre, date, durée), lecture
  sur l'ampli via AVTransport (fichiers MP3/AAC, redirections suivies, testé). ★ sur une
  émission = suivie (seul le `feedUrl` est stocké dans `podcasts.json`, les épisodes sont
  toujours à jour). **Cas Radio France géré automatiquement** : leurs émissions sont dans
  le catalogue Apple mais sans flux RSS (stratégie app-first) ; l'app reconstruit alors
  l'URL de la page de l'émission sur radiofrance.fr (slug prévisible dérivé du titre,
  essai multi-antennes) et en extrait le flux `radiofrance-podcast.net` — transparent dans
  la recherche. Pour les autres éditeurs qui retiendraient leur RSS : **coller l'URL du
  flux directement dans le champ de recherche**, l'app le parse et présente l'émission.
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
  reste le nom de la station) — c'est pourquoi l'app échantillonne l'ICY elle-même (voir plus
  haut).

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

### Distribution : DMG

```sh
./build.sh && ./package.sh   # → build/CabasseRemote.dmg
```

`package.sh` fabrique un DMG « glisser dans Applications » : fond dessiné (rendu par
`packaging/dmg-background.swift`, @2x), icônes positionnées, icône de volume, compression
UDZO. Sur un autre Mac, l'app n'étant pas notarisée : après la copie,
`xattr -dr com.apple.quarantine /Applications/CabasseRemote.app` (ou Réglages →
Confidentialité et sécurité → « Ouvrir quand même »).

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
Piège vérifié sur firmware 25.04.10 : **`muted` est omis de la zone quand il vaut `false`**,
et n'apparaît que lorsque la coupure est active — d'où le `?? false` au décodage, verrouillé
par un test. `/Mixer/Capability/Mute.json` reflète le même état en lecture (et accepte
`POST {"mute": bool}`), mais l'app pilote tout par la zone, ce qui suffit dans les deux sens.
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

## Tests

`./test.sh` compile et exécute la suite — même chaîne que `build.sh` : swiftc, pas de SPM,
pas de dépendance. Seules les sources sans interface y entrent (le `@main` de `App.swift`
entrerait en collision avec le point d'entrée des tests).

Couverture ciblée sur ce qui casse silencieusement : le décodage de l'état de zone
(dont l'omission de `muted`), le filtre grep des favoris, le bornage des préférences, et la
mesure de loudness — dont le **cas 1 d'EBU Tech 3341** (sinus 1 kHz à −23 dBFS crête →
−23,0 LUFS ±0,1), la linéarité et le comportement sur silence numérique.

## Structure

```
Sources/
  Models.swift             Modèles Codable (player, sources, zone, EQ, DEAP…)
  CabasseClient.swift      Client REST async (transport, volume, EQ, power, long-poll)
  Discovery.swift          Découverte Bonjour + résolution IPv4
  UPnP.swift               SSDP + ContentDirectory (browse) + AVTransport (play) + cache
  Favorites.swift          Store de favoris radios illimité (JSON)
  RadioIndex.swift         Index local du catalogue vTuner (crawl + cache)
  RadioBrowser.swift       Annuaire mondial radio-browser.info + fallback logos
  Podcasts.swift           Catalogue Apple + parseur RSS + récup. Radio France + store
  ICYMetadata.swift        Échantillonnage du titre en cours depuis le flux (ICY)
  SystemNowPlaying.swift   Intégration Now Playing / touches média macOS
  Support.swift            Factory URLSession, débounce, filtre grep partagés
  AmpController.swift      Connexion, power/veille, lecture, volume, EQ, actions
  CatalogController.swift  Navigation vTuner + index local + recherche Radio Browser
  PodcastsController.swift Recherche/épisodes/suivis podcasts
  App.swift                Scènes : MenuBarExtra + fenêtres Catalogue et Stats
  Views.swift              Vues SwiftUI (menu, favoris, son, catalogue, podcasts)
  Loudness.swift           Mesure EBU R128 native + moyenne glissante par station
Info.plist               LSUIElement, ATS, Bonjour, usage réseau local
LICENSE                  MIT
build.sh                 Compile un .app autonome avec swiftc, installe dans /Applications
test.sh                  Compile et lance la suite de tests (swiftc, sans dépendance)
```

## Loudness : pourquoi deux radios au même volume ne sonnent pas pareil

Les favoris viennent de deux mondes. Les stations **vTuner** pointent vers les URL que joue
aussi l'app officielle (FIP → `icecast.radiofrance.fr`, diffusé au standard broadcast
**−18 LUFS**). Les stations trouvées via **Radio Browser** pointent vers le flux direct de
la station, souvent un AzuraCast associatif poussé au maximum : Arvorig FM et Radio Kerne
ont été mesurées entre **−12 et −10 LUFS**, soit **6 à 8 LU au-dessus** — un facteur ~2,4 en
niveau perçu, avec une plage dynamique écrasée (LRA 1,3 LU contre 4,0 LU pour FIP).

Passer d'un favori à l'autre au même réglage de volume fait donc un bond de niveau qui n'a
rien à voir avec l'app : c'est le programme qui arrive plus fort. L'app **mesure et affiche**
ce niveau, sans jamais corriger le volume à ta place — la décision reste à toi.

- Mesure : **loudness intégrée EBU R128 / ITU-R BS.1770-4**, implémentée dans
  `Sources/Loudness.swift` avec les seuls frameworks Apple (pondération K dérivée pour la
  fréquence d'échantillonnage réelle, blocs de 400 ms à 75 % de recouvrement, portes absolue
  −70 LUFS et relative −10 LU). Recoupée avec le filtre `ebur128` de ffmpeg sur un fichier
  identique : **−11,73 LUFS ici contre −11,7 là**.
- Échantillonnage : ~25 s prélevées depuis le Mac 5 s après le début de la lecture, décodées
  via AVFoundation. Le flux de l'ampli n'est pas touché. Ogg/Opus et les playlists sont
  ignorés (non décodables ou non audio).
- Un seul échantillon d'un flux vivant varie de quelques LU selon ce qui passe à l'antenne :
  la valeur est donc une **moyenne glissante**, affinée jusqu'à 5 lectures puis laissée
  tranquille pendant 3 mois. Stockage :
  `~/Library/Application Support/CabasseRemote/loudness.json`.
- Affichage : badge à côté de chaque favori et sous le titre en cours, **orange au-delà de
  −14 LUFS** (≥ 4 LU au-dessus de la référence). Le survol détaille l'écart et le nombre
  d'échantillons.

## Licence

[MIT](LICENSE) — © 2026 Thierry Le Bris.

Projet indépendant, sans lien avec Cabasse. L'API locale de l'ampli a été documentée par
rétro-ingénierie du dashboard web embarqué, sur du matériel possédé, pour un usage personnel.
« Cabasse », « Abyss » et « AMP 240 S » appartiennent à leurs détenteurs respectifs.

## Pistes « en mieux » (suite)

- Raccourcis clavier globaux et intégration *Now Playing* / Centre de contrôle.
- Réordonnancement / renommage des favoris, tags.
- Multi-ampli / multiroom (plusieurs zones découvertes).
