#!/usr/bin/env -S python3 -I
"""Fetches landmark candidates from Wikidata (CC0) into tools/wikidata-landmarks.json.

Candidates are UNESCO World Heritage Sites (P1435 = Q9259), per country
(P17, so cross-border sites count for each country), ranked by how many
Wikipedia language editions cover them (sitelinks) as a rough "how famous"
signal. Up to 8 per country are kept; build-countries.py takes the top 3,
and tools/facts-overrides.json can replace them with a hand-picked list.

The snapshot is committed so builds are reproducible.

Usage: python3 -I tools/fetch-landmarks.py <repo root>
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
KEEP_PER_COUNTRY = 8

# Step 1: sites with country, coordinates and fame. Step 2: English labels
# for just those items, in batches (one big join with labels times out).
QUERY = """
SELECT ?site ?country ?coord ?links WHERE {
  ?site wdt:P1435 wd:Q9259 ;
        wdt:P17 ?country ;
        wikibase:sitelinks ?links .
  OPTIONAL { ?site wdt:P625 ?coord . }
}
"""

LABEL_QUERY = """
SELECT ?site ?label WHERE {
  VALUES ?site { %s }
  ?site rdfs:label ?label . FILTER(LANG(?label) = "en")
}
"""

POINT = re.compile(r"Point\(([-0-9.eE]+) ([-0-9.eE]+)\)")
BARE_ID = re.compile(r"^Q\d+$")


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
    # Country item -> ISO alpha-2, from the committed facts snapshot (joining
    # on P297 in the query makes it time out).
    facts = json.loads((root / "tools" / "wikidata-facts.json").read_text())["countries"]
    iso_of = {fact["wikidata"]: iso2 for iso2, fact in facts.items()}

    rows = [row for row in sparql(QUERY)
            if row["country"]["value"].rsplit("/", 1)[-1] in iso_of]
    qids = sorted({row["site"]["value"].rsplit("/", 1)[-1] for row in rows})
    labels = {}
    for start in range(0, len(qids), 300):
        batch = " ".join(f"wd:{q}" for q in qids[start:start + 300])
        for row in sparql(LABEL_QUERY % batch):
            labels[row["site"]["value"].rsplit("/", 1)[-1]] = row["label"]["value"]

    sites = {}  # (iso2, qid) -> site
    for row in rows:
        iso2 = iso_of[row["country"]["value"].rsplit("/", 1)[-1]]
        qid = row["site"]["value"].rsplit("/", 1)[-1]
        name = labels.get(qid)
        if not name or BARE_ID.match(name):
            continue  # no English label
        site = sites.setdefault((iso2, qid), {
            "wikidata": qid, "name": name, "sitelinks": int(row["links"]["value"]), "points": set(),
        })
        match = POINT.match(row.get("coord", {}).get("value", ""))
        if match:
            site["points"].add((round(float(match[1]), 4), round(float(match[2]), 4)))

    by_country = {}
    for (iso2, _), site in sites.items():
        if not site["points"]:
            continue  # can't pin it on the map
        # Serial sites have many coordinates; use the first, deterministically.
        lon, lat = sorted(site.pop("points"))[0]
        by_country.setdefault(iso2, []).append({**site, "lon": lon, "lat": lat})
    for iso2 in by_country:
        by_country[iso2].sort(key=lambda s: (-s["sitelinks"], s["name"], s["wikidata"]))
        by_country[iso2] = by_country[iso2][:KEEP_PER_COUNTRY]

    snapshot = {
        "_meta": {
            "fetched": datetime.date.today().isoformat(),
            "source": "Wikidata (CC0): UNESCO World Heritage Sites by sitelinks; see QUERY in tools/fetch-landmarks.py",
        },
        "countries": by_country,
    }
    out = root / "tools" / "wikidata-landmarks.json"
    out.write_text(json.dumps(snapshot, ensure_ascii=False, indent=1, sort_keys=True) + "\n")
    print(f"==> {sum(map(len, by_country.values()))} landmarks in {len(by_country)} countries -> {out.relative_to(root)}")


if __name__ == "__main__":
    main()
