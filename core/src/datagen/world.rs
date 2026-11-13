//! Builds `World.bin` (see `map::world`) from Natural Earth GeoJSON.
//!
//! Usage: mapgen <ne_110m_admin_0_countries.geojson> <ne_50m_admin_0_countries.geojson> <out World.bin>
//!
//! - Fine outlines come from the 1:50m layer (242 countries/territories).
//! - Coarse outlines come from the 1:110m layer where the country exists
//!   there, else from the 1:50m outline simplified.
//! - Everything is projected to Equal Earth map coordinates here, once, so
//!   the app never projects at runtime.
//!
//! Run via tools/build-data.sh (needs `--features mapgen`).

use std::collections::HashMap;

use crate::map::geometry::simplify_ring;
use crate::map::world::encode;
use crate::map::{CountryData, equal_earth};
use serde_json::Value;

/// Tolerance (map units) when simplifying 1:50m outlines for the coarse
/// level, for countries missing from the 1:110m layer. ~0.002 ≈ 1 px on a
/// full-width iPad map.
const COARSE_TOLERANCE: f32 = 0.002;

/// Display names: the plain, common English name a kid will meet, where
/// Natural Earth's NAME_EN is formal or dated. Keyed by ADM0_A3.
const NAME_OVERRIDES: &[(&str, &str)] = &[
    ("CHN", "China"),
    ("CYN", "Northern Cyprus"),
    ("CIV", "Côte d'Ivoire"),
    ("TLS", "Timor-Leste"),
    ("MAC", "Macao"),
    ("CPV", "Cabo Verde"),
    ("USA", "United States"),
    ("FSM", "Micronesia"),
    ("CZE", "Czechia"),
    // "The Bahamas" / "The Gambia" sort under T, where kids won't look.
    ("BHS", "Bahamas"),
    ("GMB", "Gambia"),
    ("IOA", "Christmas and Cocos Islands"),
];

/// Features whose ISO_A2_EH points at a *different* country's facts (both
/// carry "AU"), so tapping them showed Australia's card. "-99" = name only.
const ISO_OVERRIDES: &[(&str, &str)] = &[("IOA", "-99"), ("ATC", "-99")];

/// Territory the family map assigns differently from Natural Earth's
/// default (de facto) layer: (from ADM0_A3, to ADM0_A3, a lon/lat inside the
/// territory, name). The territory must be a separate polygon of `from` in
/// both layers; mapgen fails if it isn't, so a data update can't silently
/// undo this. Policy: docs/REQUIREMENTS.md §4.
const TRANSFERS: &[(&str, &str, (f64, f64), &str)] = &[
    ("RUS", "UKR", (34.10, 44.95), "Crimea"), // point: Simferopol
];

