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
use std::process::ExitCode;

use mimundo_core::map::geometry::simplify_ring;
use mimundo_core::map::world::encode;
use mimundo_core::map::{CountryData, equal_earth};
use serde_json::Value;

/// Tolerance (map units) when simplifying 1:50m outlines for the coarse
/// level, for countries missing from the 1:110m layer. ~0.002 ≈ 1 px on a
/// full-width iPad map.
const COARSE_TOLERANCE: f32 = 0.002;

/// Display names where Natural Earth's NAME_EN is the formal name.
const NAME_OVERRIDES: &[(&str, &str)] = &[("CHN", "China"), ("CYN", "Northern Cyprus")];

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!("usage: mapgen <ne_110m.geojson> <ne_50m.geojson> <out World.bin>");
        return ExitCode::from(2);
    }
    match run(&args[1], &args[2], &args[3]) {
        Ok(summary) => {
            println!("{summary}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("mapgen: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(coarse_path: &str, fine_path: &str, out_path: &str) -> Result<String, String> {
    let coarse = read_features(coarse_path)?;
    let fine = read_features(fine_path)?;

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
        countries.push(CountryData {
            iso2: prop_str(feature, "ISO_A2_EH")?,
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
