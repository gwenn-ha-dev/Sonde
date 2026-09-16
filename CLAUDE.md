# Sonde — agent context

## What this is

A small macOS **menu bar** app that drives a **Cabasse Abyss / AMP 240 S** amplifier (StreamUnlimited platform — the same electronics the official *StreamCONTROL* app talks to, but native, light and instant).

Platform: macOS 26+. Build system: swiftc, no package manager. Bundle ID `dev.gwennha.Sonde`.

## Build and test

```sh
make build   # release, warnings are errors
make test
make lint    # charter compliance — run before declaring anything done
```

Never invoke `swift build`, `xcodebuild` or a build script directly; go through
the `Makefile`. It is the same interface in every project here.

## Invariants — do not break these

- **No hard-coded user-visible strings.** Everything goes through
  `Resources/Localizable.xcstrings`, present in both `en` and `fr`. Adding a
  string means adding both translations in the same change.
- **No build artefacts committed.** No `.app`, no `build/`, no `.build/`.
- **Dependencies: none.** Adding one requires documenting it in the README's
  *Dependencies* section.
- **`README.md` and `README.fr.md` stay in sync.** Editing one means editing the other.
- **The icon is generated**, never hand-placed: `outils/icone.swift` is the
  source, `make icon` rebuilds `Resources/AppIcon.icns`.
- Code, comments and commit messages are in **English**.

- `outils/build.sh` **installs into `/Applications` on every build**, on purpose: macOS grants the Local Network permission per signed bundle at a stable path, so building elsewhere breaks amp discovery. Do not "fix" this.
- `CabasseClient`, `_cabasse-api._tcp` and the `Cabasse` device name are the **amplifier's protocol**, not this app's identity. They stay.

## Layout

```
.github/
.gitignore
CHANGELOG.md
CONTRIBUTING.md
Info.plist
LICENSE
Makefile
README.md
Resources/
Sources/
Tests/
logo.png
outils/
packaging/
```

## The charter

The full norm this project follows lives at `../../Charte/CHARTE.md`.
