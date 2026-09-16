# Changelog

All notable changes to Sonde are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- The app now carries the generated icon. The build rebuilt its own from
  `logo.png` and overwrote it, so `make icon` never reached the bundle, and
  LaunchServices kept serving the cached entry of the bundle each build
  destroys. The DMG background now draws the same generated icon.

## [0.1.0] — 2026-09-16

### Added
- Initial release.

[Unreleased]: https://github.com/gwenn-ha-dev/Sonde/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/gwenn-ha-dev/Sonde/releases/tag/v0.1.0
