//! Physical features shown when zoomed in (requirements §3.1): rivers,
//! lakes, deserts, mountain ranges and peaks. Built by `featuregen`
//! (src/bin/featuregen.rs) from Natural Earth and loaded from `Features.bin`.
//!
//! File format (little-endian):
//! ```text
//! "MMF1"  u32 version  u32 feature_count
//! per feature:
//!   u8 kind (0 river, 1 lake, 2 desert, 3 range, 4 peak)
//!   str name
//!   f32 min_zoom  f32 label_min_zoom        (MapCamera zoom units, ≥ 1)
//!   f32 label_x  f32 label_y  f32 label_angle (map coords; radians)
//!   i32 elevation_m (peaks; 0 otherwise)
//!   u32 part_count, per part: u32 point_count, point_count × (f32 x, f32 y)
//! str = u16 byte length + UTF-8
//! ```
//! Parts are polylines for rivers, rings for lakes/deserts/ranges (fill
//! even-odd), and a single point for peaks.

use super::world::MapError;

const MAGIC: &[u8; 4] = b"MMF1";
const VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FeatureKind {
    River,
    Lake,
    Desert,
    Range,
    Peak,
}

impl FeatureKind {
    fn code(self) -> u8 {
        match self {
            FeatureKind::River => 0,
            FeatureKind::Lake => 1,
            FeatureKind::Desert => 2,
            FeatureKind::Range => 3,
            FeatureKind::Peak => 4,
        }
    }

    fn from_code(code: u8) -> Option<Self> {
        Some(match code {
            0 => FeatureKind::River,
            1 => FeatureKind::Lake,
            2 => FeatureKind::Desert,
            3 => FeatureKind::Range,
            4 => FeatureKind::Peak,
            _ => return None,
        })
    }
}

/// One physical feature, ready to draw.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PhysicalFeature {
    pub kind: FeatureKind,
    pub name: String,
    /// Drawn from this camera zoom on (1 = whole world).
    pub min_zoom: f32,
    /// Labelled from this camera zoom on.
    pub label_min_zoom: f32,
    pub label_x: f32,
    pub label_y: f32,
    /// Text rotation in radians (rivers follow their course), in [-π/2, π/2].
    pub label_angle: f32,
    /// Peaks only; 0 for other kinds.
    pub elevation_m: i32,
    pub parts: Vec<Vec<f32>>,
}

/// Parses `Features.bin`.
#[uniffi::export]
pub fn load_features(bytes: Vec<u8>) -> Result<Vec<PhysicalFeature>, MapError> {
    decode(&bytes)
}

pub fn encode(features: &[PhysicalFeature]) -> Vec<u8> {
    let len32 = |n: usize| u32::try_from(n).expect("count too large for Features.bin");
    let mut out = Vec::new();
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&VERSION.to_le_bytes());
    out.extend_from_slice(&len32(features.len()).to_le_bytes());
    for f in features {
        out.push(f.kind.code());
        let name = f.name.as_bytes();
        out.extend_from_slice(
            &u16::try_from(name.len())
                .expect("name too long")
                .to_le_bytes(),
        );
        out.extend_from_slice(name);
        for v in [
            f.min_zoom,
            f.label_min_zoom,
            f.label_x,
            f.label_y,
            f.label_angle,
        ] {
            out.extend_from_slice(&v.to_le_bytes());
        }
        out.extend_from_slice(&f.elevation_m.to_le_bytes());
        out.extend_from_slice(&len32(f.parts.len()).to_le_bytes());
        for part in &f.parts {
            out.extend_from_slice(&len32(part.len() / 2).to_le_bytes());
            for v in part {
                out.extend_from_slice(&v.to_le_bytes());
            }
        }
    }
    out
}

fn bad(reason: String) -> MapError {
    MapError::BadFormat { reason }
}

