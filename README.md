# Mi Mundo

A gamified geography app for iPad: explore the world map, get quizzed on
countries, capitals and flags, and earn points for real-world rewards.

Built with SwiftUI and a Rust core. Works offline.

**Status:** planning. See [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)
and [CHANGELOG.md](CHANGELOG.md).

## Layout

| Path | What it is |
|---|---|
| `core/` | Rust game logic (scoring, attendance, …), exported to Swift with UniFFI |
| `apple/MiMundoCore/` | Swift package wrapping the Rust core as an XCFramework |
| `apple/MiMundo/` | SwiftUI iPad app; `project.yml` is the XcodeGen spec |
| `scripts/build-core.sh` | Builds Rust for iPad + simulator, generates bindings and the Xcode project |

## Getting started

Requirements: Xcode, [rustup](https://rustup.rs) (`brew install rustup`), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
rustup default stable
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
./scripts/build-core.sh
open apple/MiMundo/MiMundo.xcodeproj
```

Re-run `./scripts/build-core.sh` after changing anything in `core/` or
`project.yml`. Rust tests: `cd core && cargo test`.

## License

Licensed under the [MIT License](LICENSE).