pub fn run(coarse_path: &str, fine_path: &str, out_path: &str) -> Result<String, String> {
    let mut coarse = read_features(coarse_path)?;
    let mut fine = read_features(fine_path)?;
    apply_transfers(&mut coarse, coarse_path)?;
    apply_transfers(&mut fine, fine_path)?;

    let coarse_by_id: HashMap<String, Vec<Vec<f32>>> = coarse
        .iter()
        .map(|f| Ok((prop_str(f, "ADM0_A3")?, project_geometry(f)?)))
        .collect::<Result<_, String>>()?;

    let mut countries = Vec::new();
    let mut simplified = 0;
    for feature in &fine {
        let id = prop_str(feature, "ADM0_A3")?;
        let fine_rings = project_geometry(feature)?;
        let coarse_rings = match coarse_by_id.get(&id) {
            Some(rings) => rings.clone(),
            None => {
                simplified += 1;
                fine_rings
                    .iter()
                    .map(|r| simplify_ring(r, COARSE_TOLERANCE))
                    .collect()
            }
        };
        let name = NAME_OVERRIDES
            .iter()
            .find(|(code, _)| *code == id)
            .map(|(_, name)| name.to_string())
            .map_or_else(|| prop_str(feature, "NAME_EN"), Ok)?;
        let (lx, ly) = equal_earth(prop_f64(feature, "LABEL_X")?, prop_f64(feature, "LABEL_Y")?);
        let iso2 = ISO_OVERRIDES
            .iter()
            .find(|(code, _)| *code == id)
            .map(|(_, iso2)| iso2.to_string())
            .map_or_else(|| prop_str(feature, "ISO_A2_EH"), Ok)?;
        countries.push(CountryData {
            iso2,
            name,
            continent: prop_str(feature, "CONTINENT")?,
            color_group: prop_f64(feature, "MAPCOLOR7")? as u8,
            label: (lx as f32, ly as f32),
            coarse: coarse_rings,
            fine: fine_rings,
            id,
        });
    }
    countries.sort_by(|a, b| a.id.cmp(&b.id));

    let bytes = encode(&countries);
    std::fs::write(out_path, &bytes).map_err(|e| format!("writing {out_path}: {e}"))?;
    let points = |pick: fn(&CountryData) -> &Vec<Vec<f32>>| -> usize {
        countries.iter().flat_map(pick).map(|r| r.len() / 2).sum()
    };
    Ok(format!(
        "==> {} countries ({} coarse outlines simplified from 1:50m), {} coarse + {} fine points, {} KB -> {}",
        countries.len(),
        simplified,
        points(|c| &c.coarse),
        points(|c| &c.fine),
        bytes.len() / 1024,
        out_path
    ))
}

/// Moves each TRANSFERS territory polygon from one country's MultiPolygon
/// to the other's (turning a Polygon into a MultiPolygon if needed).
fn apply_transfers(features: &mut [Value], path: &str) -> Result<(), String> {
    for &(from, to, (lon, lat), name) in TRANSFERS {
        let index_of = |code: &str| {
            features
                .iter()
                .position(|f| f["properties"]["ADM0_A3"] == code)
                .ok_or_else(|| format!("{path}: no feature {code} for the {name} transfer"))
        };
        let (from_i, to_i) = (index_of(from)?, index_of(to)?);
        if features[from_i]["geometry"]["type"] != "MultiPolygon" {
            return Err(format!("{path}: {from} is not a MultiPolygon"));
        }
        let polygons = features[from_i]["geometry"]["coordinates"]
            .as_array_mut()
            .ok_or_else(|| format!("{path}: {from} has no coordinates"))?;
        let hit = polygons
            .iter()
            .position(|polygon| outer_ring_contains(polygon, lon, lat))
            .ok_or_else(|| format!("{path}: {name} is not a separate polygon of {from}"))?;
        let moved = polygons.remove(hit);
        let geometry = &mut features[to_i]["geometry"];
        if geometry["type"] == "Polygon" {
            let single = geometry["coordinates"].take();
            geometry["type"] = Value::from("MultiPolygon");
            geometry["coordinates"] = Value::Array(vec![single]);
        }
        geometry["coordinates"]
            .as_array_mut()
            .ok_or_else(|| format!("{path}: {to} has no coordinates"))?
            .push(moved);
    }
    Ok(())
}

fn outer_ring_contains(polygon: &Value, lon: f64, lat: f64) -> bool {
    let Some(ring) = polygon.get(0).and_then(Value::as_array) else {
        return false;
    };
    let flat: Vec<f32> = ring
        .iter()
        .flat_map(|p| {
            [
                p[0].as_f64().unwrap_or(f64::NAN) as f32,
                p[1].as_f64().unwrap_or(f64::NAN) as f32,
            ]
        })
        .collect();
    crate::map::geometry::point_in_rings(&[flat], lon as f32, lat as f32)
}

fn read_features(path: &str) -> Result<Vec<Value>, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("reading {path}: {e}"))?;
    let json: Value = serde_json::from_str(&text).map_err(|e| format!("parsing {path}: {e}"))?;
    json["features"]
        .as_array()
        .cloned()
        .ok_or_else(|| format!("{path}: no features array"))
}

fn prop_str(feature: &Value, key: &str) -> Result<String, String> {
    feature["properties"][key]
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| format!("feature missing string property {key}"))
}

