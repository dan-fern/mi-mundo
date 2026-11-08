#!/usr/bin/env bash
# Downloads the raw map/flag sources into data/raw/ (gitignored). The app
# never reads these directly: tools/build-data.sh turns them into the small
# bundled files under apple/MiMundo/Resources/ (which ARE committed).
#
# Sources (all free to use):
#   Natural Earth admin-0 countries, 1:110m and 1:50m — public domain
#     https://www.naturalearthdata.com  (GeoJSON mirror: nvkelso/natural-earth-vector)
#   flag-icons SVG flags — MIT  https://github.com/lipis/flag-icons
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW="$ROOT/data/raw"
NE_BASE="https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson"
FLAG_ICONS_VERSION="7.2.3"

mkdir -p "$RAW/naturalearth" "$RAW/flag-icons"

for layer in ne_110m_admin_0_countries ne_50m_admin_0_countries; do
  echo "==> $layer"
  curl -fsSL "$NE_BASE/$layer.geojson" -o "$RAW/naturalearth/$layer.geojson"
done

echo "==> flag-icons $FLAG_ICONS_VERSION"
curl -fsSL "https://registry.npmjs.org/flag-icons/-/flag-icons-$FLAG_ICONS_VERSION.tgz" \
  -o "$RAW/flag-icons/flag-icons.tgz"
rm -rf "$RAW/flag-icons/package"
tar -xzf "$RAW/flag-icons/flag-icons.tgz" -C "$RAW/flag-icons" package/flags/4x3 package/LICENSE

echo "==> Done. Raw data in data/raw/"
ls -la "$RAW/naturalearth" "$RAW/flag-icons/package/flags/4x3" | head -8
