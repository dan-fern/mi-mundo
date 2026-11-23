//! Grading a freehand flag drawing (requirements §3.3, step 3): the kid
//! draws the whole flag on a blank canvas. The app shrinks the real flag
//! and the drawing to the same small grid of pixels; this module names each
//! pixel's paint-box colour and compares the two.
//!
//! Lenient on purpose (owner: "especially lenient on emblems and difficult
//! things to draw"):
//! - **Emblems and small details are never graded.** When the flag has an
//!   outline (FlagLayouts.json), every pixel where the real flag differs
//!   from its plain outline is detail, and is skipped along with its
//!   neighbours. Colours covering under [`MINOR_SHARE_PERCENT`] of the flag
//!   are skipped too (stars, thin stripes, fimbriations).
//! - **Placement is approximate.** A pixel counts if the drawing's colour
//!   is anywhere in the real flag's 3×3 neighbourhood there, so wobbly
//!   edges are fine.
//! - **Close shades count** (blue/light blue, red/maroon), as in the outline.
//! - Right means [`PASS_PERCENT`] of the graded pixels match, every main
//!   colour shows up in at least half of its own area, and no big patch of
//!   the drawing is a colour the flag doesn't have at all (a white cross on
//!   a flag with no white). Emblem colours count as the flag's, so drawing
//!   the emblem never hurts.
//!
//! A drawing that isn't right can still earn part of the points
//! ([`DrawCredit`], owner's rule): a mirror image (France drawn backwards,
//! or upside down) earns ¾, and one with all the flag's colours but in the
//! wrong places earns ½.

use crate::flags::{PALETTE, flag_colours_match};

/// Share of graded pixels that must match.
pub const PASS_PERCENT: u32 = 75;
/// Colours smaller than this share of the flag are details, not graded.
pub const MINOR_SHARE_PERCENT: u32 = 6;
/// A main colour must match in at least this share of its own area.
pub const COLOUR_PRESENT_PERCENT: u32 = 50;
/// "No colour" in a classified grid (transparent, nothing drawn).
pub const BLANK: u8 = 255;

/// Typical shades of each paint-box colour (same order as [`PALETTE`]),
/// used to name a pixel's colour. Matches tools/check-flag-layouts.py.
const SHADES: [&[(u8, u8, u8)]; 9] = [
    &[
        (206, 17, 38),
        (237, 41, 57),
        (218, 41, 28),
        (200, 16, 46),
        (239, 51, 64),
    ],
    &[(138, 21, 56), (158, 49, 54), (141, 27, 61)],
    &[
        (224, 82, 6),
        (255, 130, 0),
        (255, 153, 51),
        (242, 168, 0),
        (247, 127, 0),
    ],
    &[
        (252, 209, 22),
        (255, 206, 0),
        (254, 223, 0),
        (255, 221, 0),
        (255, 196, 0),
    ],
    &[
        (0, 140, 69),
        (0, 122, 61),
        (0, 155, 58),
        (0, 106, 78),
        (20, 181, 58),
        (0, 150, 57),
    ],
    &[
        (180, 215, 244),
        (24, 195, 223),
        (116, 172, 223),
        (106, 206, 255),
        (65, 137, 221),
        (0, 153, 204),
        (0, 173, 216),
    ],
    &[
        (45, 42, 74),
        (0, 56, 147),
        (0, 40, 104),
        (0, 87, 183),
        (0, 35, 149),
        (0, 47, 108),
        (0, 82, 147),
    ],
    &[(255, 255, 255), (245, 245, 245)],
    &[(0, 0, 0), (35, 31, 32)],
];

/// The nearest paint-box colour (index into [`PALETTE`]) of an RGB colour.
pub fn nearest_paint(r: u8, g: u8, b: u8) -> u8 {
    let dist = |(sr, sg, sb): (u8, u8, u8)| {
        let d = |a: u8, b: u8| (i32::from(a) - i32::from(b)).pow(2);
        d(r, sr) + d(g, sg) + d(b, sb)
    };
    let mut best = (0u8, i32::MAX);
    for (i, shades) in SHADES.iter().enumerate() {
        for shade in *shades {
            let d = dist(*shade);
            if d < best.1 {
                best = (i as u8, d);
            }
        }
    }
    best.0
}

/// Names each pixel of an RGBA buffer (4 bytes a pixel) by paint-box
/// colour index; mostly transparent pixels are [`BLANK`].
#[uniffi::export]
pub fn classify_pixels(rgba: Vec<u8>) -> Vec<u8> {
    rgba.chunks_exact(4)
        .map(|p| {
            if p[3] < 128 {
                BLANK
            } else {
                nearest_paint(p[0], p[1], p[2])
            }
        })
        .collect()
}

/// How much of a right answer a drawing earns.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DrawCredit {
    /// Right: full points.
    Full,
    /// Right if flipped left-to-right or upside down: ¾ of the points.
    Mirrored,
    /// Every main colour of the flag, in big enough patches, and no colour
    /// the flag doesn't have, but not in the right places: ½ of the points.
    Colours,
    /// Nothing.
    None,
}

/// The share of the points a [`DrawCredit`] earns, in percent.
#[uniffi::export]
pub fn draw_credit_percent(credit: DrawCredit) -> u32 {
    match credit {
        DrawCredit::Full => 100,
        DrawCredit::Mirrored => 75,
        DrawCredit::Colours => 50,
        DrawCredit::None => 0,
    }
}

/// A main colour counts as "there" for [`DrawCredit::Colours`] when the
/// drawing has at least this share of the flag's area of it. High enough
/// that a dab or two of each colour on a blank canvas isn't "all the
/// colours" (blank counts as white).
pub const COLOURS_CREDIT_SHARE_PERCENT: u32 = 60;

