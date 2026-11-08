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
usage() { echo "usage: $0 [--release] [--if-stale] [--no-project] | --check [--release]" >&2; exit 2; }
set_mode() {
  [[ "$MODE" == build || "$MODE" == "$1" ]] || usage # --check and --if-stale conflict
  MODE="$1"
}
for arg in "$@"; do
  case "$arg" in
    --release) PROFILE=release; CARGO_PROFILE_FLAG=(--release) ;;
    --if-stale) set_mode if-stale ;;
    --no-project) REGENERATE_PROJECT=0 ;;
    --check) set_mode check ;;
    *) usage ;;
  esac
done
[[ "$MODE" != check || "$REGENERATE_PROJECT" == 1 ]] || usage

fail() { echo "error: $*" >&2; exit 1; }
LOG="$APP/build/rust-core.log"

# Prints why the Rust core needs rebuilding for $PROFILE: "missing", the
# profile change, or the first input newer than the last build. Prints
# nothing when the build is current.
stale_reason() {
  if [[ ! -f "$STAMP" || ! -d "$PKG/$FFI_MODULE.xcframework" \
        || ! -f "$PKG/Sources/MiMundoCore/mimundo_core.swift" ]]; then
    echo "missing"
    return
  fi
  local built_profile
  built_profile="$(cat "$STAMP")"
  if [[ "$built_profile" != "$PROFILE" ]]; then
    echo "built as $built_profile, need $PROFILE"
    return
  fi
  # -quit stops at the first match, so no pipe (a pipe into head can kill
  # find with SIGPIPE, which pipefail + set -e would turn into a silent exit).
  # A missing input makes find exit 1; that's not "stale", so ignore it.
  find "$CORE/src" "$CORE/Cargo.toml" "$CORE/Cargo.lock" \
       "$CORE/rust-toolchain.toml" "$ROOT/scripts/build-core.sh" \
       -newer "$STAMP" -print -quit 2>/dev/null || true
}

if [[ "$MODE" == check ]]; then
  stale="$(stale_reason)"
  if [[ -n "$stale" ]]; then
    echo "error: The Rust core is out of date (${stale#"$ROOT/"}). Build once with Cmd-B to rebuild it (SwiftUI Previews don't run that step), or run scripts/build-core.sh." >&2
    if [[ -f "$LOG" && ( ! -f "$STAMP" || "$LOG" -nt "$STAMP" ) ]]; then
      echo "error: The last automatic Rust build failed. End of $LOG:" >&2
      tail -n 15 "$LOG" >&2
    fi
    exit 1
  fi
  exit 0
fi

if [[ "$MODE" == if-stale ]]; then
  stale="$(stale_reason)"
  if [[ -z "$stale" ]]; then
    echo "==> Rust core is up to date ($PROFILE)"
    exit 0
  fi
  echo "==> Rust core needs rebuilding (${stale#"$ROOT/"})"
fi

# Xcode runs scheme pre-actions with a minimal PATH, so make Homebrew
# findable. Append rather than prepend so a Homebrew `cargo` (which ignores
# rust-toolchain.toml) never wins over rustup's. Homebrew's rustup is
# keg-only, so its proxies go first.
export PATH="$HOME/.cargo/bin:$PATH:/opt/homebrew/bin:/usr/local/bin"
if command -v brew >/dev/null && RUSTUP_PREFIX="$(brew --prefix rustup 2>/dev/null)"; then
  export PATH="$RUSTUP_PREFIX/bin:$PATH"
fi

# The stamp records the build's *start* time, so edits saved while a build
# runs are still newer than it. Remove it now so a build that fails halfway
# can never look current.
BUILD_STARTED="$(mktemp -t mimundo-core-build)"
trap 'rm -f "$BUILD_STARTED"' EXIT
rm -f "$STAMP"

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
touch -r "$BUILD_STARTED" "$STAMP"

if [[ "$REGENERATE_PROJECT" == 1 ]]; then
  echo "==> Generating Xcode project"
  (cd "$APP" && xcodegen generate --quiet)
fi

echo "==> Done ($PROFILE). Open apple/MiMundo/MiMundo.xcodeproj"