fn prop_f64(feature: &Value, key: &str) -> Result<f64, String> {
    feature["properties"][key]
        .as_f64()
        .ok_or_else(|| format!("feature missing number property {key}"))
}

/// Projects a Polygon/MultiPolygon into flat rings (outer rings and holes
/// alike; the app fills with the even-odd rule).
fn project_geometry(feature: &Value) -> Result<Vec<Vec<f32>>, String> {
    let geometry = &feature["geometry"];
    let polygons: Vec<&Value> = match geometry["type"].as_str() {
        Some("Polygon") => vec![&geometry["coordinates"]],
        Some("MultiPolygon") => geometry["coordinates"]
            .as_array()
            .ok_or("bad MultiPolygon")?
            .iter()
            .collect(),
        other => return Err(format!("unsupported geometry {other:?}")),
    };
    let mut rings = Vec::new();
    for polygon in polygons {
        for ring in polygon.as_array().ok_or("bad polygon")? {
            let mut flat = Vec::new();
            for point in ring.as_array().ok_or("bad ring")? {
                let lon = point[0].as_f64().ok_or("bad lon")?;
                let lat = point[1].as_f64().ok_or("bad lat")?;
                let (x, y) = equal_earth(lon, lat);
                flat.extend([x as f32, y as f32]);
            }
            rings.push(flat);
        }
    }
    Ok(rings)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::datagen::testutil::{rect, temp_dir, write_collection};
    use crate::map::World;
    use serde_json::json;

    fn country(id: &str, iso2: &str, name: &str, geometry: Value) -> Value {
        json!({"type": "Feature",
               "properties": {"ADM0_A3": id, "ISO_A2_EH": iso2, "NAME_EN": name, "CONTINENT": "Europe",
                              "MAPCOLOR7": 2, "LABEL_X": 0.0, "LABEL_Y": 0.0},
               "geometry": geometry})
    }

    /// Russia with Crimea as a separate polygon, and Ukraine as a Polygon.
    fn russia_and_ukraine() -> Vec<Value> {
        vec![
            country(
                "RUS",
                "RU",
                "Russia",
                json!({"type": "MultiPolygon", "coordinates": [
                    [rect(40.0, 50.0, 60.0, 60.0)],
                    [rect(33.0, 44.4, 36.5, 46.0)],
                ]}),
            ),
            country(
                "UKR",
                "UA",
                "Ukraine",
                json!({"type": "Polygon", "coordinates": [rect(24.0, 46.5, 40.0, 52.0)]}),
            ),
        ]
    }

    #[test]
    fn crimea_moves_from_russia_to_ukraine() {
        let mut features = russia_and_ukraine();
        apply_transfers(&mut features, "test").unwrap();
        assert_eq!(
            features[0]["geometry"]["coordinates"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        let ukraine = &features[1]["geometry"];
        assert_eq!(ukraine["type"], "MultiPolygon");
        let polygons = ukraine["coordinates"].as_array().unwrap();
        assert_eq!(polygons.len(), 2);
        assert!(outer_ring_contains(&polygons[1], 34.10, 44.95));
    }

    #[test]
    fn a_transfer_fails_loudly_if_the_territory_is_not_a_polygon_of_its_own() {
        // A data update that merged Crimea into another polygon, or dropped
        // it, must stop the build rather than silently undo the policy.
        let mut joined = russia_and_ukraine();
        joined[0]["geometry"]["coordinates"] = json!([[rect(40.0, 50.0, 60.0, 60.0)]]);
        let err = apply_transfers(&mut joined, "test").unwrap_err();
        assert!(err.contains("Crimea"), "{err}");
    }

    #[test]
    fn a_transfer_fails_loudly_if_a_country_is_missing() {
        let mut only_russia = russia_and_ukraine();
        only_russia.pop();
        let err = apply_transfers(&mut only_russia, "test").unwrap_err();
        assert!(err.contains("UKR"), "{err}");
    }

    #[test]
    fn outer_ring_contains_ignores_holes_and_bad_input() {
        let with_hole = json!([rect(0.0, 0.0, 10.0, 10.0), rect(4.0, 4.0, 6.0, 6.0)]);
        assert!(outer_ring_contains(&with_hole, 5.0, 5.0));
        assert!(!outer_ring_contains(&with_hole, 11.0, 5.0));
        assert!(!outer_ring_contains(&json!([]), 5.0, 5.0));
    }

    #[test]
    fn only_polygons_can_be_projected() {
        let point = country(
            "PNT",
            "PT",
            "Pointland",
            json!({"type": "Point", "coordinates": [0.0, 0.0]}),
        );
        assert!(project_geometry(&point).is_err());
        let square = country(
            "SQR",
            "SQ",
            "Square",
            json!({"type": "Polygon", "coordinates": [rect(0.0, 0.0, 1.0, 1.0)]}),
        );
        let rings = project_geometry(&square).unwrap();
        assert_eq!(rings.len(), 1);
        assert_eq!(rings[0].len(), 10);
    }

    fn layers(dir: &std::path::Path) -> (String, String) {
        let mut coarse = russia_and_ukraine();
        coarse.push(country(
            "CHN",
            "CN",
            "People's Republic of China",
            json!({"type": "Polygon", "coordinates": [rect(80.0, 20.0, 120.0, 45.0)]}),
        ));
        let mut fine = coarse.clone();
        // Only in the 1:50m layer: its coarse outline is simplified from it.
        let detailed: Vec<Value> = (0..=40)
            .map(|i| json!([100.0 + f64::from(i) * 0.01, -10.0]))
            .chain([
                json!([100.4, -10.4]),
                json!([100.0, -10.4]),
                json!([100.0, -10.0]),
            ])
            .collect();
        fine.push(country(
            "IOA",
            "AU",
            "Indian Ocean Territories",
            json!({"type": "Polygon", "coordinates": [detailed]}),
        ));
        (
            write_collection(dir, "110m.json", coarse),
            write_collection(dir, "50m.json", fine),
        )
    }

    #[test]
    fn run_builds_a_world_with_the_family_rules() {
        let dir = temp_dir("mapgen-run");
        let (coarse, fine) = layers(&dir);
        let out = dir.join("World.bin");
        run(&coarse, &fine, out.to_str().unwrap()).unwrap();
        let world = World::new(std::fs::read(&out).unwrap()).unwrap();
        let meta = world.countries();
        let ids: Vec<&str> = meta.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(ids, ["CHN", "IOA", "RUS", "UKR"]); // sorted by id
        assert_eq!(meta[0].name, "China"); // NAME_OVERRIDES
        assert_eq!(meta[1].iso2, "-99"); // ISO_OVERRIDES: not Australia's card
        let shapes = (
            world.shapes(crate::map::Detail::Coarse),
            world.shapes(crate::map::Detail::Fine),
        );
        assert!(
            shapes.0[1].rings[0].len() < shapes.1[1].rings[0].len(),
            "IOA coarse is simplified"
        );
        // Crimea (Simferopol) is Ukraine.
        let (x, y) = equal_earth(34.10, 44.95);
        assert_eq!(world.country_at(x as f32, y as f32, 0.0), Some(3));
    }

    #[test]
    fn run_is_deterministic_and_fails_on_missing_properties() {
        let dir = temp_dir("mapgen-twice");
        let (coarse, fine) = layers(&dir);
        let (a, b) = (dir.join("a.bin"), dir.join("b.bin"));
        run(&coarse, &fine, a.to_str().unwrap()).unwrap();
        run(&coarse, &fine, b.to_str().unwrap()).unwrap();
        assert_eq!(std::fs::read(a).unwrap(), std::fs::read(b).unwrap());

        let mut broken = russia_and_ukraine();
        broken[1]["properties"]["MAPCOLOR7"] = Value::Null;
        let broken = write_collection(&dir, "broken.json", broken);
        let err = run(&coarse, &broken, dir.join("c.bin").to_str().unwrap()).unwrap_err();
        assert!(err.contains("MAPCOLOR7"), "{err}");
    }
}
