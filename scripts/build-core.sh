#!/usr/bin/env bash
# Builds the Rust core for iPad (device + simulator), generates the Swift
# bindings, packages everything as an XCFramework inside the MiMundoCore
# Swift package, then regenerates the Xcode project.
#
# Run this after any change under core/, and once after a fresh clone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
PKG="$ROOT/apple/MiMundoCore"
APP="$ROOT/apple/MiMundo"
LIB=libmimundo_core
FFI_MODULE=mimundo_coreFFI

# Homebrew's rustup is keg-only, so make sure cargo is on PATH.
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"

cd "$CORE"

echo "==> Building Rust core"
cargo build --lib --release                                # Mac: for bindgen
cargo build --lib --release --target aarch64-apple-ios     # iPad
cargo build --lib --release --target aarch64-apple-ios-sim # Simulator

echo "==> Generating Swift bindings"
GEN="$CORE/target/uniffi-swift"
rm -rf "$GEN"
cargo run --quiet --release --bin uniffi-bindgen -- generate \
  --library "target/release/$LIB.dylib" \
  --language swift \
  --out-dir "$GEN"

HEADERS="$GEN/headers"
mkdir -p "$HEADERS"
cp "$GEN/$FFI_MODULE.h" "$HEADERS/"
cp "$GEN/$FFI_MODULE.modulemap" "$HEADERS/module.modulemap"

echo "==> Packaging XCFramework"
rm -rf "$PKG/$FFI_MODULE.xcframework"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-ios/release/$LIB.a" -headers "$HEADERS" \
  -library "target/aarch64-apple-ios-sim/release/$LIB.a" -headers "$HEADERS" \
  -output "$PKG/$FFI_MODULE.xcframework" >/dev/null

mkdir -p "$PKG/Sources/MiMundoCore"
cp "$GEN/mimundo_core.swift" "$PKG/Sources/MiMundoCore/mimundo_core.swift"

if command -v xcodegen >/dev/null; then
  echo "==> Generating Xcode project"
  (cd "$APP" && xcodegen generate --quiet)
else
  echo "xcodegen not found: install it with 'brew install xcodegen'" >&2
fi

echo "==> Done. Open apple/MiMundo/MiMundo.xcodeproj"
