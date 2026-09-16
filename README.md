# Sonde

[![CI](https://github.com/gwenn-ha-dev/Sonde/actions/workflows/ci.yml/badge.svg)](https://github.com/gwenn-ha-dev/Sonde/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
![Platform](https://img.shields.io/badge/Platform-macOS%2014%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)

*🇬🇧 English · 🇫🇷 [Français](./README.fr.md)*

A small macOS **menu bar** app that drives a **Cabasse Abyss / AMP 240 S** amplifier (StreamUnlimited platform — the same electronics the official *StreamCONTROL* app talks to, but native, light and instant).

## Features

- **Automatic discovery** on the network (Bonjour `_cabasse-api._tcp`) with **automatic reconnection**: if the amp reboots, changes IP, or the Mac wakes up, discovery restarts on its own.
- **Power / standby** from the menu, with a **sleep timer** (15/30/60/90 min, visible countdown, cancellable).
- **Live now playing**: title, provider, artwork, transport state. Play/pause, previous, next.
- **Volume and mute** on a 0–100 slider that mirrors the physical remote. The displayed value is exactly `rendering_zones[0].volume` — the same number the official app shows.
- **A volume ceiling that is actually enforced** (on by default at 50). Not a mark on the slider: the long-polling loop watches the zone state and **pulls the amp back to the ceiling whatever caused the overshoot** — physical remote, official app, AirPlay, Bluetooth.
- **Low startup volume**, radio and podcast browsing, favourites.
- No dependencies — Apple frameworks only (SwiftUI, Network, URLSession).

## Install

```sh
git clone https://github.com/gwenn-ha-dev/Sonde.git
cd Sonde
make build
```

## How it works

`CabasseClient` speaks the amp's HTTP API on `http://<host>:34000`, unauthenticated. State is followed by long polling, which is why the volume ceiling can react to a change that did not come from this app. The type keeps the `Cabasse` name because it names the device protocol, not this app.

## Build

| Command | What it does |
|---|---|
| `make build` | Release build, warnings are errors |
| `make test` | Run the test suite |
| `make run` | Launch the app |
| `make icon` | Regenerate `Resources/AppIcon.icns` |
| `make package` | Produce a distributable bundle in `build/` |
| `make lint` | Check compliance with the project charter |
| `make help` | List every target |

## Dependencies

None — Apple frameworks only.

## License

MIT © 2026 gwenn-ha-dev — see [LICENSE](./LICENSE).
