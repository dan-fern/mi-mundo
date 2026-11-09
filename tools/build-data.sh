#!/usr/bin/env bash
# Builds the map data the app bundles, from the raw downloads in data/raw/
# (run tools/fetch-data.sh first) and the committed Wikidata snapshot
# tools/wikidata-facts.json (refresh it with tools/fetch-facts.py):
#
#   apple/MiMundo/Resources/World.bin        country outlines (Rust mapgen)
#   apple/MiMundo/Resources/Features.bin     rivers, lakes, deserts, ranges, peaks (Rust featuregen)
#   apple/MiMundo/Resources/Countries.json   capitals, population, languages
#   apple/MiMundo/Resources/Flags.xcassets   one PNG imageset per flag
#
# The outputs are committed, so a normal build never needs this script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW="$ROOT/data/raw"
OUT="$ROOT/apple/MiMundo/Resources"
FLAG_WIDTH=320  # 4:3 flags; the card shows them ~160 pt wide (@2x)

export PATH="$HOME/.cargo/bin:$PATH:/opt/homebrew/bin:/usr/local/bin"
if command -v brew >/dev/null && RUSTUP_PREFIX="$(brew --prefix rustup 2>/dev/null)"; then
  export PATH="$RUSTUP_PREFIX/bin:$PATH"
fi
command -v inkscape >/dev/null || { echo "error: inkscape not found (brew install --cask inkscape)" >&2; exit 1; }

echo "==> World.bin"
(cd "$ROOT/core" && cargo run -q --release --features mapgen --bin mapgen -- \
  "$RAW/naturalearth/ne_110m_admin_0_countries.geojson" \
  "$RAW/naturalearth/ne_50m_admin_0_countries.geojson" \
  "$OUT/World.bin")

echo "==> Features.bin"
(cd "$ROOT/core" && cargo run -q --release --features mapgen --bin featuregen -- \
  "$RAW/naturalearth/ne_50m_rivers_lake_centerlines.geojson" \
  "$RAW/naturalearth/ne_50m_lakes.geojson" \
  "$RAW/naturalearth/ne_50m_geography_regions_polys.geojson" \
  "$RAW/naturalearth/ne_50m_geography_regions_elevation_points.geojson" \
  "$OUT/Features.bin")

echo "==> Countries.json"
python3 -I "$ROOT/tools/build-countries.py" \
  "$RAW/naturalearth/ne_50m_admin_0_countries.geojson" \
  "$ROOT/tools/wikidata-facts.json" \
  "$ROOT/tools/wikidata-landmarks.json" \
  "$ROOT/tools/facts-overrides.json" \
  "$OUT/Countries.json"

echo "==> Flags.xcassets"
FLAGS="$OUT/Flags.xcassets"
rm -rf "$FLAGS"
mkdir -p "$FLAGS"
printf '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' > "$FLAGS/Contents.json"
count=0
for iso2 in $(python3 -I -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1])))))' "$OUT/Countries.json"); do
  code="$(echo "$iso2" | tr 'A-Z' 'a-z')"
  svg="$RAW/flag-icons/package/flags/4x3/$code.svg"
  [[ -f "$svg" ]] || { echo "  (no flag for $iso2)"; continue; }
  set_dir="$FLAGS/flag-$code.imageset"
  mkdir -p "$set_dir"
  log="$(mktemp -t inkscape)"
  if ! inkscape "$svg" -w "$FLAG_WIDTH" -h $((FLAG_WIDTH * 3 / 4)) --export-png-color-mode=RGB_8 \
      -o "$set_dir/flag-$code.png" 2>"$log" || [[ ! -s "$set_dir/flag-$code.png" ]]; then
    echo "error: rendering flag $iso2 failed:" >&2
    cat "$log" >&2
    exit 1
  fi
  rm -f "$log"
  printf '{\n  "images" : [ { "filename" : "flag-%s.png", "idiom" : "universal" } ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' \
    "$code" > "$set_dir/Contents.json"
  count=$((count + 1))
done
echo "  $count flags"

echo "==> Checking the map against known places (core/tests/world_bin.rs, features_bin.rs)"
(cd "$ROOT/core" && cargo test -q --test world_bin --test features_bin)

echo "==> Done. Sizes:"
du -sh "$OUT/World.bin" "$OUT/Features.bin" "$OUT/Countries.json" "$FLAGS"
