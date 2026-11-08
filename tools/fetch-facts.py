#!/usr/bin/env python3 -I
"""Fetches country facts from Wikidata (CC0) into data/raw/wikidata/facts.json.

For every item with an ISO 3166-1 alpha-2 code (P297): English name, capital(s)
(P36), latest population (P1082 with its P585 date), and official languages
(P37). tools/build-data.sh then joins this with the Natural Earth countries.

Usage: python3 -I tools/fetch-facts.py <repo root>
"""

import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

ENDPOINT = "https://query.wikidata.org/sparql"
USER_AGENT = "MiMundo-data-tools/0.1 (https://github.com/dan-fern/mi-mundo)"

QUERY = """
SELECT ?iso2 ?country ?countryLabel ?capitalLabel ?pop ?popDate ?langLabel ?speakers WHERE {
  ?country wdt:P297 ?iso2 .
  FILTER NOT EXISTS { ?country wdt:P576 ?dissolved . }
  OPTIONAL { ?country wdt:P36 ?capital . }
  OPTIONAL {
    ?country p:P1082 ?popStatement .
    ?popStatement ps:P1082 ?pop .
    OPTIONAL { ?popStatement pq:P585 ?popDate . }
  }
  OPTIONAL {
    ?country wdt:P37 ?lang .
    FILTER NOT EXISTS { ?lang wdt:P31/wdt:P279* wd:Q34228 . }  # sign languages
    OPTIONAL { ?lang wdt:P1098 ?speakers . }
  }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
}
"""


def run_query():
    url = ENDPOINT + "?" + urllib.parse.urlencode({"query": QUERY, "format": "json"})
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response)["results"]["bindings"]


def value(row, key):
    return row[key]["value"] if key in row else None


def main():
    root = Path(sys.argv[1])
    rows = run_query()
    facts = {}
    for row in rows:
        iso2 = value(row, "iso2").upper()
        entry = facts.setdefault(iso2, {
            "wikidata": value(row, "country").rsplit("/", 1)[-1],
            "name": value(row, "countryLabel"),
            "capitals": [],
            "languages": [],
            "population": None,
            "populationDate": None,
        })
        capital = value(row, "capitalLabel")
        if capital and capital not in entry["capitals"]:
            entry["capitals"].append(capital)
        language = value(row, "langLabel")
        if language:
            speakers = int(float(value(row, "speakers") or 0))
            ranked = entry.setdefault("_speakers", {})
            ranked[language] = max(ranked.get(language, 0), speakers)
        pop, pop_date = value(row, "pop"), value(row, "popDate") or ""
        if pop is not None:
            # Keep the most recent figure (undated ones lose to dated ones).
            if entry["population"] is None or pop_date > (entry["populationDate"] or ""):
                entry["population"] = int(float(pop))
                entry["populationDate"] = pop_date or None

    # Most-spoken languages first (worldwide speakers), then apply hand
    # overrides for countries where Wikidata's "official languages" list
    # misleads a kid (tools/facts-overrides.json, keyed by ISO alpha-2).
    overrides = json.loads((root / "tools" / "facts-overrides.json").read_text())
    for iso2, entry in facts.items():
        ranked = entry.pop("_speakers", {})
        entry["languages"] = sorted(ranked, key=lambda name: (-ranked[name], name))
        for key, replacement in overrides.get(iso2, {}).items():
            if not key.startswith("_"):
                entry[key] = replacement

    out = root / "data" / "raw" / "wikidata" / "facts.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(facts, ensure_ascii=False, indent=1, sort_keys=True))
    print(f"==> {len(facts)} countries -> {out.relative_to(root)}")


if __name__ == "__main__":
    main()
