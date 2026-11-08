//! The bundled world map: country outlines at two levels of detail, plus
//! hit testing. Built by `mapgen` (src/bin/mapgen.rs) from Natural Earth and
//! loaded by the app from `World.bin`.
//!
//! File format (little-endian):
//! ```text
//! "MMW1"  u32 version  u32 country_count
//! per country:
//!   str id (ADM0_A3)  str iso2  str name  str continent
//!   u8 color_group (1–7, adjacent countries differ)
//!   f32 label_x  f32 label_y          (map coordinates)
//!   coarse rings, then fine rings:
//!     u32 ring_count, per ring: u32 point_count, point_count × (f32 x, f32 y)
//! str = u16 byte length + UTF-8
//! ```

use std::fmt;
use std::sync::Arc;

use super::geometry::{Bounds, point_in_rings};

const MAGIC: &[u8; 4] = b"MMW1";
const VERSION: u32 = 1;

/// One country as stored in the file. Rings are flattened x,y pairs in map
/// coordinates (see `projection`).
#[derive(Debug, Clone, PartialEq)]
pub struct CountryData {
    pub id: String,
    pub iso2: String,
    pub name: String,
    pub continent: String,
    pub color_group: u8,
    pub label: (f32, f32),
    pub coarse: Vec<Vec<f32>>,
    pub fine: Vec<Vec<f32>>,
}

/// Which outlines to draw: coarse when zoomed out, fine when zoomed in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Detail {
    Coarse,
    Fine,
}

/// What Swift needs to know about a country besides its outline.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CountryMeta {
    /// Position in `World::countries()`; shapes and hit tests refer to it.
    pub index: u32,
    /// Natural Earth ADM0_A3 code, e.g. "USA". Stable across data updates.
    pub id: String,
    /// ISO 3166-1 alpha-2, e.g. "US"; "-99" where none exists.
    pub iso2: String,
    pub name: String,
    pub continent: String,
    pub color_group: u8,
    pub label_x: f32,
    pub label_y: f32,
    pub min_x: f32,
    pub min_y: f32,
    pub max_x: f32,
    pub max_y: f32,
}

/// A country's outline: flattened x,y rings. Fill with the even-odd rule
/// so holes (enclaves, lakes) show through.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CountryShape {
    pub index: u32,
    pub rings: Vec<Vec<f32>>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Error)]
pub enum MapError {
    BadFormat { reason: String },
}

impl fmt::Display for MapError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MapError::BadFormat { reason } => write!(f, "World.bin is not valid: {reason}"),
        }
    }
}

impl std::error::Error for MapError {}

#[derive(uniffi::Object)]
pub struct World {
    countries: Vec<CountryData>,
    bounds: Vec<Bounds>,
}

#[uniffi::export]
impl World {
    /// Loads a world from the bytes of `World.bin`.
    #[uniffi::constructor]
    pub fn new(bytes: Vec<u8>) -> Result<Arc<Self>, MapError> {
        let countries = decode(&bytes)?;
        let bounds = countries
            .iter()
            .map(|c| {
                let mut b = Bounds::EMPTY;
                c.fine.iter().for_each(|r| b.include_ring(r));
                b
            })
            .collect();
        Ok(Arc::new(World { countries, bounds }))
    }

    pub fn countries(&self) -> Vec<CountryMeta> {
        self.countries
            .iter()
            .zip(&self.bounds)
            .enumerate()
            .map(|(i, (c, b))| CountryMeta {
                index: i as u32,
                id: c.id.clone(),
                iso2: c.iso2.clone(),
                name: c.name.clone(),
                continent: c.continent.clone(),
                color_group: c.color_group,
                label_x: c.label.0,
                label_y: c.label.1,
                min_x: b.min_x,
                min_y: b.min_y,
                max_x: b.max_x,
                max_y: b.max_y,
            })
            .collect()
    }

    /// Every country's outline at one level of detail, in index order.
    pub fn shapes(&self, detail: Detail) -> Vec<CountryShape> {
        self.countries
            .iter()
            .enumerate()
            .map(|(i, c)| CountryShape {
                index: i as u32,
                rings: match detail {
                    Detail::Coarse => c.coarse.clone(),
                    Detail::Fine => c.fine.clone(),
                },
            })
            .collect()
    }

