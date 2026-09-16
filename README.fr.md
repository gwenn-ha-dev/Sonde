# Sonde

[![CI](https://github.com/gwenn-ha-dev/Sonde/actions/workflows/ci.yml/badge.svg)](https://github.com/gwenn-ha-dev/Sonde/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
![Platform](https://img.shields.io/badge/Platform-macOS%2014%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)

*🇬🇧 [English](./README.md) · 🇫🇷 Français*

Petite app **barre de menu macOS** pour piloter un amplificateur **Cabasse Abyss / AMP 240 S** (plateforme StreamUnlimited, la même électronique que l'app officielle *StreamCONTROL*, mais native, légère et instantanée).

## Fonctionnalités

- **Découverte automatique** de l'ampli sur le réseau (Bonjour `_cabasse-api._tcp`), avec **reconnexion automatique** : si l'ampli redémarre, change d'IP, ou au réveil du Mac, la découverte repart toute seule.
- **Marche / veille** depuis le menu, avec **minuteur de mise en veille** (15/30/60/90 min, compte à rebours affiché, annulable).
- **Now playing temps réel** : titre, fournisseur, pochette, état de lecture. Lecture/pause, précédent, suivant.
- **Volume et mute** sur un slider 0–100 qui reflète aussi la télécommande physique. La valeur affichée est exactement `rendering_zones[0].volume` — la même que celle de l'app officielle.
- **Plafond de volume réellement appliqué** (activé par défaut à 50). Ce n'est pas un repère sur le slider : la boucle de long-polling surveille l'état de zone et **ramène l'ampli au plafond quelle que soit l'origine du dépassement** — télécommande physique, app officielle, AirPlay, Bluetooth.
- **Volume de démarrage bas**, navigation radios et podcasts, favoris.
- Aucune dépendance — frameworks Apple uniquement (SwiftUI, Network, URLSession).

## Installation

```sh
git clone https://github.com/gwenn-ha-dev/Sonde.git
cd Sonde
make build
```

## Comment ça marche

`CabasseClient` parle l'API HTTP de l'ampli sur `http://<hôte>:34000`, sans authentification. L'état est suivi par long polling, ce qui permet au plafond de volume de réagir à un changement qui ne vient pas de cette app. Le type garde le nom `Cabasse` parce qu'il nomme le protocole de l'appareil, pas cette app.

## Construction

| Commande | Ce qu'elle fait |
|---|---|
| `make build` | Compilation release, tout avertissement est une erreur |
| `make test` | Lance la suite de tests |
| `make run` | Lance l'app |
| `make icon` | Régénère `Resources/AppIcon.icns` |
| `make package` | Produit un bundle distribuable dans `build/` |
| `make lint` | Vérifie la conformité à la charte |
| `make help` | Liste toutes les cibles |

## Dépendances

Aucune — frameworks Apple uniquement.

## Licence

MIT © 2026 gwenn-ha-dev — voir [LICENSE](./LICENSE).
