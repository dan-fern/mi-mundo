#!/usr/bin/env -S python3 -I
"""Fetches country facts from Wikidata (CC0) into tools/wikidata-facts.json.

The snapshot is committed, so builds are reproducible and fact changes show
up as their own reviewable diff. Hand fixes are NOT applied here: they live
in tools/facts-overrides.json and are applied by build-countries.py, so
content fixes never need the network.

For every item with an ISO 3166-1 alpha-2 code (P297): English name,
capital(s) (P36), population (P1082, best-ranked statement, most recent by
date), and official languages (P37, sign languages dropped), ranked by
worldwide speakers (P1098) as a starting point for the overrides.

Usage: python3 -I tools/fetch-facts.py <repo root>
"""

import datetime
import json
import re
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
    # Best rank only (preferred, else normal): never deprecated figures.
    ?country p:P1082 ?popStatement .
    ?popStatement ps:P1082 ?pop ; a wikibase:BestRank .
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

# A label that's just an item id means Wikidata had no English label; fail
# loudly instead of showing "Q36262" to a kid.
BARE_ID = re.compile(r"^Q\d+$")


def run_query():
    url = ENDPOINT + "?" + urllib.parse.urlencode({"query": QUERY, "format": "json"})
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response)["results"]["bindings"]


def value(row, key):
    return row[key]["value"] if key in row else None


def main():
    root = Path(sys.argv[1])
    facts, bare_ids = {}, set()
    for row in run_query():
        iso2 = value(row, "iso2").upper()
        entry = facts.setdefault(iso2, {
            "wikidata": value(row, "country").rsplit("/", 1)[-1],
            "name": value(row, "countryLabel"),
            "capitals": set(),
            "_speakers": {},
            "_populations": set(),
        })
        capital = value(row, "capitalLabel")
        if capital:
            (bare_ids.add(f"{iso2} capital {capital}") if BARE_ID.match(capital)
             else entry["capitals"].add(capital))
        language = value(row, "langLabel")
        if language:
            if BARE_ID.match(language):
                bare_ids.add(f"{iso2} language {language}")
            else:
                speakers = int(float(value(row, "speakers") or 0))
                entry["_speakers"][language] = max(entry["_speakers"].get(language, 0), speakers)
        if value(row, "pop") is not None:
            entry["_populations"].add((value(row, "popDate") or "", int(float(value(row, "pop")))))

    for entry in facts.values():
        # Deterministic: capitals alphabetical (overrides set a preferred
        # order), languages by speakers then name, population = most recent
        # dated figure, ties broken by the larger value.
        entry["capitals"] = sorted(entry["capitals"])
        ranked = entry.pop("_speakers")
        entry["languages"] = sorted(ranked, key=lambda name: (-ranked[name], name))
        populations = sorted(entry.pop("_populations"))
        entry["population"], entry["populationDate"] = (
            (populations[-1][1], populations[-1][0] or None) if populations else (None, None)
        )

    if bare_ids:
        print("Labels missing in English (add overrides):", *sorted(bare_ids), sep="\n  ")

    snapshot = {
        "_meta": {
            "fetched": datetime.date.today().isoformat(),
            "source": "Wikidata (CC0) via query.wikidata.org; see QUERY in tools/fetch-facts.py",
        },
        "countries": facts,
    }
    out = root / "tools" / "wikidata-facts.json"
    out.write_text(json.dumps(snapshot, ensure_ascii=False, indent=1, sort_keys=True) + "\n")
    print(f"==> {len(facts)} countries -> {out.relative_to(root)}")


if __name__ == "__main__":
    main()
