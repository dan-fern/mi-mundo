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

/// English names a kid would know from school, where Natural Earth keeps
/// a local form, a headwater or delta-branch name, or a typo (most local
/// names, like Vänern or Paraná, are also the English name and stay).
/// Whitespace runs are collapsed before this lookup.
const RENAMES: &[(&str, &str)] = &[
    // Rivers: one English name per river, so a river split into segments
    // isn't labelled twice under different names.
    ("Amazonas", "Amazon"),
    ("Rhein", "Rhine"),
    ("Bénoué", "Benue"),
    ("Sénégal", "Senegal"),
    ("Al Furat", "Euphrates"),
    ("Firat", "Euphrates"),
    ("Dicle", "Tigris"),
    ("Ertis", "Irtysh"),
    ("Dnepre", "Dnieper"),
    ("Abay", "Blue Nile"),
    ("Huang", "Yellow River"),
    ("Yellow", "Yellow River"),
    ("Nu", "Salween"),
    ("Ayeyarwady", "Irrawaddy"),
    ("Irrawaddy Delta", "Irrawaddy"),
    ("Nmai", "Irrawaddy"),
    ("Tongtian", "Yangtze"),
    ("Tuotuo", "Yangtze"),
    ("Za", "Mekong"),
    ("Damqogkanbab", "Brahmaputra"),
    ("Dihang", "Brahmaputra"),
    ("Shiquan", "Indus"),
    ("Teslin", "Yukon"),
    ("Ideriyn", "Selenga"),
    ("Selenge (Selenga)", "Selenga"),
    // Lakes.
    ("Lago Titicaca", "Lake Titicaca"),
    ("Lago de Nicaragua", "Lake Nicaragua"),
    ("Qinghai Hu", "Qinghai Lake"),
    ("Poyang Hu", "Poyang Lake"),
    ("Tai Hu", "Lake Tai"),
    ("Khövsgöl Nuur", "Lake Khövsgöl"),
    ("Lagoa Minim", "Lagoa Mirim"),
    ("Lac Île-á-la-Crosse", "Lac Île-à-la-Crosse"),
    ("Lac Moeru", "Lake Mweru"),
    ("Buhayrat ath Tharthar", "Lake Tharthar"),
    ("Pskov", "Lake Pskov"),
    ("Kaliningradskiy Zaliv", "Vistula Lagoon"),
    ("Zalev Wislany", "Vistula Lagoon"),
    // Ranges.
    ("Appennino Ligure", "Apennines"), // the polygon covers the whole chain
    ("Ahag", "Ahaggar Mountains"),
    ("Serra da Mantiquiera", "Serra da Mantiqueira"),
    ("Pamir mountains", "Pamir Mountains"),
    ("Kolyma mountains", "Kolyma Mountains"),
    ("Naga hills", "Naga Hills"),
    ("Tannu-Ola mountains", "Tannu-Ola Mountains"),
    ("Crystal Mountain", "Crystal Mountains"),
    ("Columbia Kootenay Mountain", "Columbia Mountains"),
    // Peaks.
    ("Gora Elbrus", "Mount Elbrus"),
    ("Cerro Aconcagua", "Aconcagua"),
    ("Gunung Kinabalu", "Mount Kinabalu"),
    ("Pik Imeni Ismail Samani", "Ismoil Somoni Peak"),
];

/// Left out: river delta channels and stubs that showed as mystery labels
/// at whole-world zoom, regions that aren't deserts (Punjab is farmland,
/// Caatinga is dry shrubland), and minor US state high points that crowded
/// out world-famous peaks.
const DROP: &[(FeatureKind, &str)] = &[
    (FeatureKind::River, "Madison"),
    (FeatureKind::River, "Weir"),
    (FeatureKind::River, "Borcea"),
    (FeatureKind::River, "Bratul Chillia"),
    (FeatureKind::River, "Bratul Sulina"),
    (FeatureKind::River, "Bratul Sfintu Gheorghe"),
    (FeatureKind::River, "Bykovskaya Protoka"),
    (FeatureKind::River, "Olenekskaya Protoka"),
    (FeatureKind::Desert, "Punjab"),
    (FeatureKind::Desert, "Caatinga"),
    (FeatureKind::Peak, "Spruce Knob"),
    (FeatureKind::Peak, "Trapper Peak"),
    (FeatureKind::Peak, "Sacajawea Peak"),
    (FeatureKind::Peak, "Mount Rogers"),
    (FeatureKind::Peak, "Clingmans Dome"),
    (FeatureKind::Peak, "Uncompahgre Peak"),
    (FeatureKind::Peak, "Borah Peak"),
    (FeatureKind::Peak, "Wheeler Peak"),
    (FeatureKind::Peak, "King's Peak"),
    (FeatureKind::Peak, "Mount Katahdin"),
    (FeatureKind::Peak, "Mount Chamberlin"),
];

