#!/usr/bin/env python3 -I
"""Writes Countries.json: Wikidata facts for every country on the map.

Usage: build-countries.py <ne_50m_admin_0_countries.geojson> <facts.json> <out Countries.json>

Output is keyed by ISO 3166-1 alpha-2 (matches CountryMeta.iso2 from the
Rust map) and holds only what the country card shows:
  { "FR": { "capitals": ["Paris"], "population": 68605616,
            "languages": ["French"], "wikidata": "Q142" }, ... }
Languages are capped at 3, capitals at 3.
"""

import json
import sys


def main():
    ne_path, facts_path, out_path = sys.argv[1:4]
    features = json.load(open(ne_path))["features"]
    facts = json.load(open(facts_path))

    out, missing = {}, []
    for feature in features:
        iso2 = feature["properties"]["ISO_A2_EH"]
        if iso2 == "-99":
            continue
        fact = facts.get(iso2)
        if fact is None:
            missing.append(iso2)
            continue
        out[iso2] = {
            "wikidata": fact["wikidata"],
            "capitals": fact["capitals"][:3],
            "population": fact["population"],
            "languages": fact["languages"][:3],
        }

    with open(out_path, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")
    print(f"  {len(out)} countries with facts" + (f"; no facts for {missing}" if missing else ""))


if __name__ == "__main__":
    main()