/// How a freehand drawing did.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FreehandGrade {
    /// Share of graded pixels that matched, 0–100.
    pub score_percent: u32,
    /// Main colours of the flag the drawing is missing (paint-box names).
    pub missing_colours: Vec<String>,
    /// Colours drawn over a big patch that the flag doesn't have at all.
    pub extra_colours: Vec<String>,
    /// Pixels that were graded and didn't match (for showing where).
    pub wrong_cells: Vec<bool>,
    /// Right: the same as `credit == DrawCredit::Full`.
    pub correct: bool,
    /// How much of a right answer it earns.
    pub credit: DrawCredit,
}

fn matches(a: u8, b: u8) -> bool {
    if a == BLANK || b == BLANK {
        return false;
    }
    a == b
        || flag_colours_match(
            PALETTE[a as usize].to_string(),
            PALETTE[b as usize].to_string(),
        )
}

/// Grades a drawing against the real flag, both classified
/// ([`classify_pixels`]) on the same `width`×`height` grid. A blank pixel
/// in the drawing counts as white (the canvas is white).
///
/// `outline` is the flag's plain outline (regions in their colours, no
/// emblem) on the same grid, or empty if the flag has none: pixels where
/// the real flag differs from it are emblem or detail and aren't graded.
#[uniffi::export]
pub fn grade_freehand(
    reference: Vec<u8>,
    drawing: Vec<u8>,
    outline: Vec<u8>,
    width: u32,
    height: u32,
) -> FreehandGrade {
    let (w, h) = (width as usize, height as usize);
    // Called from the app: never panic. Sizes that don't fit the buffers
    // fail without allocating for them, and a value that isn't a paint-box
    // colour counts as blank.
    if w.checked_mul(h) != Some(reference.len()) {
        return failed(0);
    }
    let clean = |cells: Vec<u8>| -> Vec<u8> {
        cells
            .into_iter()
            .map(|c| {
                if (c as usize) < PALETTE.len() {
                    c
                } else {
                    BLANK
                }
            })
            .collect()
    };
    let (reference, drawing, outline) = (clean(reference), clean(drawing), clean(outline));
    let mut grade = grade_as_drawn(&reference, &drawing, &outline, w, h);
    if grade.correct || drawing.len() != w * h || reference.len() != w * h {
        return grade;
    }
    let flipped = |flip: fn(usize, usize, usize, usize) -> usize| -> Vec<u8> {
        (0..w * h)
            .map(|i| drawing[flip(i % w, i / w, w, h)])
            .collect()
    };
    let left_right = flipped(|x, y, w, _| y * w + (w - 1 - x));
    let upside_down = flipped(|x, y, w, h| (h - 1 - y) * w + x);
    grade.credit = if grade_as_drawn(&reference, &left_right, &outline, w, h).correct
        || grade_as_drawn(&reference, &upside_down, &outline, w, h).correct
    {
        DrawCredit::Mirrored
    } else if has_the_colours(&reference, &drawing, &grade) {
        DrawCredit::Colours
    } else {
        DrawCredit::None
    };
    grade
}

/// Every main colour of the flag (one big enough to be graded) is drawn
/// over at least [`COLOURS_CREDIT_SHARE_PERCENT`] of its own area,
/// anywhere, and nothing big is drawn in a colour the flag doesn't have.
fn has_the_colours(reference: &[u8], drawing: &[u8], grade: &FreehandGrade) -> bool {
    if !grade.extra_colours.is_empty() || drawing.iter().all(|&c| c == BLANK) {
        return false;
    }
    let white = PALETTE.iter().position(|c| *c == "white").unwrap() as u8;
    let area = colour_areas(reference);
    let mut drawn = [0usize; 9];
    for &d in drawing {
        let d = if d == BLANK { white } else { d };
        if (d as usize) < drawn.len() {
            drawn[d as usize] += 1;
        }
    }
    let main = main_colours(reference);
    // A flag with no main colour (bad input) has no colours to get right.
    !main.is_empty()
        && main.iter().all(|&c| {
            let have: usize = (0..9u8)
                .filter(|&d| matches(c, d))
                .map(|d| drawn[d as usize])
                .sum();
            have * 100 >= area[c as usize] * COLOURS_CREDIT_SHARE_PERCENT as usize
        })
}

/// How many cells of the grid are each paint-box colour.
fn colour_areas(cells: &[u8]) -> [usize; 9] {
    let mut area = [0usize; 9];
    for &c in cells {
        if (c as usize) < area.len() {
            area[c as usize] += 1;
        }
    }
    area
}

/// The flag's main colours (palette indices, in palette order): each
/// covers at least [`MINOR_SHARE_PERCENT`] of it, so it's graded.
fn main_colours(reference: &[u8]) -> Vec<u8> {
    let area = colour_areas(reference);
    (0..9u8)
        .filter(|&c| {
            let a = area[c as usize];
            a > 0 && a * 100 >= reference.len() * MINOR_SHARE_PERCENT as usize
        })
        .collect()
}

/// The colour hint on the drawing pad: the flag's main colours (paint-box
/// names, in paint-box order), the ones the grader marks. `reference` is
/// the real flag, classified ([`classify_pixels`]). Emblem and other
/// small details aren't marked, so they aren't given away either.
#[uniffi::export]
pub fn flag_main_colours(reference: Vec<u8>) -> Vec<String> {
    main_colours(&reference)
        .into_iter()
        .map(|c| PALETTE[c as usize].to_string())
        .collect()
}

/// Not right, with `n` unmarked cells.
fn failed(n: usize) -> FreehandGrade {
    FreehandGrade {
        score_percent: 0,
        missing_colours: Vec::new(),
        extra_colours: Vec::new(),
        wrong_cells: vec![false; n],
        correct: false,
        credit: DrawCredit::None,
    }
}

