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

Requirements: an **Apple Silicon Mac**, Xcode,
[rustup](https://rustup.rs) (`brew install rustup`), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
The Rust version and iPad targets are pinned in `core/rust-toolchain.toml`
and installed automatically.

```bash
./scripts/build-core.sh            # fast debug build of the Rust core
./scripts/build-core.sh --release  # optimized build, for the real iPad
open apple/MiMundo/MiMundo.xcodeproj
```

After that, Xcode rebuilds the Rust core automatically whenever `core/`
changes (a scheme pre-action; Release builds use `--release`). If the Rust
build fails, the Xcode build fails with the compiler error; the full log is in
`apple/MiMundo/build/rust-core.log`. Re-run `./scripts/build-core.sh` by hand
only after editing `project.yml`.
Rust checks: `cd core && cargo test && cargo clippy --all-targets`.

CI (`.github/workflows/ci.yml`) runs on every PR and push to `main`:
`cargo fmt`, `clippy -D warnings`, `cargo test`, then a from-scratch
`build-core.sh` and an iPad simulator build.

To run on a real iPad, copy `apple/MiMundo/Config/Local.xcconfig.example` to
`Local.xcconfig` (gitignored) and put in your Apple Team ID.

## License

Licensed under the [MIT License](LICENSE).