/// Renames that depend on where the feature is: (name, lon range, lat
/// range of its first point, new name; empty = drop).
type Located = (&'static str, (f64, f64), (f64, f64), &'static str);
const LOCATED: &[Located] = &[
    // Natural Earth names Colombia's central range "Cordillera Blanca" too.
    (
        "Cordillera Blanca",
        (-80.0, -70.0),
        (0.0, 12.0),
        "Cordillera Central",
    ),
    // Bolivia's Río Grande, easily confused with the US/Mexico Rio Grande.
    ("Grande", (-70.0, -55.0), (-25.0, -10.0), ""),
];

/// World-famous peaks Natural Earth's 1:50m points leave out:
/// (name, lon, lat, elevation m). Shown from web zoom 5, like most peaks.
const EXTRA_PEAKS: &[(&str, f64, f64, i32)] = &[
    ("Mount Fuji", 138.7274, 35.3606, 3776),
    ("Matterhorn", 7.6586, 45.9763, 4478),
    ("Aoraki / Mount Cook", 170.1418, -43.5950, 3724),
    ("Mauna Kea", -155.4681, 19.8207, 4207),
    ("Mount Etna", 14.9934, 37.7510, 3357),
    ("Mount Vesuvius", 14.4261, 40.8214, 1281),
    ("Mount Olympus", 22.3583, 40.0857, 2918),
    ("Mount Ararat", 44.2983, 39.7016, 5137),
    ("Mount Rainier", -121.7603, 46.8529, 4392),
];

/// Label points moved by hand (name, lon, lat) where the computed one lands
/// in the wrong country for quiz reveals: Lake Malawi's fell in
/// Mozambique's part of the lake.
const LABEL_AT: &[(&str, f64, f64)] = &[("Lake Malawi", 34.4, -11.5)];

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
    let mut skipped = Skipped::default();

    for f in read_features(rivers)? {
        if prop_str(&f, &["featurecla"]).as_deref() != Some("River") {
            continue;
        }
        let Some(name) = clean_name(FeatureKind::River, &f, RIVER_NAMES, &mut skipped)? else {
            continue;
        };
        let parts = project_lines(&f)?;
        let Some((x, y, angle)) = polyline_label(&parts) else {
            skipped.no_label += 1;
            continue;
        };
        let zooms = zooms(&f, "min_zoom", "min_label")?;
        features.push(feature(
            FeatureKind::River,
            name,
            parts,
            (x, y, angle),
            0,
            zooms,
        ));
    }

    for f in read_features(lakes)? {
        let Some(name) = clean_name(FeatureKind::Lake, &f, LAKE_NAMES, &mut skipped)? else {
            continue;
        };
        let parts = project_rings(&f)?;
        let Some((x, y)) = ring_label(&parts) else {
            skipped.no_label += 1;
            continue;
        };
        let zooms = zooms(&f, "min_zoom", "min_label")?;
        features.push(feature(
            FeatureKind::Lake,
            name,
            parts,
            (x, y, 0.0),
            0,
            zooms,
        ));
    }

    for f in read_features(regions)? {
        let kind = match prop_str(&f, &["FEATURECLA"]).as_deref() {
            Some("Desert") => FeatureKind::Desert,
            Some("Range/mtn") => FeatureKind::Range,
            _ => continue,
        };
        let Some(name) = clean_name(kind, &f, REGION_NAMES, &mut skipped)? else {
            continue;
        };
        let parts = project_rings(&f)?;
        let Some((x, y)) = ring_label(&parts) else {
            skipped.no_label += 1;
            continue;
        };
        let zooms = zooms(&f, "MIN_LABEL", "MIN_LABEL")?;
        features.push(feature(kind, name, parts, (x, y, 0.0), 0, zooms));
    }

    for f in read_features(peaks)? {
        if prop_str(&f, &["featurecla"]).as_deref() != Some("mountain") {
            continue;
        }
        let Some(name) = clean_name(FeatureKind::Peak, &f, PEAK_NAMES, &mut skipped)? else {
            continue;
        };
        let (x, y) = project_point(&f["geometry"]["coordinates"])?;
        let elevation = f["properties"]["elevation"]
            .as_f64()
            .ok_or_else(|| format!("peak {name} has no elevation"))?
            .round() as i32;
        let zooms = zooms(&f, "min_zoom", "min_zoom")?;
        features.push(feature(
            FeatureKind::Peak,
            name,
            vec![vec![x, y]],
            (x, y, 0.0),
            elevation,
            zooms,
        ));
    }
    for &(name, lon, lat, elevation) in EXTRA_PEAKS {
        let (x, y) = equal_earth(lon, lat);
        let (x, y) = (x as f32, y as f32);
        let zoom = camera_zoom_from_web(5.0);
        features.push(feature(
            FeatureKind::Peak,
            name.into(),
            vec![vec![x, y]],
            (x, y, 0.0),
            elevation,
            (zoom, zoom),
        ));
    }

    for &(name, lon, lat) in LABEL_AT {
        let (x, y) = equal_earth(lon, lat);
        let f = features
            .iter_mut()
            .find(|f| f.name == name)
            .ok_or_else(|| format!("LABEL_AT: no feature named {name}"))?;
        (f.label_x, f.label_y) = (x as f32, y as f32);
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
        "==> {} rivers, {} lakes, {} deserts, {} ranges, {} peaks, {} KB -> {out}\n    \
         ({} nameless kept to draw, {} dropped by DROP/LOCATED, {} with no usable geometry)",
        count(FeatureKind::River),
        count(FeatureKind::Lake),
        count(FeatureKind::Desert),
        count(FeatureKind::Range),
        count(FeatureKind::Peak),
        bytes.len() / 1024,
        features.iter().filter(|f| f.name.is_empty()).count(),
        skipped.dropped,
        skipped.no_label,
    ))
}

