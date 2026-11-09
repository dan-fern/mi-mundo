#!/usr/bin/env -S python3 -I
"""Fetches where each country's capital is, from Wikidata (CC0), into
tools/wikidata-capitals.json, so the map can star the capital of the
selected country.

For every country in tools/wikidata-facts.json: its capitals (P36, best
rank) with their coordinates (P625) and English label. Capitals set by hand
in facts-overrides.json that aren't Wikidata's get coordinates from the
override's `capitalPoints` instead.

The snapshot is committed so builds are reproducible.

Usage: python3 -I tools/fetch-capitals.py <repo root>
"""

import datetime
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ENDPOINT = "https://query.wikidata.org/sparql"
USER_AGENT = "MiMundo-data-tools/0.1 (https://github.com/dan-fern/mi-mundo)"

QUERY = """
SELECT ?country ?capital ?label ?coord WHERE {
  VALUES ?country { %s }
  ?country wdt:P36 ?capital .
  ?capital wdt:P625 ?coord .
  OPTIONAL { ?capital rdfs:label ?label . FILTER(LANG(?label) = "en") }
}
"""

POINT = re.compile(r"Point\(([-0-9.eE]+) ([-0-9.eE]+)\)")


def sparql(query, attempts=5):
    """Runs a query, retrying the query service's frequent 429/5xx answers
    with backoff (honouring Retry-After)."""
    body = urllib.parse.urlencode({"query": query, "format": "json"}).encode()
    for attempt in range(1, attempts + 1):
        request = urllib.request.Request(ENDPOINT, data=body, headers={
            "User-Agent": USER_AGENT, "Content-Type": "application/x-www-form-urlencoded"})
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                return json.load(response)["results"]["bindings"]
        except urllib.error.HTTPError as e:
            if attempt == attempts or (e.code != 429 and e.code < 500):
                raise
            wait = int(e.headers.get("Retry-After") or 0) or 10 * attempt
        except (urllib.error.URLError, TimeoutError):
            if attempt == attempts:
                raise
            wait = 10 * attempt
        print(f"  query failed (attempt {attempt}), retrying in {wait} s", file=sys.stderr)
        time.sleep(wait)


def main():
    root = Path(sys.argv[1])
    facts = json.loads((root / "tools" / "wikidata-facts.json").read_text())["countries"]
    iso_of = {fact["wikidata"]: iso2 for iso2, fact in facts.items()}

    points = {}  # (iso2, name) -> set of (lon, lat)
    qids = sorted(iso_of)
    for start in range(0, len(qids), 100):
        batch = " ".join(f"wd:{q}" for q in qids[start:start + 100])
        for row in sparql(QUERY % batch):
            iso2 = iso_of[row["country"]["value"].rsplit("/", 1)[-1]]
            name = row.get("label", {}).get("value")
            match = POINT.match(row["coord"]["value"])
            if name and match:
                points.setdefault((iso2, name), set()).add(
                    (round(float(match[1]), 4), round(float(match[2]), 4)))

    by_country = {}
    for (iso2, name), pts in sorted(points.items()):
        # A few cities carry several coordinates; take one deterministically
        # (build-countries.py checks it lands inside the country).
        lon, lat = sorted(pts)[0]
        by_country.setdefault(iso2, []).append({"name": name, "lon": lon, "lat": lat})

    snapshot = {
        "_meta": {
            "fetched": datetime.date.today().isoformat(),
            "source": "Wikidata (CC0): capitals (P36) with coordinates (P625); see QUERY in tools/fetch-capitals.py",
        },
        "countries": by_country,
    }
    out = root / "tools" / "wikidata-capitals.json"
    out.write_text(json.dumps(snapshot, ensure_ascii=False, indent=1, sort_keys=True) + "\n")
    print(f"==> {sum(map(len, by_country.values()))} capitals in {len(by_country)} countries -> {out.relative_to(root)}")


if __name__ == "__main__":
    main()
