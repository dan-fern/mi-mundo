#!/usr/bin/env -S python3 -I
"""Writes Countries.json: facts for every country on the map.

Usage: build-countries.py <ne_50m_admin_0_countries.geojson> <wikidata-facts.json>
                          <facts-overrides.json> <out Countries.json>

Starts from the committed Wikidata snapshot, applies the hand fixes in
facts-overrides.json (offline), and keeps only what the country card shows.
Output is keyed by ISO 3166-1 alpha-2 (matches CountryMeta.iso2):
  { "FR": { "capitals": ["Paris"], "population": 68605616,
            "languages": ["French"], "wikidata": "Q142" }, ... }
Capitals and languages are capped at 3.
"""

import json
import sys

FIELDS = ("capitals", "population", "languages")


def main():
    ne_path, facts_path, overrides_path, out_path = sys.argv[1:5]
    features = json.load(open(ne_path))["features"]
    facts = json.load(open(facts_path))["countries"]
    overrides = {k: v for k, v in json.load(open(overrides_path)).items() if not k.startswith("_")}

    on_map = {f["properties"]["ISO_A2_EH"] for f in features} - {"-99"}
    unknown = sorted(set(overrides) - on_map)
    if unknown:
        sys.exit(f"error: overrides for countries not on the map: {unknown}")
    for iso2, fix in overrides.items():
        bad = sorted(k for k in fix if not k.startswith("_") and k not in FIELDS)
        if bad:
            sys.exit(f"error: override {iso2} has unknown fields {bad}")

    # Population figures older than this (and not hand-fixed) are listed so
    # each refresh gets a look; Wikidata lags for some countries.
    stale_before = "2020"
    stale = sorted(
        iso2 for iso2 in on_map
        if iso2 in facts and "population" not in overrides.get(iso2, {})
        and facts[iso2]["population"] is not None
        and (facts[iso2].get("populationDate") or "0000") < stale_before
    )

    out, missing = {}, []
    for iso2 in sorted(on_map):
        fact = facts.get(iso2)
        if fact is None:
            missing.append(iso2)
            continue
        entry = {"wikidata": fact["wikidata"], **{k: fact[k] for k in FIELDS}}
        entry.update({k: v for k, v in overrides.get(iso2, {}).items() if not k.startswith("_")})
        entry["capitals"] = entry["capitals"][:3]
        entry["languages"] = entry["languages"][:3]
        out[iso2] = entry

    with open(out_path, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")
    multi = sum(1 for e in out.values() if len(e["languages"]) > 1)
    print(f"  {len(out)} countries with facts ({len(overrides)} with hand fixes, "
          f"{multi} with several languages — review those on each refresh)"
          + (f"; no facts for {missing}" if missing else ""))
    if stale:
        print(f"  population older than {stale_before} (consider an override): {', '.join(stale)}")


if __name__ == "__main__":
    main()