#[derive(Default)]
struct Skipped {
    dropped: usize,
    no_label: usize,
}

/// The feature's display name after RENAMES, LOCATED and DROP; `None` if it
/// is left out. Nameless features are kept on purpose (85 small lakes and
/// a few river stubs): they still draw, the app just never labels them.
fn clean_name(
    kind: FeatureKind,
    f: &Value,
    keys: &[&str],
    skipped: &mut Skipped,
) -> Result<Option<String>, String> {
    let mut name = prop_str(f, keys).unwrap_or_default();
    if let Some((lon, lat)) = first_point(&f["geometry"]["coordinates"]) {
        for &(from, (lon0, lon1), (lat0, lat1), to) in LOCATED {
            if name == from && (lon0..=lon1).contains(&lon) && (lat0..=lat1).contains(&lat) {
                name = to.to_string();
                if name.is_empty() {
                    skipped.dropped += 1;
                    return Ok(None);
                }
            }
        }
    }
    if DROP.iter().any(|&(k, n)| k == kind && n == name) {
        skipped.dropped += 1;
        return Ok(None);
    }
    Ok(Some(name))
}

/// First coordinate pair anywhere in a GeoJSON coordinates array.
fn first_point(c: &Value) -> Option<(f64, f64)> {
    match c.as_array()?.as_slice() {
        [Value::Number(lon), Value::Number(lat), ..] => Some((lon.as_f64()?, lat.as_f64()?)),
        [first, ..] => first_point(first),
        [] => None,
    }
}

/// (min_zoom, label_min_zoom) in camera units from Natural Earth's web zoom
/// keys. A missing key is an error: defaulting would silently move every
/// feature if a Natural Earth update renamed a field.
fn zooms(f: &Value, min_zoom_key: &str, label_key: &str) -> Result<(f32, f32), String> {
    let web = |key: &str| {
        f["properties"][key]
            .as_f64()
            .ok_or_else(|| format!("feature {:?} has no numeric {key}", f["properties"]["name"]))
    };
    let min_zoom = camera_zoom_from_web(web(min_zoom_key)?);
    Ok((
        min_zoom,
        camera_zoom_from_web(web(label_key)?).max(min_zoom),
    ))
}

fn feature(
    kind: FeatureKind,
    name: String,
    parts: Vec<Vec<f32>>,
    (label_x, label_y, label_angle): (f32, f32, f32),
    elevation_m: i32,
    (min_zoom, label_min_zoom): (f32, f32),
) -> PhysicalFeature {
    PhysicalFeature {
        kind,
        name,
        min_zoom,
        label_min_zoom,
        label_x,
        label_y,
        label_angle,
        elevation_m,
        parts,
    }
}

fn read_features(path: &str) -> Result<Vec<Value>, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("reading {path}: {e}"))?;
    let json: Value = serde_json::from_str(&text).map_err(|e| format!("parsing {path}: {e}"))?;
    json["features"]
        .as_array()
        .cloned()
        .ok_or_else(|| format!("{path}: no features array"))
}

/// First non-empty string among `keys`, whitespace collapsed, with RENAMES
/// applied.
fn prop_str(f: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .filter_map(|k| f["properties"][*k].as_str())
        .find(|s| !s.trim().is_empty())
        .map(|s| {
            let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
            RENAMES
                .iter()
                .find(|(from, _)| *from == s)
                .map_or(s, |(_, to)| to.to_string())
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
