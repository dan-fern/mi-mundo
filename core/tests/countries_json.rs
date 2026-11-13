//! Checks the bundled country facts (apple/MiMundo/Resources/Countries.json)
//! against the map and the content rules in docs/REQUIREMENTS.md §4.

use std::collections::{BTreeSet, HashMap};
use std::sync::OnceLock;

use mimundo_core::map::{World, equal_earth};
use serde_json::Value;

const RESOURCES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../apple/MiMundo/Resources");

fn facts() -> &'static serde_json::Map<String, Value> {
    static FACTS: OnceLock<serde_json::Map<String, Value>> = OnceLock::new();
    FACTS.get_or_init(|| {
        let text = std::fs::read_to_string(format!("{RESOURCES}/Countries.json")).unwrap();
        serde_json::from_str::<Value>(&text)
            .unwrap()
            .as_object()
            .unwrap()
            .clone()
    })
}

fn world() -> &'static World {
    static WORLD: OnceLock<std::sync::Arc<World>> = OnceLock::new();
    WORLD.get_or_init(|| {
        World::new(std::fs::read(format!("{RESOURCES}/World.bin")).unwrap()).unwrap()
    })
}

/// ISO code of the country at a lon/lat, with tolerance in map units.
fn iso_at(lon: f64, lat: f64, tolerance: f32) -> Option<String> {
    let (x, y) = equal_earth(lon, lat);
    let countries = world().countries();
    world()
        .country_at(x as f32, y as f32, tolerance)
        .map(|i| countries[i as usize].iso2.clone())
}

fn strings(v: &Value) -> Vec<&str> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|s| s.as_str().unwrap())
        .collect()
}

fn points(v: &Value) -> Vec<(&str, f64, f64)> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|p| {
            (
                p["name"].as_str().unwrap(),
                p["lon"].as_f64().unwrap(),
                p["lat"].as_f64().unwrap(),
            )
        })
        .collect()
}

#[test]
fn facts_and_map_cover_the_same_countries() {
    let on_map: BTreeSet<String> = world()
        .countries()
        .into_iter()
        .map(|c| c.iso2)
        .filter(|iso| iso != "-99")
        .collect();
    let with_facts: BTreeSet<String> = facts().keys().cloned().collect();
    assert_eq!(on_map, with_facts);
}

#[test]
fn every_capital_has_a_location_in_the_same_order() {
    for (iso, f) in facts() {
        let names: Vec<&str> = points(&f["capitalPoints"]).iter().map(|p| p.0).collect();
        assert_eq!(names, strings(&f["capitals"]), "{iso}");
    }
}

#[test]
fn capitals_sit_in_their_own_country() {
    // Pitcairn's and the Turks and Caicos' capitals are on islands the
    // 1:50m outlines leave out (tools/build-countries.py).
    for (iso, f) in facts()
        .iter()
        .filter(|(iso, _)| !["PN", "TC"].contains(&iso.as_str()))
    {
        for (name, lon, lat) in points(&f["capitalPoints"]) {
            // On land it must be this country; a coastal capital may fall
            // just offshore of the simplified coastline (build-countries.py
            // checks it's close), but never inside a neighbour.
            let at = iso_at(lon, lat, 0.0);
            assert!(
                at.is_none() || at.as_deref() == Some(iso.as_str()),
                "{iso} {name} is in {at:?}"
            );
        }
    }
}

#[test]
fn landmarks_are_not_inside_another_country() {
    // Sites that span a border (UNESCO transboundary sites, shared lakes
    // and falls): the point can land on the other side.
    let shared = [
        "Victoria Falls",
        "Iguazu Falls",
        "Mount Everest",
        "Lake Titicaca",
        "Dead Sea",
        "Białowieża Forest",
        "W-Arly-Pendjari Complex",
        "Koutammakou",
        "Sangha Trinational",
        "Mount Nimba Strict Nature Reserve",
        "Stone Circles of Senegambia",
        "Old City of Jerusalem",
        "Maloti-Drakensberg Park",
        "Landscapes of Dauria",
    ];
    let mut wrong = Vec::new();
    for (iso, f) in facts() {
        for (name, lon, lat) in points(&f["landmarks"]) {
            if let Some(other) = iso_at(lon, lat, 0.0) {
                if &other != iso && !shared.contains(&name) {
                    wrong.push(format!("{iso} {name} is in {other}"));
                }
            }
        }
    }
    assert!(wrong.is_empty(), "{wrong:#?}");
}

#[test]
fn lists_are_short_enough_for_the_card() {
    for (iso, f) in facts() {
        for key in ["capitals", "languages", "landmarks"] {
            assert!(f[key].as_array().unwrap().len() <= 3, "{iso} {key}");
        }
        let uninhabited = f["population"].is_null();
        assert!(
            uninhabited || !strings(&f["languages"]).is_empty(),
            "{iso} has no language"
        );
    }
}

