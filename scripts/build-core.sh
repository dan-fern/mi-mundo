#!/usr/bin/env bash
# Builds the Rust core for iPad (device + simulator), generates the Swift
# bindings, packages everything as an XCFramework inside the MiMundoCore
# Swift package, then regenerates the Xcode project.
#
# Usage: scripts/build-core.sh [--release] [--if-stale] [--no-project]
#        scripts/build-core.sh --check
#   (default)     fast debug build of the Rust core, for day-to-day work
#   --release     optimized (LTO, stripped) build, for the real iPad / sharing
#   --if-stale    do nothing if the last build is still current
#   --no-project  skip regenerating the Xcode project
#   --check       only report whether the Rust core needs rebuilding (exit 1
#                 with an Xcode-style error if it does); builds nothing
#
# Run it by hand once after a fresh clone and after editing
# apple/MiMundo/project.yml. After that, Xcode runs it automatically before
# each build (scheme pre-action with --if-stale --no-project), so editing
# core/ and pressing Run picks up the change. Apple Silicon Macs only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
PKG="$ROOT/apple/MiMundoCore"
APP="$ROOT/apple/MiMundo"
LIB=libmimundo_core
FFI_MODULE=mimundo_coreFFI
IOS_TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim)
# Records which profile the current XCFramework was built with; its mtime
# marks when it was built. Gitignored.
STAMP="$PKG/.core-stamp"

PROFILE=debug
CARGO_PROFILE_FLAG=()
MODE=build
REGENERATE_PROJECT=1
usage() { echo "usage: $0 [--release] [--if-stale] [--no-project] | --check" >&2; exit 2; }
for arg in "$@"; do
  case "$arg" in
    --release) PROFILE=release; CARGO_PROFILE_FLAG=(--release) ;;
    --if-stale) MODE=if-stale ;;
    --no-project) REGENERATE_PROJECT=0 ;;
    --check) MODE=check ;;
    *) usage ;;
  esac
done

fail() { echo "error: $*" >&2; exit 1; }

# Prints the first Rust input newer than the last build, or "missing" if
# there is no usable build. Prints nothing when the build is current.
first_stale_input() {
  if [[ ! -f "$STAMP" || ! -d "$PKG/$FFI_MODULE.xcframework" \
        || ! -f "$PKG/Sources/MiMundoCore/mimundo_core.swift" ]]; then
    echo "missing"
    return
  fi
  find "$CORE/src" "$CORE/Cargo.toml" "$CORE/Cargo.lock" \
       "$CORE/rust-toolchain.toml" "$ROOT/scripts/build-core.sh" \
       -newer "$STAMP" -print 2>/dev/null | head -n 1
}

if [[ "$MODE" == check ]]; then
  stale="$(first_stale_input)"
  if [[ -n "$stale" ]]; then
    echo "error: The Rust core is out of date (${stale#"$ROOT/"}). Xcode normally rebuilds it before each build; see apple/MiMundo/build/rust-core.log, or run scripts/build-core.sh." >&2
    exit 1
  fi
  exit 0
fi

if [[ "$MODE" == if-stale ]]; then
  stale="$(first_stale_input)"
  built_profile="$(cat "$STAMP" 2>/dev/null || true)"
  if [[ -z "$stale" && "$built_profile" == "$PROFILE" ]]; then
    echo "==> Rust core is up to date ($PROFILE)"
    exit 0
  fi
  echo "==> Rust core needs rebuilding (${stale:-profile $built_profile -> $PROFILE})"
fi

# Xcode runs scheme pre-actions with a minimal PATH, so add Homebrew's
# locations explicitly. Its rustup is keg-only, so add that too.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"
if command -v brew >/dev/null && RUSTUP_PREFIX="$(brew --prefix rustup 2>/dev/null)"; then
  export PATH="$RUSTUP_PREFIX/bin:$PATH"
fi

echo "==> Checking tools"
[[ "$(uname -m)" == arm64 ]] || fail "Mi Mundo builds on Apple Silicon Macs only."
command -v cargo >/dev/null    || fail "cargo not found. Install Rust: brew install rustup && rustup default stable"
command -v xcodebuild >/dev/null || fail "xcodebuild not found. Install Xcode."
if [[ "$REGENERATE_PROJECT" == 1 ]]; then
  command -v xcodegen >/dev/null || fail "xcodegen not found. Install it: brew install xcodegen"
fi

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
# Only replace the bindings when they changed, so Xcode doesn't recompile
# the Swift package for nothing.
if ! cmp -s "$GEN/mimundo_core.swift" "$PKG/Sources/MiMundoCore/mimundo_core.swift"; then
  cp "$GEN/mimundo_core.swift" "$PKG/Sources/MiMundoCore/mimundo_core.swift"
fi

echo "$PROFILE" > "$STAMP"

if [[ "$REGENERATE_PROJECT" == 1 ]]; then
  echo "==> Generating Xcode project"
  (cd "$APP" && xcodegen generate --quiet)
fi

echo "==> Done ($PROFILE). Open apple/MiMundo/MiMundo.xcodeproj"