/// Grades the drawing as it is (no flipping).
fn grade_as_drawn(
    reference: &[u8],
    drawing: &[u8],
    outline: &[u8],
    w: usize,
    h: usize,
) -> FreehandGrade {
    let n = w * h;
    let fail = failed;
    if n == 0
        || reference.len() != n
        || drawing.len() != n
        || (!outline.is_empty() && outline.len() != n)
    {
        return fail(0);
    }
    // Nothing drawn at all is never right.
    if drawing.iter().all(|&c| c == BLANK) {
        return fail(n);
    }
    let white = PALETTE.iter().position(|c| *c == "white").unwrap() as u8;
    let drawn = |i: usize| {
        if drawing[i] == BLANK {
            white
        } else {
            drawing[i]
        }
    };
    let neighbours = |i: usize| {
        let (x, y) = ((i % w) as isize, (i / w) as isize);
        (-1..=1)
            .flat_map(move |dy| (-1..=1).map(move |dx| (x + dx, y + dy)))
            .filter(move |&(nx, ny)| nx >= 0 && ny >= 0 && (nx as usize) < w && (ny as usize) < h)
            .map(move |(nx, ny)| ny as usize * w + nx as usize)
    };

    // Detail: where the real flag isn't its plain outline, and around it.
    let mut skip = vec![false; n];
    if !outline.is_empty() {
        for i in 0..n {
            if !matches(reference[i], outline[i]) {
                for j in neighbours(i) {
                    skip[j] = true;
                }
            }
        }
    }
    // The emblem area: anything drawn there is fine.
    let emblem = skip.clone();
    // Small colours are details too.
    let area = colour_areas(reference);
    let minor = |c: u8| {
        (c as usize) >= area.len() || area[c as usize] * 100 < n * MINOR_SHARE_PERCENT as usize
    };
    for i in 0..n {
        if minor(reference[i]) {
            skip[i] = true;
        }
    }

    let mut graded = 0usize;
    let mut matched = 0usize;
    let mut per_colour = [(0usize, 0usize); 9]; // (graded, matched)
    let mut wrong_cells = vec![false; n];
    for i in 0..n {
        if skip[i] {
            continue;
        }
        graded += 1;
        let c = reference[i] as usize;
        per_colour[c].0 += 1;
        if neighbours(i).any(|j| matches(reference[j], drawn(i))) {
            matched += 1;
            per_colour[c].1 += 1;
        } else {
            wrong_cells[i] = true;
        }
    }
    if graded == 0 {
        return fail(n);
    }
    let score_percent = (matched * 100 / graded) as u32;
    let missing_colours: Vec<String> = per_colour
        .iter()
        .enumerate()
        .filter(|(_, (g, m))| *g > 0 && m * 100 < g * COLOUR_PRESENT_PERCENT as usize)
        .map(|(i, _)| PALETTE[i].to_string())
        .collect();
    // Big patches, outside the emblem, of a colour the flag has nowhere.
    let mut drawn_area = [0usize; 9];
    for i in (0..n).filter(|&i| !emblem[i]) {
        drawn_area[drawn(i) as usize] += 1;
    }
    let extra_colours: Vec<String> = (0..9u8)
        .filter(|&c| drawn_area[c as usize] * 100 >= n * MINOR_SHARE_PERCENT as usize)
        .filter(|&c| !reference.iter().any(|&r| matches(r, c)))
        .map(|c| PALETTE[c as usize].to_string())
        .collect();
    let correct =
        score_percent >= PASS_PERCENT && missing_colours.is_empty() && extra_colours.is_empty();
    FreehandGrade {
        correct,
        credit: if correct {
            DrawCredit::Full
        } else {
            DrawCredit::None
        },
        score_percent,
        missing_colours,
        extra_colours,
        wrong_cells,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    const W: usize = 48;
    const H: usize = 36;

    /// Untouched canvas, in `grid`.
    const BLANK_NAME: &str = "blank";

    fn idx(name: &str) -> u8 {
        if name == BLANK_NAME {
            return BLANK;
        }
        PALETTE.iter().position(|c| *c == name).unwrap() as u8
    }

    /// A grid painted by a function of (x, y) in 0..1.
    fn grid(f: impl Fn(f32, f32) -> &'static str) -> Vec<u8> {
        (0..W * H)
            .map(|i| idx(f((i % W) as f32 / W as f32, (i / W) as f32 / H as f32)))
            .collect()
    }

    fn france(x: f32, _: f32) -> &'static str {
        if x < 1.0 / 3.0 {
            "blue"
        } else if x < 2.0 / 3.0 {
            "white"
        } else {
            "red"
        }
    }

    fn grade(reference: &[u8], drawing: &[u8], outline: &[u8]) -> FreehandGrade {
        grade_freehand(
            reference.to_vec(),
            drawing.to_vec(),
            outline.to_vec(),
            W as u32,
            H as u32,
        )
    }

    #[test]
    fn a_perfect_copy_is_right() {
        let f = grid(france);
        let g = grade(&f, &f, &[]);
        assert!(g.correct);
        assert_eq!(g.score_percent, 100);
    }

    #[test]
    fn wobbly_edges_are_fine() {
        let f = grid(france);
        // Stripes a few percent off where they should be.
        let d = grid(|x, y| france(x + 0.04 * (y * 9.0).sin(), y));
        assert!(grade(&f, &d, &[]).correct);
    }

    #[test]
    fn white_left_blank_counts_as_white() {
        let f = grid(france);
        let d: Vec<u8> = f
            .iter()
            .map(|&c| if c == idx("white") { BLANK } else { c })
            .collect();
        assert!(grade(&f, &d, &[]).correct);
    }

    #[test]
    fn the_stripes_the_wrong_way_round_are_wrong() {
        let f = grid(france);
        let d = grid(|x, y| france(1.0 - x, y));
        let g = grade(&f, &d, &[]);
        assert!(!g.correct);
        assert!(g.score_percent < 50);
    }

    #[test]
    fn a_missing_stripe_is_named() {
        let f = grid(france);
        let d = grid(|x, y| if x < 1.0 / 3.0 { "red" } else { france(x, y) });
        let g = grade(&f, &d, &[]);
        assert!(!g.correct);
        assert_eq!(g.missing_colours, vec!["blue".to_string()]);
    }

    #[test]
    fn a_big_patch_of_a_colour_the_flag_lacks_is_wrong() {
        // Denmark (red, white cross) drawn for a plain red flag.
        let red = grid(|_, _| "red");
        let denmark = grid(|x, y| {
            if (x - 0.36).abs() < 0.06 || (y - 0.5).abs() < 0.08 {
                "white"
            } else {
                "red"
            }
        });
        let g = grade(&red, &denmark, &[]);
        assert!(!g.correct);
        assert_eq!(g.extra_colours, vec!["white".to_string()]);
    }

    #[test]
    fn drawing_the_emblem_in_its_own_colours_never_hurts() {
        let plain = |_: f32, _: f32| "red";
        let with_star = grid(|x, y| {
            if (x - 0.5).abs() < 0.1 && (y - 0.5).abs() < 0.12 {
                "yellow"
            } else {
                plain(x, y)
            }
        });
        let outline = grid(plain);
        // A star drawn bigger than the real one.
        let big_star = grid(|x, y| {
            if (x - 0.5).abs() < 0.2 && (y - 0.5).abs() < 0.22 {
                "yellow"
            } else {
                plain(x, y)
            }
        });
        assert!(grade(&with_star, &big_star, &outline).correct);
    }

    /// Nine alternating blue/white stripes, blue first (Greece's, without
    /// the canton).
    fn stripes9(_: f32, y: f32) -> &'static str {
        if (y * 9.0) as usize % 2 == 0 {
            "blue"
        } else {
            "white"
        }
    }

    #[test]
    fn thin_stripes_drawn_as_two_big_ones_are_wrong() {
        let f = grid(stripes9);
        let d = grid(|_, y| if y < 0.5 { "blue" } else { "white" });
        let g = grade(&f, &d, &[]);
        assert!(!g.correct, "{g:?}");
    }

    #[test]
    fn thin_stripes_copied_or_a_bit_off_are_right() {
        let f = grid(stripes9);
        assert!(grade(&f, &f, &[]).correct);
        let d = grid(|x, y| stripes9(x, y + 0.02 * (x * 9.0).sin()));
        assert!(grade(&f, &d, &[]).correct);
    }

    #[test]
    fn five_stripes_drawn_as_two_is_wrong() {
        // Thailand/Costa Rica style: red, white, blue(wide), white, red.
        let f = grid(|_, y| match (y * 6.0) as usize {
            0 | 5 => "red",
            1 | 4 => "white",
            _ => "blue",
        });
        let d = grid(|_, y| if y < 0.5 { "red" } else { "blue" });
        assert!(!grade(&f, &d, &[]).correct);
    }

    fn credit(reference: &[u8], drawing: &[u8]) -> DrawCredit {
        grade_freehand(
            reference.to_vec(),
            drawing.to_vec(),
            vec![],
            W as u32,
            H as u32,
        )
        .credit
    }

    #[test]
    fn a_right_drawing_earns_full_credit() {
        let f = grid(france);
        assert_eq!(credit(&f, &f), DrawCredit::Full);
        assert_eq!(draw_credit_percent(DrawCredit::Full), 100);
    }

    #[test]
    fn france_drawn_backwards_is_a_mirror_image() {
        let f = grid(france);
        let backwards = grid(|x, y| france(1.0 - x, y));
        let g = grade_freehand(f.clone(), backwards, vec![], W as u32, H as u32);
        assert!(!g.correct);
        assert_eq!(g.credit, DrawCredit::Mirrored);
        assert_eq!(draw_credit_percent(g.credit), 75);
    }

    #[test]
    fn a_flag_drawn_upside_down_is_a_mirror_image() {
        // Red over white (Indonesia/Monaco style) drawn white over red.
        let f = grid(|_, y| if y < 0.5 { "red" } else { "white" });
        let d = grid(|_, y| if y < 0.5 { "white" } else { "red" });
        assert_eq!(credit(&f, &d), DrawCredit::Mirrored);
    }

    #[test]
    fn all_the_colours_in_the_wrong_places_earn_half() {
        // France's colours as horizontal stripes.
        let f = grid(france);
        let d = grid(|_, y| france(y, 0.0));
        let g = grade_freehand(f, d, vec![], W as u32, H as u32);
        assert!(!g.correct);
        assert_eq!(g.credit, DrawCredit::Colours);
        assert_eq!(draw_credit_percent(g.credit), 50);
    }

    #[test]
    fn a_missing_or_extra_colour_earns_nothing() {
        let f = grid(france);
        // No red.
        let two = grid(|x, _| if x < 0.5 { "blue" } else { "white" });
        assert_eq!(credit(&f, &two), DrawCredit::None);
        // Green, which France doesn't have, over a big patch.
        let green = grid(|x, y| if y < 0.3 { "green" } else { france(y, x) });
        assert_eq!(credit(&f, &green), DrawCredit::None);
        // A dab of each colour isn't "all the colours".
        let dabs = grid(|x, y| match (x < 0.1 && y < 0.1, x > 0.9 && y > 0.9) {
            (true, _) => "blue",
            (_, true) => "red",
            _ => "white",
        });
        assert_eq!(credit(&f, &dabs), DrawCredit::None);
        assert_eq!(credit(&f, &vec![BLANK; W * H]), DrawCredit::None);
        assert_eq!(draw_credit_percent(DrawCredit::None), 0);
    }

    #[test]
    fn two_blobs_on_a_blank_canvas_are_not_all_the_colours() {
        // Review: blank counts as white, so a blue and a red patch at the
        // edges used to earn half for France.
        let f = grid(france);
        let blobs = grid(|x, y| {
            if x < 0.19 && y < 0.25 {
                "blue"
            } else if x > 0.81 && y > 0.75 {
                "red"
            } else {
                BLANK_NAME
            }
        });
        assert_eq!(credit(&f, &blobs), DrawCredit::None);
        // Japan: one small red scribble on blank isn't half either.
        let japan = grid(|x, y| {
            if (x - 0.5).powi(2) + (y - 0.5).powi(2) < 0.09 {
                "red"
            } else {
                "white"
            }
        });
        let scribble = grid(|x, y| {
            if x < 0.15 && y < 0.15 {
                "red"
            } else {
                BLANK_NAME
            }
        });
        assert_eq!(credit(&japan, &scribble), DrawCredit::None);
    }

    #[test]
    fn a_mirror_image_of_a_flag_with_an_emblem_still_counts() {
        // France with an emblem near the top of the hoist (not graded): the
        // plain flag drawn backwards is still a mirror image.
        let emblem = |x: f32, y: f32| x < 0.2 && y < 0.25;
        let real = grid(|x, y| if emblem(x, y) { "yellow" } else { france(x, y) });
        let outline = grid(france);
        let backwards = grid(|x, y| france(1.0 - x, y));
        let g = grade_freehand(real, backwards, outline, W as u32, H as u32);
        assert_eq!(g.credit, DrawCredit::Mirrored, "{g:?}");
    }

    #[test]
    fn the_colour_hint_names_the_main_colours_only() {
        // France with a small yellow detail: the hint is the three bands.
        let detail = |x: f32, y: f32| x > 0.45 && x < 0.5 && y < 0.1;
        let flag = grid(|x, y| if detail(x, y) { "yellow" } else { france(x, y) });
        assert_eq!(
            flag_main_colours(flag),
            ["red", "blue", "white"].map(String::from)
        );
        assert!(flag_main_colours(Vec::new()).is_empty());
        assert!(flag_main_colours(vec![BLANK; 12]).is_empty());
    }

    #[test]
    fn bad_input_from_the_app_never_panics() {
        let f = grid(france);
        // Values that aren't paint-box colours count as blank.
        let junk = vec![9u8; W * H];
        assert_eq!(credit(&f, &junk), DrawCredit::None);
        assert_eq!(credit(&vec![200u8; W * H], &f), DrawCredit::None);
        // Sizes that don't fit the buffers fail without a huge allocation.
        let g = grade_freehand(f.clone(), f.clone(), vec![], u32::MAX, u32::MAX);
        assert!(!g.correct && g.wrong_cells.is_empty());
        let g = grade_freehand(f.clone(), vec![0; 3], vec![], W as u32, H as u32);
        assert!(!g.correct && g.wrong_cells.is_empty());
    }

    #[test]
    fn nothing_drawn_is_wrong() {
        let f = grid(france);
        assert!(!grade(&f, &vec![BLANK; W * H], &[]).correct);
    }

    #[test]
    fn close_shades_count() {
        let f = grid(france);
        let d = grid(|x, y| match france(x, y) {
            "blue" => "lightblue",
            "red" => "maroon",
            c => c,
        });
        assert!(grade(&f, &d, &[]).correct);
    }

    #[test]
    fn the_emblem_is_never_graded() {
        // Mexico-like: green, white, red, with a big brown-ish (black here)
        // emblem in the middle that the kid leaves out entirely.
        let mexico = |x: f32, _y: f32| {
            if x < 1.0 / 3.0 {
                "green"
            } else if x < 2.0 / 3.0 {
                "white"
            } else {
                "red"
            }
        };
        let with_emblem = grid(|x, y| {
            if (x - 0.5).abs() < 0.12 && (y - 0.5).abs() < 0.2 {
                "black"
            } else {
                mexico(x, y)
            }
        });
        let outline = grid(mexico);
        let plain_drawing = grid(mexico);
        let g = grade(&with_emblem, &plain_drawing, &outline);
        assert!(g.correct, "{g:?}");
        assert_eq!(g.score_percent, 100);
        // A scribbled emblem doesn't hurt either.
        let scribbled = grid(|x, y| {
            if (x - 0.5).abs() < 0.15 && (y - 0.45).abs() < 0.25 {
                "yellow"
            } else {
                mexico(x, y)
            }
        });
        assert!(grade(&with_emblem, &scribbled, &outline).correct);
    }

    #[test]
    fn small_details_are_skipped_without_an_outline() {
        // Stars covering ~3% of the flag, left out of the drawing.
        let plain = |_: f32, _: f32| "blue";
        let starred = grid(|x, y| {
            if ((x * 10.0) as i32 + (y * 10.0) as i32) % 9 == 0 && x < 0.3 && y < 0.5 {
                "white"
            } else {
                plain(x, y)
            }
        });
        let g = grade(&starred, &grid(plain), &[]);
        assert!(g.correct, "{g:?}");
    }

    #[test]
    fn mismatched_sizes_are_wrong_not_a_crash() {
        let f = grid(france);
        let g = grade_freehand(f.clone(), f[..10].to_vec(), Vec::new(), W as u32, H as u32);
        assert!(!g.correct);
        let g = grade_freehand(Vec::new(), Vec::new(), Vec::new(), 0, 0);
        assert!(!g.correct);
    }

    #[test]
    fn nearest_paint_names_flag_colours() {
        assert_eq!(PALETTE[nearest_paint(255, 255, 255) as usize], "white");
        assert_eq!(PALETTE[nearest_paint(10, 10, 10) as usize], "black");
        assert_eq!(PALETTE[nearest_paint(0, 87, 183) as usize], "blue");
        assert_eq!(PALETTE[nearest_paint(255, 213, 0) as usize], "yellow");
        assert_eq!(PALETTE[nearest_paint(0, 147, 68) as usize], "green");
        assert_eq!(PALETTE[nearest_paint(255, 136, 62) as usize], "orange");
        assert_eq!(PALETTE[nearest_paint(200, 16, 46) as usize], "red");
    }

    #[test]
    fn classify_pixels_reads_rgba_and_blank() {
        let px = vec![255, 255, 255, 255, 0, 0, 0, 255, 9, 9, 9, 0];
        assert_eq!(classify_pixels(px), vec![idx("white"), idx("black"), BLANK]);
    }

    // ---- Thresholds, exactly at the line -------------------------------

    /// A grid from a function of the cell (x, y).
    fn cells(f: impl Fn(usize, usize) -> u8) -> Vec<u8> {
        (0..W * H).map(|i| f(i % W, i / W)).collect()
    }

    /// Red over the top 27 rows (1296 cells), blue under (432 cells).
    fn red_over_blue() -> Vec<u8> {
        cells(|_, y| if y < 27 { idx("red") } else { idx("blue") })
    }

    /// `red_over_blue` with its first `k` cells (raster order) repainted.
    /// Cells in rows 0..26 have no blue neighbour, so blue there never
    /// matches.
    fn with_first_cells(base: &[u8], k: usize, colour: &str) -> Vec<u8> {
        let mut d = base.to_vec();
        for c in d.iter_mut().take(k) {
            *c = idx(colour);
        }
        d
    }

    #[test]
    fn seventy_five_percent_matched_passes_and_one_cell_less_does_not() {
        // 1728 graded cells: 432 wrong is exactly 75%.
        let r = red_over_blue();
        let at = grade(&r, &with_first_cells(&r, 432, "blue"), &[]);
        assert_eq!(at.score_percent, PASS_PERCENT);
        assert!(at.correct, "{at:?}");
        let below = grade(&r, &with_first_cells(&r, 433, "blue"), &[]);
        assert_eq!(below.score_percent, PASS_PERCENT - 1);
        assert!(below.missing_colours.is_empty() && below.extra_colours.is_empty());
        assert!(!below.correct, "{below:?}");
    }

    #[test]
    fn a_colour_half_there_is_present_and_one_cell_less_is_missing() {
        // Blue's 432 cells: rows 29.. (336 cells) have no red neighbour.
        let r = red_over_blue();
        let repaint = |k: usize| {
            let mut d = r.clone();
            for c in d.iter_mut().skip(29 * W).take(k) {
                *c = idx("red");
            }
            d
        };
        let half = grade(&r, &repaint(216), &[]);
        assert!(half.missing_colours.is_empty(), "{half:?}");
        assert!(half.correct);
        let less = grade(&r, &repaint(217), &[]);
        assert_eq!(less.missing_colours, ["blue"]);
        assert!(!less.correct);
    }

    #[test]
    fn a_colour_on_six_percent_of_the_flag_is_main_and_less_is_detail() {
        // 6% of 1728 cells is 103.68.
        let r = cells(|_, _| idx("red"));
        assert_eq!(
            flag_main_colours(with_first_cells(&r, 104, "blue")),
            ["red", "blue"]
        );
        assert_eq!(
            flag_main_colours(with_first_cells(&r, 103, "blue")),
            ["red"]
        );
        // Detail isn't graded: all red is right with 103 blue cells.
        let all_red = r.clone();
        assert!(grade(&with_first_cells(&r, 103, "blue"), &all_red, &[]).correct);
    }

    #[test]
    fn colours_credit_needs_sixty_percent_of_each_colour() {
        // Red over blue, 864 cells each; drawn as red then blue down the
        // columns (side by side, so not right and not a mirror image).
        let flag = cells(|_, y| if y < H / 2 { idx("red") } else { idx("blue") });
        let drawn = |red_cells: usize| -> Vec<u8> {
            let mut d = vec![idx("blue"); W * H];
            for k in 0..red_cells {
                d[(k % H) * W + k / H] = idx("red");
            }
            d
        };
        // 60% of 864 is 518.4: 519 red cells is enough, 518 isn't.
        assert_eq!(credit(&flag, &drawn(519)), DrawCredit::Colours);
        assert_eq!(credit(&flag, &drawn(518)), DrawCredit::None);
        // And the same for blue at the other end.
        assert_eq!(credit(&flag, &drawn(W * H - 519)), DrawCredit::Colours);
        assert_eq!(credit(&flag, &drawn(W * H - 518)), DrawCredit::None);
    }

    #[test]
    fn a_pixel_is_blank_below_half_opacity() {
        assert_eq!(classify_pixels(vec![206, 17, 38, 127]), [BLANK]);
        assert_eq!(classify_pixels(vec![206, 17, 38, 128]), [idx("red")]);
        assert_eq!(classify_pixels(vec![0, 0, 0, 0]), [BLANK]);
    }

    // ---- The paint box ---------------------------------------------------

    #[test]
    fn every_typical_shade_is_named_as_its_own_colour() {
        assert_eq!(SHADES.len(), PALETTE.len());
        for (i, shades) in SHADES.iter().enumerate() {
            assert!(!shades.is_empty(), "{}", PALETTE[i]);
            for &(r, g, b) in *shades {
                assert_eq!(
                    nearest_paint(r, g, b) as usize,
                    i,
                    "{:?} for {}",
                    (r, g, b),
                    PALETTE[i]
                );
            }
        }
    }

    #[test]
    fn classify_ignores_a_partial_pixel_and_handles_nothing() {
        assert!(classify_pixels(Vec::new()).is_empty());
        assert_eq!(classify_pixels(vec![0, 0, 0, 255, 9, 9]), [idx("black")]);
    }

    #[test]
    fn more_of_a_right_answer_is_worth_more() {
        let order = [
            DrawCredit::Full,
            DrawCredit::Mirrored,
            DrawCredit::Colours,
            DrawCredit::None,
        ];
        let percents: Vec<u32> = order.iter().map(|c| draw_credit_percent(*c)).collect();
        assert_eq!(percents, [100, 75, 50, 0]);
    }

    // ---- Part credit with close shades, extras and bad input -------------

    #[test]
    fn a_mirror_image_in_a_close_shade_is_still_a_mirror_image() {
        let flag = grid(france);
        let backwards_maroon = grid(|x, y| match france(1.0 - x, y) {
            "red" => "maroon",
            c => c,
        });
        assert_eq!(credit(&flag, &backwards_maroon), DrawCredit::Mirrored);
    }

    #[test]
    fn the_right_colours_in_close_shades_earn_half() {
        let flag = grid(|_, y| if y < 0.5 { "red" } else { "blue" });
        let side_by_side = grid(|x, _| if x < 0.5 { "maroon" } else { "lightblue" });
        assert_eq!(credit(&flag, &side_by_side), DrawCredit::Colours);
    }

    #[test]
    fn a_mirror_image_with_a_big_extra_colour_earns_nothing() {
        let flag = grid(france);
        let backwards_with_green = grid(|x, y| if y < 0.2 { "green" } else { france(1.0 - x, y) });
        let g = grade(&flag, &backwards_with_green, &[]);
        assert_eq!(g.extra_colours, ["green"]);
        assert_eq!(g.credit, DrawCredit::None);
    }

    #[test]
    fn an_outline_of_the_wrong_size_is_never_right() {
        let flag = grid(france);
        let g = grade(&flag, &flag, &[idx("blue"); 10]);
        assert!(!g.correct);
        assert_ne!(g.credit, DrawCredit::Full);
    }

    #[test]
    fn a_blank_reference_earns_nothing() {
        let blank = vec![BLANK; W * H];
        for drawing in [blank.clone(), grid(france)] {
            let g = grade(&blank, &drawing, &[]);
            assert!(!g.correct);
            assert_eq!(g.credit, DrawCredit::None);
        }
    }

    #[test]
    fn nothing_in_the_emblem_is_marked_wrong() {
        let emblem = |x: f32, y: f32| (x - 0.5).abs() < 0.12 && (y - 0.5).abs() < 0.2;
        let flag = grid(|x, y| if emblem(x, y) { "yellow" } else { france(x, y) });
        let outline = grid(france);
        // Black scribbled over the emblem and a wrong (red) left band.
        let drawing = grid(|x, y| {
            if emblem(x, y) {
                "black"
            } else if x < 1.0 / 3.0 {
                "red"
            } else {
                france(x, y)
            }
        });
        let g = grade(&flag, &drawing, &outline);
        for i in 0..W * H {
            let (x, y) = ((i % W) as f32 / W as f32, (i / W) as f32 / H as f32);
            if emblem(x, y) {
                assert!(!g.wrong_cells[i], "cell {i} is in the emblem");
            }
        }
        assert!(g.wrong_cells.iter().any(|w| *w), "the left band is wrong");
    }

    #[test]
    fn a_half_wrong_drawing_scores_about_half() {
        let flag = grid(|_, y| if y < 0.5 { "red" } else { "blue" });
        let all_red = grid(|_, _| "red");
        let g = grade(&flag, &all_red, &[]);
        // Blue's cells next to the red band match (the 3×3 tolerance).
        assert!((50..=53).contains(&g.score_percent), "{}", g.score_percent);
        assert_eq!(g.missing_colours, ["blue"]);
    }

    // ---- Gaps mutation testing found ----------------------------------------

    #[test]
    fn a_colour_exactly_between_two_paints_goes_to_the_earlier_one() {
        // (229, 84, 45) is as close to a red shade as to an orange one.
        assert_eq!(nearest_paint(229, 84, 45), idx("red"));
    }

    #[test]
    fn a_flag_that_changes_down_its_rows_drawn_backwards_is_a_mirror_image() {
        // Blue hoist, white over red on the fly side (every row differs from
        // the first, unlike vertical stripes).
        let flag = grid(|x, y| {
            if x < 1.0 / 3.0 {
                "blue"
            } else if y < 0.5 {
                "white"
            } else {
                "red"
            }
        });
        assert_eq!(
            credit(&flag, &flipped_left_right(&flag)),
            DrawCredit::Mirrored
        );
    }

    #[test]
    fn a_blank_canvas_counts_as_white_for_colours_credit() {
        // Red over white; drawn as red on the left, the rest left blank.
        let flag = grid(|_, y| if y < 0.5 { "red" } else { "white" });
        let drawing = grid(|x, _| if x < 0.5 { "red" } else { BLANK_NAME });
        assert_eq!(credit(&flag, &drawing), DrawCredit::Colours);
    }

    #[test]
    fn grading_refuses_buffers_of_the_wrong_size_itself() {
        // `grade_freehand` checks sizes first; the inner grader must too.
        let g = grade_as_drawn(&[0, 0, 0], &[0, 0, 0, 0], &[], 2, 2);
        assert_eq!(g.score_percent, 0);
        assert!(g.wrong_cells.is_empty() && !g.correct);
        let g = grade_as_drawn(&[0; 4], &[0; 3], &[], 2, 2);
        assert!(g.wrong_cells.is_empty() && !g.correct);
        let g = grade_as_drawn(&[0; 4], &[0; 4], &[0; 2], 2, 2);
        assert!(g.wrong_cells.is_empty() && !g.correct);
    }

    #[test]
    fn a_colour_on_exactly_six_percent_is_graded_not_detail() {
        // On a 50×50 grid, a 10×15 block is exactly 6%: a main colour, so
        // leaving it out is wrong. Grading and the colour hint agree.
        let (w, h) = (50usize, 50usize);
        let flag: Vec<u8> = (0..w * h)
            .map(|i| {
                if i % w < 10 && i / w < 15 {
                    idx("blue")
                } else {
                    idx("red")
                }
            })
            .collect();
        assert_eq!(flag_main_colours(flag.clone()), ["red", "blue"]);
        let all_red = vec![idx("red"); w * h];
        let g = grade_freehand(flag, all_red, vec![], w as u32, h as u32);
        assert_eq!(g.missing_colours, ["blue"]);
        assert!(!g.correct);
    }

    // ---- Generated striped flags ------------------------------------------

    /// A flag of `colours` in equal bands, across (stripes) or down.
    fn bands(colours: &[u8], across: bool) -> Vec<u8> {
        let n = colours.len();
        cells(|x, y| colours[if across { y * n / H } else { x * n / W }])
    }

    fn flipped_left_right(d: &[u8]) -> Vec<u8> {
        cells(|x, y| d[y * W + (W - 1 - x)])
    }

    /// Fewer cases than the rest: each case grades whole grids, up to three
    /// times. Nightly's PROPTEST_CASES still scales it.
    fn grading_config() -> ProptestConfig {
        ProptestConfig {
            cases: (ProptestConfig::default().cases / 2).max(8),
            ..ProptestConfig::default()
        }
    }

    proptest! {
        #[test]
        fn copying_any_two_colour_split_is_right(a in 0u8..9, b in 0u8..9, cut in 0.3f32..0.7) {
            prop_assume!(!matches(a, b));
            let f: Vec<u8> = (0..W * H).map(|i| if ((i % W) as f32) < cut * W as f32 { a } else { b }).collect();
            prop_assert!(grade(&f, &f, &[]).correct);
        }

        #[test]
        fn grading_never_panics(r in proptest::collection::vec(prop_oneof![0u8..9, Just(BLANK)], W * H),
                                d in proptest::collection::vec(prop_oneof![0u8..9, Just(BLANK)], W * H)) {
            let g = grade(&r, &d, &[]);
            prop_assert!(g.score_percent <= 100);
            prop_assert_eq!(g.wrong_cells.len(), W * H);
        }
    }

    proptest! {
        #![proptest_config(grading_config())]

        #[test]
        fn copying_any_striped_flag_is_right(colours in proptest::collection::vec(0u8..9, 2..=5), across: bool) {
            prop_assume!(colours.windows(2).all(|p| !matches(p[0], p[1])));
            let flag = bands(&colours, across);
            let g = grade(&flag, &flag, &[]);
            prop_assert!(g.correct, "{:?}", g);
            prop_assert_eq!(g.credit, DrawCredit::Full);
        }

        #[test]
        fn a_striped_flag_drawn_backwards_earns_full_or_mirror_credit(
            colours in proptest::collection::vec(0u8..9, 2..=5), across: bool,
        ) {
            prop_assume!(colours.windows(2).all(|p| !matches(p[0], p[1])));
            let flag = bands(&colours, across);
            let c = credit(&flag, &flipped_left_right(&flag));
            prop_assert!(c == DrawCredit::Full || c == DrawCredit::Mirrored, "{:?}", c);
        }

        #[test]
        fn the_right_colours_in_any_order_earn_at_least_half(
            colours in proptest::sample::subsequence((0u8..9).collect::<Vec<_>>(), 2..=4),
            across: bool, turn in 1usize..4,
        ) {
            prop_assume!(colours.iter().enumerate()
                .all(|(i, a)| colours[i + 1..].iter().all(|b| !matches(*a, *b))));
            let mut shuffled = colours.clone();
            let turn = turn % shuffled.len();
            shuffled.rotate_left(turn.max(1));
            let c = credit(&bands(&colours, across), &bands(&shuffled, across));
            prop_assert!(c != DrawCredit::None, "{:?} drawn as {:?}", colours, shuffled);
        }

        #[test]
        fn right_means_full_credit_and_full_credit_means_right(
            colours in proptest::collection::vec(0u8..9, 2..=4), across: bool,
            scribble in proptest::collection::vec((0usize..W * H, 0u8..9), 0..400),
        ) {
            let flag = bands(&colours, across);
            let mut d = flag.clone();
            for (i, c) in scribble {
                d[i] = c;
            }
            let g = grade(&flag, &d, &[]);
            prop_assert_eq!(g.correct, g.credit == DrawCredit::Full);
        }

        #[test]
        fn missing_colours_are_always_main_colours(
            r in proptest::collection::vec(prop_oneof![0u8..9, Just(BLANK)], W * H),
            d in proptest::collection::vec(prop_oneof![0u8..9, Just(BLANK)], W * H),
        ) {
            let main = flag_main_colours(r.clone());
            let g = grade(&r, &d, &[]);
            prop_assert!(g.missing_colours.iter().all(|c| main.contains(c)), "{:?} vs {:?}", g.missing_colours, main);
        }
    }

    proptest! {
        #[test]
        fn main_colours_are_paint_box_colours_in_order_once(
            r in proptest::collection::vec(prop_oneof![0u8..9, Just(BLANK), 9u8..=254], 0..600),
        ) {
            let main = flag_main_colours(r.clone());
            let positions: Vec<usize> = main.iter()
                .map(|c| PALETTE.iter().position(|p| p == c).expect("a paint-box colour"))
                .collect();
            prop_assert!(positions.windows(2).all(|p| p[0] < p[1]), "{:?}", main);
            for p in positions {
                let area = r.iter().filter(|&&c| c as usize == p).count();
                prop_assert!(area > 0 && area * 100 >= r.len() * MINOR_SHARE_PERCENT as usize);
            }
        }
    }
}
