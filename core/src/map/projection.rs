//! Equal Earth projection (Šavrič, Patterson & Jenny, 2018).
//!
//! An equal-area pseudocylindrical projection: every country keeps its true
//! relative size, which matters when kids compare countries by eye.
//!
//! Map coordinates use **screen orientation**: x grows east, y grows *south*
//! (north is up on screen), in projection units. The whole world spans about
//! x ∈ [-2.7066, 2.7066] and y ∈ [-1.3173, 1.3173].

const A1: f64 = 1.340_264;
const A2: f64 = -0.081_106;
const A3: f64 = 0.000_893;
const A4: f64 = 0.003_796;

/// Projected point in map coordinates (see module docs).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct MapPoint {
    pub x: f32,
    pub y: f32,
}

/// Projects longitude/latitude in degrees to map coordinates.
pub fn equal_earth(lon_deg: f64, lat_deg: f64) -> (f64, f64) {
    let lambda = lon_deg.clamp(-180.0, 180.0).to_radians();
    let phi = lat_deg.clamp(-90.0, 90.0).to_radians();
    let m = 3f64.sqrt() / 2.0;
    let theta = (m * phi.sin()).asin();
    let t2 = theta * theta;
    let t6 = t2 * t2 * t2;
    let x = 2.0 * 3f64.sqrt() * lambda * theta.cos()
        / (3.0 * (9.0 * A4 * t6 * t2 + 7.0 * A3 * t6 + 3.0 * A2 * t2 + A1));
    let y = theta * (A1 + A2 * t2 + t6 * (A3 + A4 * t2));
    (x, -y) // screen orientation: north up means y decreases northward
}

/// Projects longitude/latitude (degrees) for Swift, e.g. to place a marker.
#[uniffi::export]
pub fn project(lon_deg: f64, lat_deg: f64) -> MapPoint {
    let (x, y) = equal_earth(lon_deg, lat_deg);
    MapPoint {
        x: x as f32,
        y: y as f32,
    }
}

/// Outline of the whole projected world (the edge of the "map paper"), as
/// flattened x,y pairs: east edge north→south, then west edge south→north.
#[uniffi::export]
pub fn world_outline() -> Vec<f32> {
    let steps = 90;
    let mut points = Vec::with_capacity((steps + 1) * 4);
    for i in 0..=steps {
        let lat = 90.0 - 180.0 * i as f64 / steps as f64;
        let (x, y) = equal_earth(180.0, lat);
        points.extend([x as f32, y as f32]);
    }
    for i in 0..=steps {
        let lat = -90.0 + 180.0 * i as f64 / steps as f64;
        let (x, y) = equal_earth(-180.0, lat);
        points.extend([x as f32, y as f32]);
    }
    points
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-4
    }

    #[test]
    fn origin_maps_to_origin() {
        let (x, y) = equal_earth(0.0, 0.0);
        assert!(close(x, 0.0) && close(y, 0.0));
    }

    #[test]
    fn known_extents() {
        // Published extents of Equal Earth on the unit sphere.
        let (x, _) = equal_earth(180.0, 0.0);
        assert!(close(x, 2.706_6), "x = {x}");
        let (_, y) = equal_earth(0.0, 90.0);
        assert!(close(y, -1.317_3), "y = {y}");
    }

    #[test]
    fn mid_latitude_reference_points() {
        // Reference values from the published formula (d3-geo equalEarthRaw),
        // y negated for screen orientation. These exercise A2–A4, which the
        // equator/pole checks don't.
        let (x, y) = equal_earth(180.0, 60.0);
        assert!(close(x, 2.039_060) && close(y, -1.088_301), "{x}, {y}");
        let (x, y) = equal_earth(90.0, 30.0);
        assert!(close(x, 1.265_851) && close(y, -0.592_935), "{x}, {y}");
    }

    #[test]
    fn north_is_up_and_east_is_right() {
        let (_, y_north) = equal_earth(0.0, 45.0);
        let (_, y_south) = equal_earth(0.0, -45.0);
        assert!(y_north < 0.0 && y_south > 0.0);
        let (x_east, _) = equal_earth(90.0, 0.0);
        assert!(x_east > 0.0);
    }

    #[test]
    fn symmetric() {
        let (x1, y1) = equal_earth(40.0, 30.0);
        let (x2, y2) = equal_earth(-40.0, -30.0);
        assert!(close(x1, -x2) && close(y1, -y2));
    }

    #[test]
    fn out_of_range_input_is_clamped() {
        assert_eq!(equal_earth(500.0, 200.0), equal_earth(180.0, 90.0));
    }

    #[test]
    fn outline_is_closed_shape_spanning_the_world() {
        let outline = world_outline();
        let xs: Vec<f32> = outline.iter().step_by(2).copied().collect();
        let max_x = xs.iter().cloned().fold(f32::MIN, f32::max);
        assert!((max_x - 2.7066).abs() < 1e-3);
        assert_eq!(outline.len() % 2, 0);
    }
}
