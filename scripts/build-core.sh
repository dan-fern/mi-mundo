#!/usr/bin/env bash
# Builds the Rust core for iPad (device + simulator), generates the Swift
# bindings, packages everything as an XCFramework inside the MiMundoCore
# Swift package, then regenerates the Xcode project.
#
# Usage: scripts/build-core.sh [--release]
#   default    fast debug build of the Rust core, for day-to-day work
#   --release  optimized (LTO, stripped) build, for the real iPad / sharing
#
# Run this after any change under core/ or apple/MiMundo/project.yml, and
# once after a fresh clone. Apple Silicon Macs only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
PKG="$ROOT/apple/MiMundoCore"
APP="$ROOT/apple/MiMundo"
LIB=libmimundo_core
FFI_MODULE=mimundo_coreFFI
IOS_TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim)

PROFILE=debug
CARGO_PROFILE_FLAG=()
case "${1:-}" in
  "") ;;
  --release) PROFILE=release; CARGO_PROFILE_FLAG=(--release) ;;
  *) echo "usage: $0 [--release]" >&2; exit 2 ;;
esac

fail() { echo "error: $*" >&2; exit 1; }

# Homebrew's rustup is keg-only, so put it on PATH if it's installed.
if command -v brew >/dev/null && RUSTUP_PREFIX="$(brew --prefix rustup 2>/dev/null)"; then
  export PATH="$RUSTUP_PREFIX/bin:$PATH"
fi
export PATH="$HOME/.cargo/bin:$PATH"

echo "==> Checking tools"
[[ "$(uname -m)" == arm64 ]] || fail "Mi Mundo builds on Apple Silicon Macs only."
command -v cargo >/dev/null    || fail "cargo not found. Install Rust: brew install rustup && rustup default stable"
command -v xcodegen >/dev/null || fail "xcodegen not found. Install it: brew install xcodegen"
command -v xcodebuild >/dev/null || fail "xcodebuild not found. Install Xcode."

cd "$CORE"
# core/rust-toolchain.toml installs the pinned toolchain and iOS targets on
# first use; this just makes that happen up front with a clear message.
INSTALLED_TARGETS="$(rustup target list --installed)"
for target in "${IOS_TARGETS[@]}"; do
  grep -qx "$target" <<<"$INSTALLED_TARGETS" \
    || fail "Rust target $target missing. Run: rustup target add $target"
done

echo "==> Building Rust core ($PROFILE)"
# (The ${arr[@]+...} form keeps macOS's bash 3.2 happy with an empty array.)
cargo build --lib ${CARGO_PROFILE_FLAG[@]+"${CARGO_PROFILE_FLAG[@]}"} \
  --target "${IOS_TARGETS[0]}" --target "${IOS_TARGETS[1]}"

echo "==> Generating Swift bindings"
# The Mac-side library and bindgen are only used to read the exported API,
# so a debug build is enough regardless of PROFILE.
cargo build --lib
GEN="$CORE/target/uniffi-swift"
rm -rf "$GEN"
cargo run --quiet --features cli --bin uniffi-bindgen -- generate \
  --library "target/debug/$LIB.dylib" \
  --language swift \
  --out-dir "$GEN"

HEADERS="$GEN/headers"
mkdir -p "$HEADERS"
cp "$GEN/$FFI_MODULE.h" "$HEADERS/"
cp "$GEN/$FFI_MODULE.modulemap" "$HEADERS/module.modulemap"

echo "==> Packaging XCFramework"
rm -rf "$PKG/$FFI_MODULE.xcframework"
xcodebuild -create-xcframework \
  -library "target/${IOS_TARGETS[0]}/$PROFILE/$LIB.a" -headers "$HEADERS" \
  -library "target/${IOS_TARGETS[1]}/$PROFILE/$LIB.a" -headers "$HEADERS" \
  -output "$PKG/$FFI_MODULE.xcframework" >/dev/null

mkdir -p "$PKG/Sources/MiMundoCore"
cp "$GEN/mimundo_core.swift" "$PKG/Sources/MiMundoCore/mimundo_core.swift"

echo "==> Generating Xcode project"
(cd "$APP" && xcodegen generate --quiet)

echo "==> Done ($PROFILE). Open apple/MiMundo/MiMundo.xcodeproj"