#[test]
fn only_uninhabited_places_have_no_population() {
    let none: BTreeSet<&str> = facts()
        .iter()
        .filter(|(_, f)| f["population"].is_null())
        .map(|(iso, _)| iso.as_str())
        .collect();
    assert_eq!(none, BTreeSet::from(["AQ", "GS", "HM", "IO", "TF"]));
}

#[test]
fn populations_are_plausible() {
    for (iso, f) in facts() {
        if let Some(p) = f["population"].as_u64() {
            assert!((30..1_600_000_000).contains(&p), "{iso}: {p}");
        }
    }
    for iso in ["CN", "IN"] {
        assert!(
            facts()[iso]["population"].as_u64().unwrap() > 1_000_000_000,
            "{iso}"
        );
    }
}

#[test]
fn no_landmark_is_about_atrocities_or_burials() {
    let heavy = [
        "genocide",
        "memorial",
        "concentration",
        "auschwitz",
        "massacre",
        "prison",
        "slave",
        "cemetery",
        "nuclear",
        "bikini",
    ];
    for (iso, f) in facts() {
        for (name, _, _) in points(&f["landmarks"]) {
            let lower = name.to_lowercase();
            assert!(!heavy.iter().any(|w| lower.contains(w)), "{iso}: {name}");
        }
    }
}

#[test]
fn border_decisions_hold() {
    // docs/REQUIREMENTS.md §4.
    let caps = |iso: &str| strings(&facts()[iso]["capitals"]).join(", ");
    assert_eq!(caps("TW"), "Taipei");
    assert!(caps("IL").contains("Jerusalem"));
    assert!(caps("PS").contains("Jerusalem"));
    assert_eq!(caps("UA"), "Kyiv");
    assert!(caps("YE").starts_with("Sanaa"));
}

#[test]
fn landmarks_belong_to_one_country_unless_shared() {
    let mut owners: HashMap<&str, Vec<&str>> = HashMap::new();
    for (iso, f) in facts() {
        for (name, _, _) in points(&f["landmarks"]) {
            owners.entry(name).or_default().push(iso);
        }
    }
    let mut shared: Vec<String> = owners
        .iter()
        .filter(|(_, isos)| isos.len() > 1)
        .map(|(name, isos)| format!("{name}: {isos:?}"))
        .collect();
    shared.sort();
    // Today: 10 genuinely shared sites (Victoria Falls, Iguazu, Titicaca…).
    assert!(shared.len() <= 12, "many shared landmarks: {shared:#?}");
}

#[test]
fn text_is_clean() {
    let is_qid =
        |s: &str| s.starts_with('Q') && s[1..].chars().all(|c| c.is_ascii_digit()) && s.len() > 1;
    for (iso, f) in facts() {
        let mut all: Vec<&str> = strings(&f["capitals"]);
        all.extend(strings(&f["languages"]));
        all.extend(points(&f["landmarks"]).iter().map(|p| p.0));
        for s in all {
            assert!(
                !s.is_empty() && s.trim() == s && !s.contains("  "),
                "{iso}: {s:?}"
            );
            assert!(!is_qid(s), "{iso}: unresolved Wikidata id {s}");
        }
    }
}

#[test]
fn every_country_has_a_flag() {
    for iso in facts().keys() {
        let set = format!(
            "{RESOURCES}/Flags.xcassets/flag-{}.imageset",
            iso.to_lowercase()
        );
        assert!(std::path::Path::new(&set).is_dir(), "no flag for {iso}");
    }
}

#[test]
fn independent_countries_are_marked_for_quiz_presets() {
    let independent = |iso: &str| facts()[iso]["independent"].as_bool().unwrap();
    let count = facts().keys().filter(|iso| independent(iso)).count();
    assert!(
        (193..=200).contains(&count),
        "{count} independent countries"
    );
    for iso in ["FR", "US", "TW", "PS", "XK", "VA", "TV"] {
        assert!(independent(iso), "{iso}");
    }
    // Territories, and Antarctica (nobody lives there).
    for iso in ["GL", "PR", "HK", "BM", "AQ", "FK", "EH"] {
        assert!(!independent(iso), "{iso}");
    }
}

#[test]
fn quiz_regions_are_quiz_sized() {
    let mut sizes: HashMap<&str, usize> = HashMap::new();
    for (iso, f) in facts() {
        let region = f["region"]
            .as_str()
            .unwrap_or_else(|| panic!("{iso} has no region"));
        if f["independent"].as_bool().unwrap() {
            *sizes.entry(region).or_default() += 1;
        }
    }
    assert!(sizes.len() >= 20, "{sizes:?}");
    for (region, n) in &sizes {
        assert!(*n <= 14, "{region} has {n} countries");
    }
    let region = |iso: &str| facts()[iso]["region"].as_str().unwrap();
    assert_eq!(region("MX"), "North America");
    assert_eq!(region("HR"), "Balkans");
    assert_eq!(region("SA"), "Arabian Peninsula");
    assert_eq!(region("JM"), "Caribbean");
}
