#!/usr/bin/env -S python3 -I
"""Writes Countries.json: facts for every country on the map.

Usage: build-countries.py <ne_50m_admin_0_countries.geojson> <wikidata-facts.json>
                          <wikidata-landmarks.json> <wikidata-capitals.json>
                          <facts-overrides.json> <out Countries.json>

Starts from the committed Wikidata snapshots (facts, and UNESCO landmarks:
the top 3 by fame unless hand-picked), applies the hand fixes in
facts-overrides.json (offline), and keeps only what the country card shows.
Output is keyed by ISO 3166-1 alpha-2 (matches CountryMeta.iso2):
  { "FR": { "capitals": ["Paris"], "population": 68605616,
            "languages": ["French"], "wikidata": "Q142",
            "landmarks": [{"name": "Eiffel Tower", "lon": 2.29, "lat": 48.86}],
            "capitalPoints": [{"name": "Paris", "lon": 2.35, "lat": 48.86}] }, ... }
Capitals, languages and landmarks are capped at 3. capitalPoints has one
entry per capital, in the same order; every capital must have one and it
must lie in (or within CAPITAL_SLACK of) the country's outline.
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
    r"genocide|memorial|concentration|auschwitz|birkenau|massacre|prison|slave|cemetery|skogskyrkog"
    r"|bikini|nuclear",
    re.IGNORECASE)
# Sites that span many countries but mean nothing to a kid (survey markers).
OBSCURE = re.compile(r"Struve Geodetic Arc", re.IGNORECASE)
# Long official UNESCO names ("Ancient and Primeval Beech Forests of the
# Carpathians and Other Regions…") don't fit a map label or a kid's memory.
MAX_AUTO_NAME = 34
OVERRIDABLE = FIELDS + ("landmarks", "capitalPoints")
# How far (degrees) a capital may sit outside the 1:50m outline: coastal
# capitals on small islands can fall just off the simplified coastline.
CAPITAL_SLACK = 0.15
# The 1:50m outlines leave out the capital's own island here (Pitcairn
# Island; Grand Turk), so the star sits, correctly, just off the drawn land.
CAPITAL_ISLAND_MISSING = {"PN", "TC"}


def rings_of(geometry):
    polys = [geometry["coordinates"]] if geometry["type"] == "Polygon" else geometry["coordinates"]
    return [ring for poly in polys for ring in poly]


def inside(rings, lon, lat):
    """Even-odd point-in-polygon over every ring (holes included)."""
    hit = False
    for ring in rings:
        for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
            if (y1 > lat) != (y2 > lat) and lon < x1 + (lat - y1) * (x2 - x1) / (y2 - y1):
                hit = not hit
    return hit


def distance(rings, lon, lat):
    """Shortest distance (degrees, flat) from a point to any ring edge."""
    best = float("inf")
    for ring in rings:
        for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
            dx, dy = x2 - x1, y2 - y1
            t = 0.0 if dx == dy == 0 else max(0.0, min(1.0, ((lon - x1) * dx + (lat - y1) * dy) / (dx * dx + dy * dy)))
            best = min(best, ((lon - x1 - t * dx) ** 2 + (lat - y1 - t * dy) ** 2) ** 0.5)
    return best


def is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def check_landmarks(iso2, landmarks):
    for lm in landmarks:
        ok = (isinstance(lm, dict) and isinstance(lm.get("name"), str) and lm["name"].strip()
              and is_number(lm.get("lon")) and is_number(lm.get("lat"))
              and -180 <= lm["lon"] <= 180 and -90 <= lm["lat"] <= 90)
        if not ok:
            sys.exit(f"error: bad landmark for {iso2}: {lm!r}")


def auto_landmarks(sites, capitals, iso2, outlines):
    """Up to 3 UNESCO picks, most famous first, without: heavy or obscure
    topics, names too long for a label, the capital itself (Vatican City,
    Valletta), sites that lie in another country (cross-border or
    mis-tagged; a point at sea is fine, as small islands are missing from
    the 1:50m outlines), and repeats of the same site under another name."""
    rings = outlines[iso2]

    def elsewhere(lon, lat):
        if inside(rings, lon, lat) or distance(rings, lon, lat) <= CAPITAL_SLACK:
            return False
        return any(inside(other, lon, lat) for code, other in outlines.items() if code != iso2)

    picks, seen_names, seen_points = [], set(), set()
    for s in sorted(sites, key=lambda s: (-s["sitelinks"], s["name"], s["wikidata"])):
        name = s["name"][:1].upper() + s["name"][1:]  # "historical city centre of Odesa"
        point = (round(s["lon"], 2), round(s["lat"], 2))
        if (HEAVY_TOPICS.search(name) or OBSCURE.search(name) or len(name) > MAX_AUTO_NAME
                or name in capitals or name.casefold() in seen_names or point in seen_points
                or elsewhere(s["lon"], s["lat"])):
            continue
        # "John Crow Mountains" vs "Blue and John Crow Mountains".
        if any(name.casefold() in other or other in name.casefold() for other in seen_names):
            continue
        seen_names.add(name.casefold())
        seen_points.add(point)
        picks.append({"name": name, "lon": s["lon"], "lat": s["lat"]})
    return picks[:3]


def main():
    ne_path, facts_path, landmarks_path, capitals_path, overrides_path, out_path = sys.argv[1:7]
    features = json.load(open(ne_path))["features"]
    facts = json.load(open(facts_path))["countries"]
    unesco = json.load(open(landmarks_path))["countries"]
    capital_points = json.load(open(capitals_path))["countries"]
    outlines = {}
    for f in features:
        outlines.setdefault(f["properties"]["ISO_A2_EH"], []).extend(rings_of(f["geometry"]))
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
        check_landmarks(iso2, fix.get("capitalPoints", []))

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
        if "landmarks" not in overrides.get(iso2, {}):
            entry["landmarks"] = auto_landmarks(unesco.get(iso2, []), entry["capitals"], iso2, outlines)
        entry["capitals"] = entry["capitals"][:3]
        entry["languages"] = entry["languages"][:3]
        entry["landmarks"] = entry["landmarks"][:3]
        known = {c["name"]: c for c in capital_points.get(iso2, []) + entry.pop("capitalPoints", [])}
        entry["capitalPoints"] = []
        for name in entry["capitals"]:
            point = known.get(name)
            if point is None:
                sys.exit(f"error: no location for {iso2} capital {name!r} "
                         "(add it to the override's capitalPoints)")
            rings = outlines[iso2]
            if iso2 not in CAPITAL_ISLAND_MISSING and not inside(rings, point["lon"], point["lat"]) and \
                    distance(rings, point["lon"], point["lat"]) > CAPITAL_SLACK:
                sys.exit(f"error: {iso2} capital {name} at {point['lon']}, {point['lat']} "
                         "is outside the country")
            entry["capitalPoints"].append({"name": name, "lon": point["lon"], "lat": point["lat"]})
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
