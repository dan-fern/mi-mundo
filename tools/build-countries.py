#!/usr/bin/env -S python3 -I
"""Writes Countries.json: facts for every country on the map.

Usage: build-countries.py <ne_50m_admin_0_countries.geojson> <wikidata-facts.json>
                          <wikidata-landmarks.json> <facts-overrides.json> <out Countries.json>

Starts from the committed Wikidata snapshots (facts, and UNESCO landmarks:
the top 3 by fame unless hand-picked), applies the hand fixes in
facts-overrides.json (offline), and keeps only what the country card shows.
Output is keyed by ISO 3166-1 alpha-2 (matches CountryMeta.iso2):
  { "FR": { "capitals": ["Paris"], "population": 68605616,
            "languages": ["French"], "wikidata": "Q142",
            "landmarks": [{"name": "Eiffel Tower", "lon": 2.29, "lat": 48.86}] }, ... }
Capitals, languages and landmarks are capped at 3.
"""

import json
import re
import sys

FIELDS = ("capitals", "population", "languages")
# Automatic (UNESCO) landmark picks are skipped when they're about atrocities
# or burial grounds: important places, but not what a young child's map card
# should lead with. The next most famous site is used instead; hand-picked
# lists in facts-overrides.json are never filtered.
HEAVY_TOPICS = re.compile(
    r"genocide|memorial|concentration|auschwitz|birkenau|massacre|prison|slave|cemetery|skogskyrkog",
    re.IGNORECASE)
# Sites that span many countries but mean nothing to a kid (survey markers).
OBSCURE = re.compile(r"Struve Geodetic Arc", re.IGNORECASE)
# Long official UNESCO names ("Ancient and Primeval Beech Forests of the
# Carpathians and Other Regions…") don't fit a map label or a kid's memory.
MAX_AUTO_NAME = 34
OVERRIDABLE = FIELDS + ("landmarks",)


def check_landmarks(iso2, landmarks):
    for lm in landmarks:
        ok = (isinstance(lm, dict) and isinstance(lm.get("name"), str) and lm["name"].strip()
              and -180 <= lm.get("lon", 999) <= 180 and -90 <= lm.get("lat", 999) <= 90)
        if not ok:
            sys.exit(f"error: bad landmark for {iso2}: {lm!r}")


def main():
    ne_path, facts_path, landmarks_path, overrides_path, out_path = sys.argv[1:6]
    features = json.load(open(ne_path))["features"]
    facts = json.load(open(facts_path))["countries"]
    unesco = json.load(open(landmarks_path))["countries"]
    overrides = {k: v for k, v in json.load(open(overrides_path)).items() if not k.startswith("_")}

    on_map = {f["properties"]["ISO_A2_EH"] for f in features} - {"-99"}
    unknown = sorted(set(overrides) - on_map)
    if unknown:
        sys.exit(f"error: overrides for countries not on the map: {unknown}")
    for iso2, fix in overrides.items():
        bad = sorted(k for k in fix if not k.startswith("_") and k not in OVERRIDABLE)
        if bad:
            sys.exit(f"error: override {iso2} has unknown fields {bad}")
        check_landmarks(iso2, fix.get("landmarks", []))

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
        entry["landmarks"] = [{"name": s["name"], "lon": s["lon"], "lat": s["lat"]}
                              for s in unesco.get(iso2, [])
                              if not HEAVY_TOPICS.search(s["name"]) and not OBSCURE.search(s["name"])
                              and len(s["name"]) <= MAX_AUTO_NAME]
        entry.update({k: v for k, v in overrides.get(iso2, {}).items() if not k.startswith("_")})
        entry["capitals"] = entry["capitals"][:3]
        entry["languages"] = entry["languages"][:3]
        entry["landmarks"] = entry["landmarks"][:3]
        out[iso2] = entry

    with open(out_path, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")
    multi = sum(1 for e in out.values() if len(e["languages"]) > 1)
    with_landmarks = sum(1 for e in out.values() if e["landmarks"])
    print(f"  {with_landmarks} countries with landmarks "
          f"({sum(1 for f in overrides.values() if 'landmarks' in f)} hand-picked)")
    print(f"  {len(out)} countries with facts ({len(overrides)} with hand fixes, "
          f"{multi} with several languages — review those on each refresh)"
          + (f"; no facts for {missing}" if missing else ""))
    if stale:
        print(f"  population older than {stale_before} (consider an override): {', '.join(stale)}")


if __name__ == "__main__":
    main()
