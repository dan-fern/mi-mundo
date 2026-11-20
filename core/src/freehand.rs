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
    let n = reference.len();
    let white = PALETTE.iter().position(|c| *c == "white").unwrap() as u8;
    let mut area = [0usize; 9];
    let mut drawn = [0usize; 9];
    for (&r, &d) in reference.iter().zip(drawing) {
        if (r as usize) < area.len() {
            area[r as usize] += 1;
        }
        let d = if d == BLANK { white } else { d };
        if (d as usize) < drawn.len() {
            drawn[d as usize] += 1;
        }
    }
    let main: Vec<u8> = (0..9u8)
        .filter(|&c| area[c as usize] * 100 >= n * MINOR_SHARE_PERCENT as usize)
        .collect();
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
    let mut area = [0usize; 9];
    for &c in reference {
        if (c as usize) < area.len() {
            area[c as usize] += 1;
        }
    }
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
}