pub fn decode(bytes: &[u8]) -> Result<Vec<PhysicalFeature>, MapError> {
    let mut pos = 0usize;
    let mut take = |n: usize| -> Result<&[u8], MapError> {
        let end = pos
            .checked_add(n)
            .filter(|&e| e <= bytes.len())
            .ok_or_else(|| bad("Features.bin ends early".into()))?;
        let slice = &bytes[pos..end];
        pos = end;
        Ok(slice)
    };
    if take(4)? != MAGIC {
        return Err(bad("Features.bin: wrong magic".into()));
    }
    let u32_of = |b: &[u8]| u32::from_le_bytes(b.try_into().unwrap());
    let f32_of = |b: &[u8]| f32::from_le_bytes(b.try_into().unwrap());
    let version = u32_of(take(4)?);
    if version != VERSION {
        return Err(bad(format!("Features.bin: unsupported version {version}")));
    }
    let count = u32_of(take(4)?) as usize;
    let mut features = Vec::with_capacity(count.min(10_000));
    for _ in 0..count {
        let kind_code = take(1)?[0];
        let kind = FeatureKind::from_code(kind_code)
            .ok_or_else(|| bad(format!("Features.bin: unknown kind {kind_code}")))?;
        let name_len = u16::from_le_bytes(take(2)?.try_into().unwrap()) as usize;
        let name = String::from_utf8(take(name_len)?.to_vec())
            .map_err(|_| bad("Features.bin: name is not UTF-8".into()))?;
        let mut floats = [0f32; 5];
        for v in &mut floats {
            *v = f32_of(take(4)?);
        }
        let elevation_m = i32::from_le_bytes(take(4)?.try_into().unwrap());
        let part_count = u32_of(take(4)?) as usize;
        let mut parts = Vec::with_capacity(part_count.min(10_000));
        for _ in 0..part_count {
            let points = u32_of(take(4)?) as usize;
            let raw = take(
                points
                    .checked_mul(8)
                    .ok_or_else(|| bad("part too large".into()))?,
            )?;
            parts.push(raw.chunks_exact(4).map(f32_of).collect::<Vec<f32>>());
        }
        let [min_zoom, label_min_zoom, label_x, label_y, label_angle] = floats;
        let feature = PhysicalFeature {
            kind,
            name,
            min_zoom,
            label_min_zoom,
            label_x,
            label_y,
            label_angle,
            elevation_m,
            parts,
        };
        if let Err(reason) = validate(&feature) {
            return Err(bad(format!("Features.bin: {:?} {reason}", feature.name)));
        }
        features.push(feature);
    }
    if pos != bytes.len() {
        return Err(bad("Features.bin: trailing bytes".into()));
    }
    Ok(features)
}

/// Checks one decoded feature: finite numbers, zooms that make sense, a
/// readable angle and geometry of the right shape for its kind.
fn validate(f: &PhysicalFeature) -> Result<(), &'static str> {
    let numbers = [
        f.min_zoom,
        f.label_min_zoom,
        f.label_x,
        f.label_y,
        f.label_angle,
    ];
    if !numbers
        .iter()
        .chain(f.parts.iter().flatten())
        .all(|v| v.is_finite())
    {
        return Err("has a non-finite number");
    }
    if f.min_zoom < 1.0 || f.label_min_zoom < f.min_zoom {
        return Err("has zooms out of order (need 1 ≤ min_zoom ≤ label_min_zoom)");
    }
    if f.label_angle.abs() > std::f32::consts::FRAC_PI_2 + 1e-4 {
        return Err("has an upside-down label angle");
    }
    let min_points = match f.kind {
        FeatureKind::Peak => {
            return match f.parts.as_slice() {
                [p] if p.len() == 2 => Ok(()),
                _ => Err("must be exactly one point"),
            };
        }
        FeatureKind::River => 2,
        FeatureKind::Lake | FeatureKind::Desert | FeatureKind::Range => 3,
    };
    if f.parts.is_empty() || f.parts.iter().any(|p| p.len() < 2 * min_points) {
        return Err("has a part with too few points");
    }
    Ok(())
}

// ---- label placement (used by featuregen) --------------------------------

