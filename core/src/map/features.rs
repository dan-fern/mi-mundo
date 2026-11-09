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
        if !floats.iter().all(|v| v.is_finite())
            || feature.parts.iter().flatten().any(|v| !v.is_finite())
            || feature.parts.is_empty()
        {
            return Err(bad(format!(
                "Features.bin: {} has bad geometry",
                feature.name
            )));
        }
        features.push(feature);
    }
    if pos != bytes.len() {
        return Err(bad("Features.bin: trailing bytes".into()));
    }
    Ok(features)
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
            let mut angle = (b[1] - a[1]).atan2(b[0] - a[0]);
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

/// Area-weighted centroid of the largest ring (good enough for the rough,
/// blob-like Natural Earth region polygons and lakes).
pub fn ring_label(rings: &[Vec<f32>]) -> Option<(f32, f32)> {
    let signed_area = |r: &Vec<f32>| -> f32 {
        let n = r.len() / 2;
        (0..n)
            .map(|i| {
                let j = (i + 1) % n;
                r[2 * i] * r[2 * j + 1] - r[2 * j] * r[2 * i + 1]
            })
            .sum::<f32>()
            / 2.0
    };
    let ring = rings
        .iter()
        .filter(|r| r.len() >= 6)
        .max_by(|a, b| signed_area(a).abs().total_cmp(&signed_area(b).abs()))?;
    let area = signed_area(ring);
    if area.abs() < f32::EPSILON {
        return None;
    }
    let n = ring.len() / 2;
    let (mut cx, mut cy) = (0.0, 0.0);
    for i in 0..n {
        let j = (i + 1) % n;
        let cross = ring[2 * i] * ring[2 * j + 1] - ring[2 * j] * ring[2 * i + 1];
        cx += (ring[2 * i] + ring[2 * j]) * cross;
        cy += (ring[2 * i + 1] + ring[2 * j + 1]) * cross;
    }
    Some((cx / (6.0 * area), cy / (6.0 * area)))
}

/// Natural Earth's web-map zoom levels (0 = one 256 px tile for the world)
/// to MapCamera zoom (1 = the world fills the iPad, about web zoom 2).
pub fn camera_zoom_from_web(web_zoom: f64) -> f32 {
    2f64.powf(web_zoom - 2.0).max(1.0) as f32
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn web_zoom_conversion() {
        assert_eq!(camera_zoom_from_web(0.0), 1.0);
        assert_eq!(camera_zoom_from_web(2.0), 1.0);
        assert_eq!(camera_zoom_from_web(3.0), 2.0);
        assert_eq!(camera_zoom_from_web(5.0), 8.0);
    }
}
