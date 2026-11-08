# Changelog

All notable changes to Mi Mundo are recorded here. Every PR adds a line under
**Unreleased**, describing what changed and why. When a build goes onto the
iPad as a named version, the Unreleased entries move under that version.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions: [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Project scaffold: Rust core (`core/`) exported to Swift via UniFFI 0.32,
  `MiMundoCore` Swift package, and an iPad-only SwiftUI app generated with
  XcodeGen. `scripts/build-core.sh` builds the XCFramework and Xcode project.
- First core rules with tests: retake scoring (full, ½, ¼, then 0; flag
  multiple choice halves) and the 7-day attendance gauge (capped at 5).
- Placeholder home screen that calls the Rust core, verified in the
  iPad mini (6th generation) simulator.
- Requirements doc (`docs/REQUIREMENTS.md`) covering explore mode, quiz mode,
  flag drawing, scoring, rewards, attendance gauge and parent stats.
- README, MIT license, `.gitignore` for Xcode and Rust, and this changelog.