/// Point halfway along the longest polyline, and the direction of the line
/// there (kept readable: never upside down).
pub fn polyline_label(parts: &[Vec<f32>]) -> Option<(f32, f32, f32)> {
    let length = |p: &Vec<f32>| -> f32 {
        p.chunks_exact(2)
            .zip(p.chunks_exact(2).skip(1))
            .map(|(a, b)| ((b[0] - a[0]).powi(2) + (b[1] - a[1]).powi(2)).sqrt())
            .sum()
    };
    let longest = parts
        .iter()
        .filter(|p| p.len() >= 4)
        .max_by(|a, b| length(a).total_cmp(&length(b)))?;
    let half = length(longest) / 2.0;
    let mut walked = 0.0;
    for (a, b) in longest.chunks_exact(2).zip(longest.chunks_exact(2).skip(1)) {
        let seg = ((b[0] - a[0]).powi(2) + (b[1] - a[1]).powi(2)).sqrt();
        if walked + seg >= half && seg > 0.0 {
            let t = (half - walked) / seg;
            // libm, not the platform's maths library: the generated file
            // must be byte-identical on every machine (CI compares it).
            let mut angle = libm::atan2f(b[1] - a[1], b[0] - a[0]);
            if angle > std::f32::consts::FRAC_PI_2 {
                angle -= std::f32::consts::PI;
            } else if angle < -std::f32::consts::FRAC_PI_2 {
                angle += std::f32::consts::PI;
            }
            return Some((a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]), angle));
        }
        walked += seg;
    }
    None
}

/// A point inside the shape to put its name on: the area-weighted centroid
/// of the largest ring when that lies inside the shape (blob-like regions),
/// otherwise the point deepest inside it (a "pole of inaccessibility", for
/// crescent or branching lakes like Balkhash and Tanganyika). Holes count.
///
/// Sums run in f64 relative to the ring's first vertex: in f32 on raw map
/// coordinates the cross terms (~1) swamp a small lake's area (~1e-6).
pub fn ring_label(rings: &[Vec<f32>]) -> Option<(f32, f32)> {
    let rings64: Vec<Vec<(f64, f64)>> = rings
        .iter()
        .filter(|r| r.len() >= 6)
        .map(|r| {
            r.chunks_exact(2)
                .map(|p| (f64::from(p[0]), f64::from(p[1])))
                .collect()
        })
        .collect();
    let ring = rings64
        .iter()
        .max_by(|a, b| signed_area(a).abs().total_cmp(&signed_area(b).abs()))?;
    let area = signed_area(ring);
    if area == 0.0 || !area.is_finite() {
        return None;
    }
    let (ox, oy) = ring[0];
    let (mut cx, mut cy) = (0.0, 0.0);
    for (i, &(x0, y0)) in ring.iter().enumerate() {
        let (x1, y1) = ring[(i + 1) % ring.len()];
        let (x0, y0, x1, y1) = (x0 - ox, y0 - oy, x1 - ox, y1 - oy);
        let cross = x0 * y1 - x1 * y0;
        cx += (x0 + x1) * cross;
        cy += (y0 + y1) * cross;
    }
    let centroid = (ox + cx / (6.0 * area), oy + cy / (6.0 * area));
    let point = if inside(&rings64, centroid) {
        centroid
    } else {
        deepest_point(&rings64, ring)
    };
    Some((point.0 as f32, point.1 as f32))
}

/// Shoelace area, relative to the first vertex for precision.
fn signed_area(ring: &[(f64, f64)]) -> f64 {
    let (ox, oy) = ring[0];
    (0..ring.len())
        .map(|i| {
            let (x0, y0) = ring[i];
            let (x1, y1) = ring[(i + 1) % ring.len()];
            (x0 - ox) * (y1 - oy) - (x1 - ox) * (y0 - oy)
        })
        .sum::<f64>()
        / 2.0
}

/// Even-odd point-in-polygon over all rings (so holes are outside).
fn inside(rings: &[Vec<(f64, f64)>], (px, py): (f64, f64)) -> bool {
    let mut hit = false;
    for ring in rings {
        for (i, &(x0, y0)) in ring.iter().enumerate() {
            let (x1, y1) = ring[(i + 1) % ring.len()];
            if (y0 > py) != (y1 > py) && px < x0 + (py - y0) * (x1 - x0) / (y1 - y0) {
                hit = !hit;
            }
        }
    }
    hit
}

/// Distance from a point to the nearest edge of any ring.
fn edge_distance(rings: &[Vec<(f64, f64)>], (px, py): (f64, f64)) -> f64 {
    let mut best = f64::INFINITY;
    for ring in rings {
        for (i, &(x0, y0)) in ring.iter().enumerate() {
            let (x1, y1) = ring[(i + 1) % ring.len()];
            let (dx, dy) = (x1 - x0, y1 - y0);
            let len2 = dx * dx + dy * dy;
            let t = if len2 == 0.0 {
                0.0
            } else {
                (((px - x0) * dx + (py - y0) * dy) / len2).clamp(0.0, 1.0)
            };
            let (ex, ey) = (px - x0 - t * dx, py - y0 - t * dy);
            best = best.min(ex * ex + ey * ey);
        }
    }
    best.sqrt()
}