    /// The country under a map point, using the fine outlines. If the point
    /// is in open sea, the nearest country within `tolerance` map units is
    /// returned instead, so tiny islands are still easy to tap.
    pub fn country_at(&self, x: f32, y: f32, tolerance: f32) -> Option<u32> {
        // Inside: prefer the smallest candidate, so an enclave wins over the
        // country around it even if the data overlaps slightly.
        let inside = self
            .countries
            .iter()
            .zip(&self.bounds)
            .enumerate()
            .filter(|(_, (c, b))| b.contains(x, y) && point_in_rings(&c.fine, x, y))
            .min_by(|(_, (_, a)), (_, (_, b))| a.area().total_cmp(&b.area()))
            .map(|(i, _)| i as u32);
        if inside.is_some() || tolerance <= 0.0 {
            return inside;
        }
        self.countries
            .iter()
            .zip(&self.bounds)
            .enumerate()
            .filter(|(_, (_, b))| {
                x >= b.min_x - tolerance
                    && x <= b.max_x + tolerance
                    && y >= b.min_y - tolerance
                    && y <= b.max_y + tolerance
            })
            .map(|(i, (c, _))| (i, distance_to_rings(&c.fine, x, y)))
            .filter(|&(_, d)| d <= tolerance)
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .map(|(i, _)| i as u32)
    }
}

fn distance_to_rings(rings: &[Vec<f32>], x: f32, y: f32) -> f32 {
    let mut best = f32::INFINITY;
    for ring in rings {
        for seg in ring.windows(4).step_by(2) {
            let (ax, ay, bx, by) = (seg[0], seg[1], seg[2], seg[3]);
            let (dx, dy) = (bx - ax, by - ay);
            let len2 = dx * dx + dy * dy;
            let t = if len2 == 0.0 {
                0.0
            } else {
                (((x - ax) * dx + (y - ay) * dy) / len2).clamp(0.0, 1.0)
            };
            let (px, py) = (ax + t * dx, ay + t * dy);
            best = best.min(((x - px).powi(2) + (y - py).powi(2)).sqrt());
        }
    }
    best
}

// ---- encoding ------------------------------------------------------------

pub fn encode(countries: &[CountryData]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&VERSION.to_le_bytes());
    out.extend_from_slice(&(countries.len() as u32).to_le_bytes());
    for c in countries {
        for s in [&c.id, &c.iso2, &c.name, &c.continent] {
            let bytes = s.as_bytes();
            out.extend_from_slice(&(bytes.len() as u16).to_le_bytes());
            out.extend_from_slice(bytes);
        }
        out.push(c.color_group);
        out.extend_from_slice(&c.label.0.to_le_bytes());
        out.extend_from_slice(&c.label.1.to_le_bytes());
        for rings in [&c.coarse, &c.fine] {
            out.extend_from_slice(&(rings.len() as u32).to_le_bytes());
            for ring in rings {
                out.extend_from_slice(&((ring.len() / 2) as u32).to_le_bytes());
                for v in ring {
                    out.extend_from_slice(&v.to_le_bytes());
                }
            }
        }
    }
    out
}

struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], MapError> {
        let end = self.pos.checked_add(n).filter(|&e| e <= self.bytes.len());
        let end = end.ok_or_else(|| bad("unexpected end of file"))?;
        let slice = &self.bytes[self.pos..end];
        self.pos = end;
        Ok(slice)
    }
    fn u8(&mut self) -> Result<u8, MapError> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> Result<u16, MapError> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }
    fn u32(&mut self) -> Result<u32, MapError> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn f32(&mut self) -> Result<f32, MapError> {
        Ok(f32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn string(&mut self) -> Result<String, MapError> {
        let len = self.u16()? as usize;
        String::from_utf8(self.take(len)?.to_vec()).map_err(|_| bad("string is not UTF-8"))
    }
    fn rings(&mut self) -> Result<Vec<Vec<f32>>, MapError> {
        let count = self.u32()? as usize;
        let mut rings = Vec::with_capacity(count.min(10_000));
        for _ in 0..count {
            let points = self.u32()? as usize;
            let raw = self.take(points.checked_mul(8).ok_or_else(|| bad("ring too large"))?)?;
            rings.push(
                raw.chunks_exact(4)
                    .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
                    .collect(),
            );
        }
        Ok(rings)
    }
}

fn bad(reason: &str) -> MapError {
    MapError::BadFormat {
        reason: reason.to_string(),
    }
}

pub fn decode(bytes: &[u8]) -> Result<Vec<CountryData>, MapError> {
    let mut r = Reader { bytes, pos: 0 };
    if r.take(4)? != MAGIC {
        return Err(bad("wrong magic"));
    }
    let version = r.u32()?;
    if version != VERSION {
        return Err(bad(&format!("unsupported version {version}")));
    }
    let count = r.u32()? as usize;
    let mut countries = Vec::with_capacity(count.min(1_000));
    for _ in 0..count {
        countries.push(CountryData {
            id: r.string()?,
            iso2: r.string()?,
            name: r.string()?,
            continent: r.string()?,
            color_group: r.u8()?,
            label: (r.f32()?, r.f32()?),
            coarse: r.rings()?,
            fine: r.rings()?,
        });
    }
    if r.pos != bytes.len() {
        return Err(bad("trailing bytes"));
    }
    Ok(countries)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn square(x0: f32, y0: f32, size: f32) -> Vec<f32> {
        vec![
            x0,
            y0,
            x0 + size,
            y0,
            x0 + size,
            y0 + size,
            x0,
            y0 + size,
            x0,
            y0,
        ]
    }

    fn sample() -> Vec<CountryData> {
        vec![
            CountryData {
                id: "BIG".into(),
                iso2: "BG".into(),
                name: "Bigland".into(),
                continent: "Europe".into(),
                color_group: 1,
                label: (5.0, 5.0),
                coarse: vec![square(0.0, 0.0, 10.0)],
                // A hole where Smallia sits.
                fine: vec![square(0.0, 0.0, 10.0), square(4.0, 4.0, 2.0)],
            },
            CountryData {
                id: "SML".into(),
                iso2: "SM".into(),
                name: "Smallia".into(),
                continent: "Europe".into(),
                color_group: 2,
                label: (5.0, 5.0),
                coarse: vec![square(4.0, 4.0, 2.0)],
                fine: vec![square(4.0, 4.0, 2.0)],
            },
            CountryData {
                id: "ISL".into(),
                iso2: "IS".into(),
                name: "Tiny Isle".into(),
                continent: "Oceania".into(),
                color_group: 3,
                label: (20.05, 20.05),
                coarse: vec![square(20.0, 20.0, 0.1)],
                fine: vec![square(20.0, 20.0, 0.1)],
            },
        ]
    }

    fn world() -> Arc<World> {
        World::new(encode(&sample())).unwrap()
    }

    #[test]
    fn round_trips() {
        assert_eq!(decode(&encode(&sample())).unwrap(), sample());
    }

    #[test]
    fn rejects_bad_files() {
        assert!(World::new(b"nope".to_vec()).is_err());
        let mut bytes = encode(&sample());
        bytes.truncate(bytes.len() - 3);
        assert!(World::new(bytes.clone()).is_err());
        bytes = encode(&sample());
        bytes.push(0);
        assert!(World::new(bytes).is_err());
        let mut wrong_version = encode(&sample());
        wrong_version[4] = 9;
        assert!(World::new(wrong_version).is_err());
    }

    #[test]
    fn hit_testing_respects_holes_and_enclaves() {
        let w = world();
        assert_eq!(w.country_at(1.0, 1.0, 0.0), Some(0));
        assert_eq!(w.country_at(5.0, 5.0, 0.0), Some(1));
        assert_eq!(w.country_at(50.0, 50.0, 0.0), None);
    }

    #[test]
    fn near_misses_snap_to_tiny_islands() {
        let w = world();
        assert_eq!(w.country_at(20.3, 20.05, 0.0), None);
        assert_eq!(w.country_at(20.3, 20.05, 0.5), Some(2));
        assert_eq!(w.country_at(25.0, 25.0, 0.5), None);
    }

    #[test]
    fn metadata_and_shapes() {
        let w = world();
        let meta = w.countries();
        assert_eq!(meta.len(), 3);
        assert_eq!(meta[1].name, "Smallia");
        assert_eq!((meta[0].min_x, meta[0].max_x), (0.0, 10.0));
        assert_eq!(w.shapes(Detail::Coarse)[0].rings.len(), 1);
        assert_eq!(w.shapes(Detail::Fine)[0].rings.len(), 2);
    }
}
