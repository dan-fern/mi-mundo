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

use crate::map::equal_earth;
use crate::map::features::{
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

pub fn run(
    rivers: &str,
    lakes: &str,
    regions: &str,
    peaks: &str,
    out: &str,
) -> Result<String, String> {
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

    // Natural Earth lists a few lakes twice (Lake Zaysan): keep the first.
    let mut seen = std::collections::HashSet::new();
    features.retain(|f| {
        seen.insert((
            f.kind as u8,
            f.name.clone(),
            f.label_x.to_bits(),
            f.label_y.to_bits(),
        ))
    });

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::datagen::testutil::{rect, temp_dir, write_collection};
    use crate::map::load_features;
    use serde_json::json;

    fn props(p: Value) -> Value {
        json!({"type": "Feature", "properties": p, "geometry": {"type": "Point", "coordinates": [0.0, 0.0]}})
    }

    #[test]
    fn names_are_tidied_and_renamed() {
        assert_eq!(
            prop_str(&props(json!({"name": " Amu  Darya "})), &["name"]).as_deref(),
            Some("Amu Darya")
        );
        assert_eq!(
            prop_str(&props(json!({"name": "Rhein"})), &["name"]).as_deref(),
            Some("Rhine")
        );
        assert_eq!(
            prop_str(&props(json!({"name": "Vänern"})), &["name"]).as_deref(),
            Some("Vänern")
        );
    }

    #[test]
    fn name_keys_are_tried_in_order_skipping_blanks() {
        let lake =
            props(json!({"label": "Lake Victoria", "name": "Victoria", "name_en": "Nyanza"}));
        assert_eq!(
            prop_str(&lake, LAKE_NAMES).as_deref(),
            Some("Lake Victoria")
        );
        let blank_label = props(json!({"label": "  ", "name": "Lake Chad"}));
        assert_eq!(
            prop_str(&blank_label, LAKE_NAMES).as_deref(),
            Some("Lake Chad")
        );
        assert_eq!(prop_str(&props(json!({"other": "x"})), LAKE_NAMES), None);
    }

    #[test]
    fn drop_only_removes_its_own_kind() {
        let punjab = props(json!({"NAME": "Punjab"}));
        let mut skipped = Skipped::default();
        assert_eq!(
            clean_name(FeatureKind::Desert, &punjab, REGION_NAMES, &mut skipped).unwrap(),
            None
        );
        assert_eq!(skipped.dropped, 1);
        assert_eq!(
            clean_name(FeatureKind::Range, &punjab, REGION_NAMES, &mut skipped)
                .unwrap()
                .as_deref(),
            Some("Punjab")
        );
    }

    fn at(name: &str, lon: f64, lat: f64) -> Value {
        json!({"type": "Feature", "properties": {"NAME": name},
               "geometry": {"type": "Polygon", "coordinates": [rect(lon, lat, lon + 1.0, lat + 1.0)]}})
    }

    #[test]
    fn located_renames_apply_only_in_their_box() {
        let mut skipped = Skipped::default();
        let colombia = at("Cordillera Blanca", -75.5, 4.0);
        let peru = at("Cordillera Blanca", -77.5, -9.5);
        let name = |f: &Value, s: &mut Skipped| {
            clean_name(FeatureKind::Range, f, REGION_NAMES, s).unwrap()
        };
        assert_eq!(
            name(&colombia, &mut skipped).as_deref(),
            Some("Cordillera Central")
        );
        assert_eq!(
            name(&peru, &mut skipped).as_deref(),
            Some("Cordillera Blanca")
        );
    }

    #[test]
    fn located_drops_apply_only_in_their_box() {
        let mut skipped = Skipped::default();
        let bolivia = at("Grande", -63.0, -18.0);
        let texas = at("Grande", -100.0, 28.0);
        assert_eq!(
            clean_name(FeatureKind::River, &bolivia, REGION_NAMES, &mut skipped).unwrap(),
            None
        );
        assert_eq!(
            clean_name(FeatureKind::River, &texas, REGION_NAMES, &mut skipped)
                .unwrap()
                .as_deref(),
            Some("Grande")
        );
        assert_eq!(skipped.dropped, 1);
    }

    #[test]
    fn first_point_digs_into_nested_coordinates() {
        assert_eq!(first_point(&json!([1.5, 2.5])), Some((1.5, 2.5)));
        assert_eq!(
            first_point(&json!([[[[3.0, 4.0], [5.0, 6.0]]]])),
            Some((3.0, 4.0))
        );
        assert_eq!(first_point(&json!([])), None);
    }

    #[test]
    fn zooms_must_be_present_and_label_never_before_shape() {
        let f = props(json!({"name": "X", "min_zoom": 3.0, "min_label": 2.0}));
        assert_eq!(zooms(&f, "min_zoom", "min_label").unwrap(), (2.0, 2.0));
        let missing = props(json!({"name": "X", "min_zoom": 3.0}));
        assert!(zooms(&missing, "min_zoom", "min_label").is_err());
        let text = props(json!({"name": "X", "min_zoom": "3", "min_label": 3.0}));
        assert!(zooms(&text, "min_zoom", "min_label").is_err());
    }

    #[test]
    fn rename_and_drop_tables_are_consistent() {
        let mut sources = std::collections::HashSet::new();
        for (from, to) in RENAMES {
            assert!(sources.insert(*from), "{from} renamed twice");
            assert_ne!(from, to);
        }
        for (_, to) in RENAMES {
            assert!(!sources.contains(to), "{to} is renamed again (a chain)");
        }
        for (_, name) in DROP {
            assert!(!sources.contains(name), "{name} is renamed and dropped");
        }
    }

    /// Four tiny layers covering every branch of `run`.
    fn sample_layers(dir: &std::path::Path, peak_elevation: Value) -> [String; 4] {
        let line = |name: &str, cla: &str, coords: Value| {
            json!({"type": "Feature",
            "properties": {"featurecla": cla, "name_en": name, "min_zoom": 2.0, "min_label": 3.0},
            "geometry": {"type": "LineString", "coordinates": coords}})
        };
        let lake = |label: &str, r: Value| {
            json!({"type": "Feature",
            "properties": {"label": label, "min_zoom": 3.0, "min_label": 4.0},
            "geometry": {"type": "Polygon", "coordinates": [r]}})
        };
        let region = |name: &str, cla: &str| {
            json!({"type": "Feature",
            "properties": {"NAME": name, "FEATURECLA": cla, "MIN_LABEL": 3.0},
            "geometry": {"type": "Polygon", "coordinates": [rect(10.0, 40.0, 14.0, 44.0)]}})
        };
        let peak = |name: &str, cla: &str| {
            json!({"type": "Feature",
            "properties": {"featurecla": cla, "name": name, "elevation": peak_elevation, "min_zoom": 5.0},
            "geometry": {"type": "Point", "coordinates": [42.44, 43.35]}})
        };
        [
            write_collection(
                dir,
                "rivers.json",
                vec![
                    line(
                        "Rhein",
                        "River",
                        json!([[7.0, 47.0], [8.0, 49.0], [7.0, 51.0]]),
                    ),
                    line(
                        "Lake Path",
                        "Lake Centerline",
                        json!([[0.0, 0.0], [1.0, 1.0]]),
                    ),
                ],
            ),
            write_collection(
                dir,
                "lakes.json",
                vec![
                    lake("Lake Malawi", rect(34.0, -14.0, 35.0, -9.5)),
                    lake("Lake Geneva", rect(6.2, 46.2, 6.9, 46.5)),
                    lake("Lake Geneva", rect(6.2, 46.2, 6.9, 46.5)),
                ],
            ),
            write_collection(
                dir,
                "regions.json",
                vec![
                    region("Appennino Ligure", "Range/mtn"),
                    region("Punjab", "Desert"),
                    region("Somewhere", "Plain"),
                ],
            ),
            write_collection(
                dir,
                "peaks.json",
                vec![peak("Gora Elbrus", "mountain"), peak("A Pass", "pass")],
            ),
        ]
    }

    fn build(dir: &std::path::Path) -> Result<Vec<PhysicalFeature>, String> {
        let [rivers, lakes, regions, peaks] = sample_layers(dir, json!(5642.0));
        let out = dir.join("Features.bin");
        run(&rivers, &lakes, &regions, &peaks, out.to_str().unwrap())?;
        load_features(std::fs::read(out).unwrap()).map_err(|e| e.to_string())
    }

    #[test]
    fn run_keeps_renames_and_drops_the_right_features() {
        let features = build(&temp_dir("featuregen-run")).unwrap();
        let names = |kind| {
            let mut v: Vec<&str> = features
                .iter()
                .filter(|f| f.kind == kind)
                .map(|f| f.name.as_str())
                .collect();
            v.sort();
            v
        };
        assert_eq!(names(FeatureKind::River), ["Rhine"]);
        assert_eq!(names(FeatureKind::Lake), ["Lake Geneva", "Lake Malawi"]); // duplicate dropped
        assert_eq!(names(FeatureKind::Range), ["Apennines"]);
        assert!(names(FeatureKind::Desert).is_empty()); // Punjab
        let peaks = names(FeatureKind::Peak);
        assert!(peaks.contains(&"Mount Elbrus") && peaks.contains(&"Mount Fuji"));
        assert_eq!(peaks.len(), 1 + EXTRA_PEAKS.len()); // the pass is skipped
    }

    #[test]
    fn run_is_deterministic() {
        let dir = temp_dir("featuregen-twice");
        let [rivers, lakes, regions, peaks] = sample_layers(&dir, json!(5642.0));
        let (a, b) = (dir.join("a.bin"), dir.join("b.bin"));
        run(&rivers, &lakes, &regions, &peaks, a.to_str().unwrap()).unwrap();
        run(&rivers, &lakes, &regions, &peaks, b.to_str().unwrap()).unwrap();
        assert_eq!(std::fs::read(a).unwrap(), std::fs::read(b).unwrap());
    }

    #[test]
    fn run_fails_on_a_peak_without_a_height() {
        let dir = temp_dir("featuregen-noheight");
        let [rivers, lakes, regions, peaks] = sample_layers(&dir, Value::Null);
        let out = dir.join("out.bin");
        let err = run(&rivers, &lakes, &regions, &peaks, out.to_str().unwrap()).unwrap_err();
        assert!(err.contains("elevation"), "{err}");
    }

    #[test]
    fn hand_placed_labels_win() {
        let features = build(&temp_dir("featuregen-labelat")).unwrap();
        let malawi = features.iter().find(|f| f.name == "Lake Malawi").unwrap();
        let (x, y) = equal_earth(34.4, -11.5);
        assert_eq!((malawi.label_x, malawi.label_y), (x as f32, y as f32));
    }

    #[test]
    fn missing_files_are_reported() {
        let err = run("/nonexistent/a", "/b", "/c", "/d", "/e").unwrap_err();
        assert!(err.contains("/nonexistent/a"), "{err}");
    }
}