/// Point inside the shape farthest from any edge, by a coarse grid over the
/// largest ring's bounds refined a few times around the best cell
/// (deterministic; precise enough for placing a label).
fn deepest_point(rings: &[Vec<(f64, f64)>], outer: &[(f64, f64)]) -> (f64, f64) {
    const GRID: usize = 24;
    let (mut x0, mut y0, mut x1, mut y1) = outer.iter().fold(
        (
            f64::INFINITY,
            f64::INFINITY,
            f64::NEG_INFINITY,
            f64::NEG_INFINITY,
        ),
        |(a, b, c, d), &(x, y)| (a.min(x), b.min(y), c.max(x), d.max(y)),
    );
    let mut best = (outer[0], -1.0);
    for _ in 0..6 {
        let (sx, sy) = ((x1 - x0) / GRID as f64, (y1 - y0) / GRID as f64);
        for i in 0..=GRID {
            for j in 0..=GRID {
                let p = (x0 + sx * i as f64, y0 + sy * j as f64);
                if inside(rings, p) {
                    let d = edge_distance(rings, p);
                    if d > best.1 {
                        best = (p, d);
                    }
                }
            }
        }
        // Zoom the grid in around the best point so far.
        let (bx, by) = best.0;
        (x0, x1, y0, y1) = (bx - 2.0 * sx, bx + 2.0 * sx, by - 2.0 * sy, by + 2.0 * sy);
    }
    best.0
}

