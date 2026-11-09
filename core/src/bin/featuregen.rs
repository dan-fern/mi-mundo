//! Builds `Features.bin` (see `map::features`) from Natural Earth 1:50m
//! physical layers.
//!
//! Usage: featuregen <rivers_lake_centerlines> <lakes> <geography_regions_polys>
//!                   <geography_regions_elevation_points> <out Features.bin>
//!
//! Kept: rivers (not lake centerlines), lakes and reservoirs, deserts,
//! mountain ranges and mountain peaks. Natural Earth's own zoom hints
//! (min_zoom / min_label, in web-map zoom levels) decide when each appears.
//!
//! Run via tools/build-data.sh (needs `--features mapgen`).

use std::process::ExitCode;

use mimundo_core::map::equal_earth;
use mimundo_core::map::features::{
    FeatureKind, PhysicalFeature, camera_zoom_from_web, encode, polyline_label, ring_label,
};
use serde_json::Value;

/// Which Natural Earth name field reads best, per layer (checked by hand):
/// rivers' `name_en` is the familiar English name (Danube, not Donau);
/// lakes' `name_en` drops "Lake" or is odd ("Nyanza"), but `label` is right.
const RIVER_NAMES: &[&str] = &["name_en", "name"];
const LAKE_NAMES: &[&str] = &["label", "name", "name_en"];
const REGION_NAMES: &[&str] = &["NAME_EN", "NAME"];
const PEAK_NAMES: &[&str] = &["name_en", "name"];

