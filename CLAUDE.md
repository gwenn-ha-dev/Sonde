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
  `Resources/{en,fr}.lproj/Localizable.strings` (the bundle is assembled by
  hand, so no `.xcstrings`; keys are the French sentences). Adding a string
  means adding both translations in the same change. `Text(cond ? "a" : "b")`
  and a label typed `String` both skip the table: write
  `cond ? Text("a") : Text("b")`, type the label `LocalizedStringKey`, and use
  `String(localized:)` for messages built in the model.
- **No build artefacts committed.** No `.app`, no `build/`, no `.build/`.
- **Dependencies: none.** Adding one requires documenting it in the README's
  *Dependencies* section.
- **`README.md` and `README.fr.md` stay in sync.** Editing one means editing the other.
- **The icon is generated**, never hand-placed: `outils/icone.swift` is the
  source, `make icon` rebuilds `Resources/AppIcon.icns`.
- Identifiers, commit messages and both READMEs are in **English**; comments may
  be in English or French (charter §2).

- `outils/build.sh` **installs into `/Applications` on every build**, on purpose: macOS grants the Local Network permission per signed bundle at a stable path, so building elsewhere breaks amp discovery. Do not "fix" this.
- `CabasseClient`, `_cabasse-api._tcp` and the `Cabasse` device name are the **amplifier's protocol**, not this app's identity. They stay.

## Public identity and releases (charter §12)

- Commit as `gwenn-ha-dev <13298867+gwenn-ha-dev@users.noreply.github.com>` (set
  in this repo's git config) and in UTC: `TZ=UTC git commit …`. No personal name,
  email or `/Users/…` path in tracked files. `../../Charte/outils/identite.sh .` checks.
- A release: `make sign && make dmg && make shots && make release-check`, then
  tag `v<version>` and attach `build/Sonde-<version>.dmg` — see
  `../../Charte/DISTRIBUTION-AGENT.md`, phase 3. The version is
  `CFBundleShortVersionString` in `Info.plist`.
- Signing, in two stages. `make build` signs `build/Sonde.app` with the
  **Apple Development** identity, chosen **by hash** (two certificates share
  its name, and the name alone is ambiguous), and installs a copy in
  `/Applications` — the copy the Local Network permission belongs to.
  `make package` only checks the bundle. `make sign` re-signs `build/Sonde.app`
  with the **Developer ID** and the hardened runtime, then notarizes it. The app
  has no entitlements: Local Network goes through `NSLocalNetworkUsageDescription`
  and `NSBonjourServices` in `Info.plist`. The notarized build discovers and connects
  to the amp, checked on a real AMP 240 S. Never `--deep`.
- The Developer ID build is a different signature from the one in
  `/Applications`: launching it may make macOS ask for Local Network again.
- Captures: `make shots` runs `outils/captures.sh`, which needs the amplifier on
  the network. The menu bar popover cannot be opened without Accessibility, so
  views are reached by launch arguments: `-window panel|catalog|stats` (the
  panel is the menu bar content in an ordinary window), `-catalog.tab podcasts`,
  `-search <text>`. They live in the launch's argument domain; nothing persists.

## Layout

```
.github/
.gitignore
CHANGELOG.md
CONTRIBUTING.md
docs/img/          README captures, social preview
Info.plist
LICENSE
Makefile
README.md
Resources/
Sources/
Tests/
site/              GitHub Pages page
outils/
```

## The charter

The full norm this project follows lives at `../../Charte/CHARTE.md`.