/// Natural Earth's web-map zoom levels (0 = one 256 px tile for the world)
/// to MapCamera zoom (1 = the world fills the iPad, about web zoom 2).
pub fn camera_zoom_from_web(web_zoom: f64) -> f32 {
    libm::pow(2.0, web_zoom - 2.0).max(1.0) as f32
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn sample() -> Vec<PhysicalFeature> {
        vec![
            PhysicalFeature {
                kind: FeatureKind::River,
                name: "Long River".into(),
                min_zoom: 1.0,
                label_min_zoom: 2.0,
                label_x: 0.5,
                label_y: 0.0,
                label_angle: 0.0,
                elevation_m: 0,
                parts: vec![vec![0.0, 0.0, 1.0, 0.0]],
            },
            PhysicalFeature {
                kind: FeatureKind::Peak,
                name: "Tall Peak".into(),
                min_zoom: 4.0,
                label_min_zoom: 4.0,
                label_x: 1.0,
                label_y: 1.0,
                label_angle: 0.0,
                elevation_m: 8848,
                parts: vec![vec![1.0, 1.0]],
            },
        ]
    }

    #[test]
    fn round_trips() {
        assert_eq!(decode(&encode(&sample())).unwrap(), sample());
        assert_eq!(load_features(encode(&sample())).unwrap(), sample());
    }

    #[test]
    fn rejects_bad_files() {
        assert!(decode(b"MMW1").is_err());
        let mut bytes = encode(&sample());
        bytes.pop();
        assert!(decode(&bytes).is_err());
        let mut kind = encode(&sample());
        kind[12] = 9; // first feature's kind byte
        assert!(decode(&kind).is_err());
        let mut nan = sample();
        nan[0].parts[0][1] = f32::NAN;
        assert!(decode(&encode(&nan)).is_err());
        let mut empty = sample();
        empty[1].parts.clear();
        assert!(decode(&encode(&empty)).is_err());
    }

    #[test]
    fn polyline_label_is_halfway_along_and_readable() {
        // An L: 3 units east, then 1 unit north. Half of 4 = 2 → on the
        // first leg at x = 2, heading east.
        let (x, y, angle) = polyline_label(&[vec![0.0, 0.0, 3.0, 0.0, 3.0, -1.0]]).unwrap();
        assert_eq!((x, y), (2.0, 0.0));
        assert_eq!(angle, 0.0);
        // A westward line is turned around so text isn't upside down.
        let (_, _, angle) = polyline_label(&[vec![2.0, 0.0, 0.0, 0.0]]).unwrap();
        assert!(angle.abs() < 1e-6);
    }

    #[test]
    fn ring_label_is_the_centroid_of_the_largest_ring() {
        let small = vec![10.0, 10.0, 11.0, 10.0, 11.0, 11.0, 10.0, 11.0, 10.0, 10.0];
        let big = vec![0.0, 0.0, 4.0, 0.0, 4.0, 2.0, 0.0, 2.0, 0.0, 0.0];
        let (x, y) = ring_label(&[small, big]).unwrap();
        assert!((x - 2.0).abs() < 1e-5 && (y - 1.0).abs() < 1e-5);
    }

    #[test]
    fn ring_label_is_precise_for_tiny_lakes_far_from_the_origin() {
        // A 0.001-wide square at x ≈ 2.5 (area 1e-6): f32 sums on raw
        // coordinates would lose it.
        let (x0, y0, d) = (2.5f32, -1.1f32, 0.001f32);
        let lake = vec![x0, y0, x0 + d, y0, x0 + d, y0 + d, x0, y0 + d, x0, y0];
        let (x, y) = ring_label(&[lake]).unwrap();
        assert!((x - (x0 + d / 2.0)).abs() < d / 10.0, "{x}");
        assert!((y - (y0 + d / 2.0)).abs() < d / 10.0, "{y}");
    }

    #[test]
    fn ring_label_stays_inside_concave_shapes_and_out_of_holes() {
        // A C shape: the centroid falls in the gap, so the label must move
        // into one of the arms.
        let c = vec![
            0.0, 0.0, 3.0, 0.0, 3.0, 1.0, 1.0, 1.0, 1.0, 2.0, 3.0, 2.0, 3.0, 3.0, 0.0, 3.0, 0.0,
            0.0,
        ];
        let (x, y) = ring_label(std::slice::from_ref(&c)).unwrap();
        let rings: Vec<Vec<(f64, f64)>> = vec![
            c.chunks_exact(2)
                .map(|p| (f64::from(p[0]), f64::from(p[1])))
                .collect(),
        ];
        assert!(inside(&rings, (f64::from(x), f64::from(y))), "({x}, {y})");
        // A square with a square hole in the middle: not in the hole.
        let outer = vec![0.0, 0.0, 4.0, 0.0, 4.0, 4.0, 0.0, 4.0, 0.0, 0.0];
        let hole = vec![1.0, 1.0, 3.0, 1.0, 3.0, 3.0, 1.0, 3.0, 1.0, 1.0];
        let (x, y) = ring_label(&[outer, hole]).unwrap();
        assert!(
            !((1.0..=3.0).contains(&x) && (1.0..=3.0).contains(&y)),
            "({x}, {y})"
        );
    }

    #[test]
    fn rejects_features_that_make_no_sense() {
        let check = |edit: fn(&mut PhysicalFeature)| {
            let mut features = sample();
            edit(&mut features[0]);
            decode(&encode(&features)).is_err()
        };
        assert!(check(|f| f.min_zoom = 0.5));
        assert!(check(|f| f.label_min_zoom = 0.9));
        assert!(check(|f| f.label_angle = 3.0));
        assert!(check(|f| f.parts = vec![vec![0.0, 0.0]])); // 1-point river
        assert!(check(|f| f.parts.push(vec![]))); // empty part
        assert!(check(|f| {
            f.kind = FeatureKind::Lake; // 2-point ring
        }));
        assert!(check(|f| {
            f.kind = FeatureKind::Peak; // a peak must be one point
        }));
    }

    #[test]
    fn web_zoom_conversion() {
        assert_eq!(camera_zoom_from_web(0.0), 1.0);
        assert_eq!(camera_zoom_from_web(2.0), 1.0);
        assert_eq!(camera_zoom_from_web(3.0), 2.0);
        assert_eq!(camera_zoom_from_web(5.0), 8.0);
    }

    fn arb_feature() -> impl Strategy<Value = PhysicalFeature> {
        let point = (-3.0f32..3.0, -1.5f32..1.5);
        (
            0u8..5,
            "\\PC{0,24}",
            1.0f32..64.0,
            0.0f32..8.0,
            point.clone(),
            -1.5f32..1.5,
            0i32..9000,
            prop::collection::vec(prop::collection::vec(point, 3..12), 1..4),
        )
            .prop_map(
                |(kind, name, min_zoom, extra, (lx, ly), angle, elevation, parts)| {
                    let kind = FeatureKind::from_code(kind).unwrap();
                    let flat = |p: &Vec<(f32, f32)>| {
                        p.iter().flat_map(|&(x, y)| [x, y]).collect::<Vec<_>>()
                    };
                    let parts = if kind == FeatureKind::Peak {
                        vec![vec![lx, ly]]
                    } else {
                        parts.iter().map(flat).collect()
                    };
                    PhysicalFeature {
                        kind,
                        name,
                        min_zoom,
                        label_min_zoom: min_zoom + extra,
                        label_x: lx,
                        label_y: ly,
                        label_angle: angle,
                        elevation_m: elevation,
                        parts,
                    }
                },
            )
    }

    proptest! {
        #[test]
        fn any_valid_feature_list_round_trips(features in prop::collection::vec(arb_feature(), 0..8)) {
            prop_assert_eq!(decode(&encode(&features)).unwrap(), features);
        }
    }

    #[test]
    fn an_empty_list_round_trips() {
        assert_eq!(decode(&encode(&[])).unwrap(), vec![]);
    }

    #[test]
    fn a_file_cut_short_anywhere_is_an_error_not_a_panic() {
        let bytes = encode(&sample());
        for len in 0..bytes.len() {
            assert!(decode(&bytes[..len]).is_err(), "cut at {len}");
        }
    }

    #[test]
    fn wrong_version_is_rejected() {
        let mut bytes = encode(&sample());
        bytes[4] = 2;
        assert!(decode(&bytes).is_err());
    }

    #[test]
    fn names_must_be_utf8() {
        let mut bytes = encode(&sample());
        bytes[15] = 0xFF; // inside the first feature's name
        assert!(decode(&bytes).is_err());
    }

    #[test]
    fn steep_rivers_are_labelled_upright() {
        // Flowing straight down the screen, or down and to the left: the
        // text angle is turned to read left-to-right or bottom-to-top.
        for line in [
            vec![0.0, 0.0, 0.0, 1.0],
            vec![0.0, 1.0, 0.0, 0.0],
            vec![1.0, 0.0, 0.0, 1.0],
            vec![0.0, 0.0, -1.0, -0.1],
        ] {
            let (_, _, angle) = polyline_label(std::slice::from_ref(&line)).unwrap();
            assert!(
                angle.abs() <= std::f32::consts::FRAC_PI_2 + 1e-6,
                "{line:?}: {angle}"
            );
        }
    }

    #[test]
    fn multipart_rivers_are_labelled_on_their_longest_part() {
        let short = vec![10.0, 10.0, 10.5, 10.0];
        let long = vec![0.0, 0.0, 4.0, 0.0];
        let (x, y, _) = polyline_label(&[short, long]).unwrap();
        assert_eq!((x, y), (2.0, 0.0));
    }

    #[test]
    fn rivers_with_no_length_have_no_label() {
        assert_eq!(polyline_label(&[]), None);
        assert_eq!(polyline_label(&[vec![1.0, 1.0]]), None);
        assert_eq!(polyline_label(&[vec![1.0, 1.0, 1.0, 1.0]]), None);
    }

    #[test]
    fn shapes_with_no_area_have_no_label() {
        assert_eq!(ring_label(&[]), None);
        assert_eq!(ring_label(&[vec![0.0, 0.0, 1.0, 1.0]]), None); // too few points
        assert_eq!(
            ring_label(&[vec![0.0, 0.0, 1.0, 1.0, 2.0, 2.0, 0.0, 0.0]]),
            None
        ); // a line
    }

    #[test]
    fn web_zoom_conversion_is_monotonic_and_never_below_one() {
        assert_eq!(camera_zoom_from_web(-3.0), 1.0);
        let zooms: Vec<f32> = (0..=20)
            .map(|z| camera_zoom_from_web(f64::from(z) / 2.0))
            .collect();
        assert!(zooms.windows(2).all(|w| w[0] <= w[1]));
        assert_eq!(camera_zoom_from_web(8.0), 64.0);
    }
}