/// Plain English names where Natural Earth keeps a local form that a kid
/// wouldn't recognize from school (most local names, like Vänern or Paraná,
/// are also the English name and stay).
const RENAMES: &[(&str, &str)] = &[
    ("Rhein", "Rhine"),
    ("Bénoué", "Benue"),
    ("Sénégal", "Senegal"),
    ("São  Francisco", "São Francisco"),
    ("Lago Titicaca", "Lake Titicaca"),
    ("Lago de Nicaragua", "Lake Nicaragua"),
    ("Qinghai Hu", "Qinghai Lake"),
    ("Poyang Hu", "Poyang Lake"),
    ("Tai Hu", "Lake Tai"),
    ("Khövsgöl Nuur", "Lake Khövsgöl"),
    ("Appennino Ligure", "Ligurian Apennines"),
];

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 6 {
        eprintln!(
            "usage: featuregen <rivers> <lakes> <regions_polys> <elevation_points> <out Features.bin>"
        );
        return ExitCode::from(2);
    }
    match run(&args[1], &args[2], &args[3], &args[4], &args[5]) {
        Ok(summary) => {
            println!("{summary}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("featuregen: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(rivers: &str, lakes: &str, regions: &str, peaks: &str, out: &str) -> Result<String, String> {
    let mut features = Vec::new();

    for f in read_features(rivers)? {
        if prop_str(&f, &["featurecla"]).as_deref() != Some("River") {
            continue;
        }
        let parts = project_lines(&f)?;
        let Some((x, y, angle)) = polyline_label(&parts) else {
            continue;
        };
        features.push(feature(
            FeatureKind::River,
            &f,
            prop_str(&f, RIVER_NAMES).unwrap_or_default(),
            parts,
            (x, y, angle),
            0,
            "min_zoom",
            "min_label",
        )?);
    }

    for f in read_features(lakes)? {
        let parts = project_rings(&f)?;
        let Some((x, y)) = ring_label(&parts) else {
            continue;
        };
        features.push(feature(
            FeatureKind::Lake,
            &f,
            prop_str(&f, LAKE_NAMES).unwrap_or_default(),
            parts,
            (x, y, 0.0),
            0,
            "min_zoom",
            "min_label",
        )?);
    }

    for f in read_features(regions)? {
        let kind = match prop_str(&f, &["FEATURECLA"]).as_deref() {
            Some("Desert") => FeatureKind::Desert,
            Some("Range/mtn") => FeatureKind::Range,
            _ => continue,
        };
        let parts = project_rings(&f)?;
        let Some((x, y)) = ring_label(&parts) else {
            continue;
        };
        features.push(feature(
            kind,
            &f,
            prop_str(&f, REGION_NAMES).unwrap_or_default(),
            parts,
            (x, y, 0.0),
            0,
            "MIN_LABEL",
            "MIN_LABEL",
        )?);
    }

    for f in read_features(peaks)? {
        if prop_str(&f, &["featurecla"]).as_deref() != Some("mountain") {
            continue;
        }
        let coords = &f["geometry"]["coordinates"];
        let (x, y) = project_point(coords)?;
        let elevation = f["properties"]["elevation"].as_f64().unwrap_or(0.0).round() as i32;
        features.push(feature(
            FeatureKind::Peak,
            &f,
            prop_str(&f, PEAK_NAMES).unwrap_or_default(),
            vec![vec![x, y]],
            (x, y, 0.0),
            elevation,
            "min_zoom",
            "min_zoom",
        )?);
    }

    // Deterministic order: kind, then when it appears, then name.
    let kind_rank = |k: FeatureKind| k as u8;
    features.sort_by(|a, b| {
        kind_rank(a.kind)
            .cmp(&kind_rank(b.kind))
            .then(a.min_zoom.total_cmp(&b.min_zoom))
            .then(a.name.cmp(&b.name))
            .then(a.label_x.total_cmp(&b.label_x))
    });

    let bytes = encode(&features);
    std::fs::write(out, &bytes).map_err(|e| format!("writing {out}: {e}"))?;
    let count = |k: FeatureKind| features.iter().filter(|f| f.kind == k).count();
    Ok(format!(
        "==> {} rivers, {} lakes, {} deserts, {} ranges, {} peaks, {} KB -> {out}",
        count(FeatureKind::River),
        count(FeatureKind::Lake),
        count(FeatureKind::Desert),
        count(FeatureKind::Range),
        count(FeatureKind::Peak),
        bytes.len() / 1024
    ))
}

#[allow(clippy::too_many_arguments)]
fn feature(
    kind: FeatureKind,
    f: &Value,
    name: String,
    parts: Vec<Vec<f32>>,
    (label_x, label_y, label_angle): (f32, f32, f32),
    elevation_m: i32,
    min_zoom_key: &str,
    label_key: &str,
) -> Result<PhysicalFeature, String> {
    let web = |key: &str| f["properties"][key].as_f64().unwrap_or(5.0);
    let min_zoom = camera_zoom_from_web(web(min_zoom_key));
    Ok(PhysicalFeature {
        kind,
        name,
        min_zoom,
        label_min_zoom: camera_zoom_from_web(web(label_key)).max(min_zoom),
        label_x,
        label_y,
        label_angle,
        elevation_m,
        parts,
    })
}

fn read_features(path: &str) -> Result<Vec<Value>, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("reading {path}: {e}"))?;
    let json: Value = serde_json::from_str(&text).map_err(|e| format!("parsing {path}: {e}"))?;
    json["features"]
        .as_array()
        .cloned()
        .ok_or_else(|| format!("{path}: no features array"))
}

/// First non-empty string among `keys`, with RENAMES applied.
fn prop_str(f: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .filter_map(|k| f["properties"][*k].as_str())
        .find(|s| !s.trim().is_empty())
        .map(|s| {
            let s = s.trim();
            RENAMES
                .iter()
                .find(|(from, _)| *from == s)
                .map_or(s, |(_, to)| to)
                .to_string()
        })
}

fn project_point(p: &Value) -> Result<(f32, f32), String> {
    let lon = p[0].as_f64().ok_or("bad lon")?;
    let lat = p[1].as_f64().ok_or("bad lat")?;
    let (x, y) = equal_earth(lon, lat);
    Ok((x as f32, y as f32))
}

fn project_line(line: &Value) -> Result<Vec<f32>, String> {
    let mut flat = Vec::new();
    for p in line.as_array().ok_or("bad line")? {
        let (x, y) = project_point(p)?;
        flat.extend([x, y]);
    }
    Ok(flat)
}

fn project_lines(f: &Value) -> Result<Vec<Vec<f32>>, String> {
    let g = &f["geometry"];
    match g["type"].as_str() {
        Some("LineString") => Ok(vec![project_line(&g["coordinates"])?]),
        Some("MultiLineString") => g["coordinates"]
            .as_array()
            .ok_or("bad MultiLineString")?
            .iter()
            .map(project_line)
            .collect(),
        other => Err(format!("expected lines, got {other:?}")),
    }
}

fn project_rings(f: &Value) -> Result<Vec<Vec<f32>>, String> {
    let g = &f["geometry"];
    let polygons: Vec<&Value> = match g["type"].as_str() {
        Some("Polygon") => vec![&g["coordinates"]],
        Some("MultiPolygon") => g["coordinates"]
            .as_array()
            .ok_or("bad MultiPolygon")?
            .iter()
            .collect(),
        other => return Err(format!("expected polygons, got {other:?}")),
    };
    let mut rings = Vec::new();
    for polygon in polygons {
        for ring in polygon.as_array().ok_or("bad polygon")? {
            rings.push(project_line(ring)?);
        }
    }
    Ok(rings)
}
