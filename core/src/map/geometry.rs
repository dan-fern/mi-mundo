//! Small 2-D helpers for map rings (flattened `[x0, y0, x1, y1, …]`).

/// Axis-aligned bounding box.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Bounds {
    pub min_x: f32,
    pub min_y: f32,
    pub max_x: f32,
    pub max_y: f32,
}

impl Bounds {
    pub const EMPTY: Bounds = Bounds {
        min_x: f32::INFINITY,
        min_y: f32::INFINITY,
        max_x: f32::NEG_INFINITY,
        max_y: f32::NEG_INFINITY,
    };

    pub fn include_ring(&mut self, ring: &[f32]) {
        for p in ring.chunks_exact(2) {
            self.min_x = self.min_x.min(p[0]);
            self.max_x = self.max_x.max(p[0]);
            self.min_y = self.min_y.min(p[1]);
            self.max_y = self.max_y.max(p[1]);
        }
    }

    pub fn contains(&self, x: f32, y: f32) -> bool {
        x >= self.min_x && x <= self.max_x && y >= self.min_y && y <= self.max_y
    }

    pub fn area(&self) -> f32 {
        (self.max_x - self.min_x).max(0.0) * (self.max_y - self.min_y).max(0.0)
    }
}

/// Even-odd point-in-polygon test over all of a country's rings, so holes
/// (e.g. Lesotho inside South Africa) are handled without knowing which
/// ring is outer and which is a hole.
pub fn point_in_rings(rings: &[Vec<f32>], x: f32, y: f32) -> bool {
    let mut inside = false;
    for ring in rings {
        let n = ring.len() / 2;
        if n < 3 {
            continue;
        }
        let mut j = n - 1;
        for i in 0..n {
            let (xi, yi) = (ring[2 * i], ring[2 * i + 1]);
            let (xj, yj) = (ring[2 * j], ring[2 * j + 1]);
            if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi {
                inside = !inside;
            }
            j = i;
        }
    }
    inside
}

/// Douglas–Peucker simplification of a closed ring. Keeps the first/last
/// point, and never returns fewer than 4 points (a closed triangle) for a
/// ring that had at least that many.
pub fn simplify_ring(ring: &[f32], tolerance: f32) -> Vec<f32> {
    let n = ring.len() / 2;
    if n <= 4 {
        return ring.to_vec();
    }
    let mut keep = vec![false; n];
    keep[0] = true;
    keep[n - 1] = true;
    let mut stack = vec![(0usize, n - 1)];
    while let Some((start, end)) = stack.pop() {
        let (ax, ay) = (ring[2 * start], ring[2 * start + 1]);
        let (bx, by) = (ring[2 * end], ring[2 * end + 1]);
        let (mut max_dist, mut max_index) = (0.0f32, start);
        for i in start + 1..end {
            let d = perpendicular_distance(ring[2 * i], ring[2 * i + 1], ax, ay, bx, by);
            if d > max_dist {
                max_dist = d;
                max_index = i;
            }
        }
        if max_dist > tolerance {
            keep[max_index] = true;
            stack.push((start, max_index));
            stack.push((max_index, end));
        }
    }
    let kept: Vec<f32> = (0..n)
        .filter(|&i| keep[i])
        .flat_map(|i| [ring[2 * i], ring[2 * i + 1]])
        .collect();
    if kept.len() / 2 < 4 {
        ring.to_vec()
    } else {
        kept
    }
}

fn perpendicular_distance(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) -> f32 {
    let (dx, dy) = (bx - ax, by - ay);
    let len = (dx * dx + dy * dy).sqrt();
    if len == 0.0 {
        ((px - ax).powi(2) + (py - ay).powi(2)).sqrt()
    } else {
        ((px - ax) * dy - (py - ay) * dx).abs() / len
    }
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

    #[test]
    fn inside_and_outside_a_square() {
        let rings = vec![square(0.0, 0.0, 10.0)];
        assert!(point_in_rings(&rings, 5.0, 5.0));
        assert!(!point_in_rings(&rings, 15.0, 5.0));
        assert!(!point_in_rings(&rings, -1.0, 5.0));
    }

    #[test]
    fn holes_are_outside() {
        let rings = vec![square(0.0, 0.0, 10.0), square(4.0, 4.0, 2.0)];
        assert!(point_in_rings(&rings, 2.0, 2.0));
        assert!(!point_in_rings(&rings, 5.0, 5.0));
    }

    #[test]
    fn multiple_islands() {
        let rings = vec![square(0.0, 0.0, 1.0), square(5.0, 5.0, 1.0)];
        assert!(point_in_rings(&rings, 0.5, 0.5));
        assert!(point_in_rings(&rings, 5.5, 5.5));
        assert!(!point_in_rings(&rings, 3.0, 3.0));
    }

    #[test]
    fn simplify_drops_collinear_points_but_keeps_corners() {
        let ring = vec![
            0.0, 0.0, 5.0, 0.0, 10.0, 0.0, 10.0, 10.0, 0.0, 10.0, 0.0, 0.0,
        ];
        let simplified = simplify_ring(&ring, 0.01);
        assert_eq!(simplified.len() / 2, 5);
        assert!(!simplified.chunks_exact(2).any(|p| p == [5.0, 0.0]));
    }

    #[test]
    fn simplify_never_collapses_a_ring() {
        let ring = square(0.0, 0.0, 0.001);
        assert_eq!(simplify_ring(&ring, 1.0), ring);
    }

    #[test]
    fn bounds() {
        let mut b = Bounds::EMPTY;
        b.include_ring(&square(1.0, 2.0, 3.0));
        assert_eq!(
            b,
            Bounds {
                min_x: 1.0,
                min_y: 2.0,
                max_x: 4.0,
                max_y: 5.0
            }
        );
        assert!(b.contains(2.0, 3.0) && !b.contains(0.0, 0.0));
    }
}
