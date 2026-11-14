# Mi Mundo

A gamified geography app for iPad: explore the world map, get quizzed on
countries, capitals and flags, and earn points for real-world rewards.

Built with SwiftUI and a Rust core. Works offline.

**Status:** in development — profiles, attendance, the explore map, the parents' quiz queue and playing quizzes (name, capital, and flag picked from four) work; drawing flags is next.
See [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)
and [CHANGELOG.md](CHANGELOG.md).

## Layout

| Path | What it is |
|---|---|
| `core/` | Rust game logic (scoring, attendance, …), exported to Swift with UniFFI |
| `apple/MiMundoCore/` | Swift package wrapping the Rust core as an XCFramework |
| `apple/MiMundo/` | SwiftUI iPad app; `project.yml` is the XcodeGen spec |
| `scripts/build-core.sh` | Builds Rust for iPad + simulator, generates bindings and the Xcode project |
| `tools/` | Map/flag/facts data pipeline (see "Map data" below) |
| `apple/MiMundo/Resources/` | Bundled data: `World.bin`, `Features.bin`, `Countries.json`, `Flags.xcassets` |

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
Rust checks: `cd core && cargo test --features mapgen && cargo clippy --all-targets --features cli,mapgen`.

CI (`.github/workflows/ci.yml`) runs on every PR and push to `main`:
`cargo fmt`, `clippy -D warnings`, `cargo test`, then a from-scratch
`build-core.sh` and an iPad simulator build.

To run on a real iPad, copy `apple/MiMundo/Config/Local.xcconfig.example` to
`Local.xcconfig` (gitignored) and put in your Apple Team ID.

## Map data

The bundled map data is committed, so normal builds don't need this. To
refresh it (needs Inkscape: `brew install --cask inkscape`):

```bash
./tools/fetch-data.sh   # Natural Earth + flag-icons -> data/raw/ (checksums in tools/data.sha256)
./tools/build-data.sh   # -> apple/MiMundo/Resources/, then runs the data tests in core/tests/
```

Country facts come from a committed Wikidata snapshot,
`tools/wikidata-facts.json` (refresh with `python3 -I tools/fetch-facts.py "$PWD"`
and review the diff); landmarks likewise from `tools/wikidata-landmarks.json`
(`tools/fetch-landmarks.py`). Hand fixes and hand-picked landmarks go in
`tools/facts-overrides.json` and apply offline. CI rebuilds `World.bin`,
`Features.bin` and `Countries.json` from the pinned sources and fails if the
committed files differ. `core/tests/world_bin.rs` checks the
map against known places (capitals, open ocean, the ±180° seam, enclaves,
tiny islands).

## License

Licensed under the [MIT License](LICENSE). Bundled map data and flags come
from Natural Earth, Wikidata and flag-icons; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
