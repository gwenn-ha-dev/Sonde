# Changelog

All notable changes to Sonde are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] — 2026-10-09

First release with a download: a signed and notarized `.dmg`.

### Added
- Sonde is distributed as `Sonde-0.3.0.dmg`, signed with a Developer ID,
  notarized and stapled: it opens with a double click on another Mac.
- README captures of the menu bar panel, the catalogue, the podcasts and the
  stream statistics, in English and French.
- `make sign`, `make dmg`, `make shots`, `make release-check`.
- A project site (`site/`) for GitHub Pages.

### Fixed
- Much of the interface stayed in French on an English system: tooltips,
  search prompts, empty states, the stream statistics, error messages and the
  labels chosen by a condition. Everything visible now follows the system
  language, and an episode's duration is formatted for the locale.
- The stable development signature was never applied: two certificates of the
  same name made it ambiguous, and the build hid the refusal. The installed
  app was signed ad hoc, which is what costs the Local Network permission.
- `Info.plist` declared macOS 14 as the minimum, while the binary needs 26.
- The panel cut the quality badge short when the loudness sat beside it, and
  the stream statistics window opened too short to show the fill rate.
- The app now carries the generated icon. The build rebuilt its own from
  `logo.png` and overwrote it, so `make icon` never reached the bundle, and
  LaunchServices kept serving the cached entry of the bundle each build
  destroys.

## [0.2.0] — 2026-09-10

Tagged, never released as a download.

### Added
- Worldwide station search (Radio Browser) ahead of the amplifier's vTuner
  index, and adding a station by its stream URL.
- Podcasts: search, episodes, followed shows.
- The current song, read from the stream's ICY metadata.
- Measured loudness (EBU R128) shown next to each station, never corrected.

### Changed
- The volume ceiling is enforced, whatever pushed the volume past it.

## [0.1.0] — 2026-08-15

### Added
- Initial version, under the name Cabasse Remote. Never tagged.

[Unreleased]: https://github.com/gwenn-ha-dev/Sonde/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/gwenn-ha-dev/Sonde/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/gwenn-ha-dev/Sonde/releases/tag/v0.2.0
