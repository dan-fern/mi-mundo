//! Flag drawing with a layout outline (requirements §3.3): the kid picks
//! the flag's layout (stripes, cross, canton, …), fills each region from a
//! small paint box, then may draw the emblem. Grading looks at the layout
//! and the region colours only. Emblems are never graded: the owner asked
//! for drawing to be especially lenient on emblems and anything hard to draw.
//!
//! The flags' layouts and colours live in
//! `apple/MiMundo/Resources/FlagLayouts.json`, written by
//! `tools/check-flag-layouts.py` after checking them against the flag
//! pictures.

use crate::quiz::SplitMix64;

/// The paint box, in the order the app shows it.
pub const PALETTE: [&str; 9] = [
    "red",
    "maroon",
    "orange",
    "yellow",
    "green",
    "lightblue",
    "blue",
    "white",
    "black",
];

/// Shades close enough that either counts (a kid can't be expected to tell
/// Estonia's blue from Botswana's light blue, or Latvia's maroon from red).
pub const CLOSE_SHADES: [(&str, &str); 2] = [("blue", "lightblue"), ("red", "maroon")];

/// Every layout the outline can draw, with how many regions it has. The
/// region order (which the app draws, and the data's colours follow) is
/// described for each in `apple/MiMundo/Sources/Views/FlagOutline.swift`.
pub const FLAG_LAYOUTS: [(&str, u32); 25] = [
    ("plain", 1),
    ("h2", 2),
    ("h3", 3),
    ("h4", 4),
    ("h5", 5),
    ("v2", 2),
    ("v3", 3),
    ("nordic", 2),
    ("nordic-bordered", 3),
    ("cross", 2),
    ("cross-quartered", 5),
    ("quarters", 4),
    ("disc", 2),
    ("h3-disc", 4),
    ("tri-h2", 3),
    ("tri-h3", 4),
    ("tri-h5", 6),
    ("bar-h2", 3),
    ("bar-h3", 4),
    ("saltire", 3),
    ("diagonal", 3),
    ("diagonal-split", 2),
    ("canton", 2),
    ("canton-h2", 3),
    ("diamond", 3),
];

/// How many layouts the kid chooses between.
pub const LAYOUT_CHOICES: u32 = 6;

/// Number of regions in a layout, or 0 for a layout that doesn't exist.
#[uniffi::export]
pub fn flag_layout_regions(layout: String) -> u32 {
    FLAG_LAYOUTS
        .iter()
        .find(|(id, _)| *id == layout)
        .map_or(0, |(_, regions)| *regions)
}

/// The paint box colour names, in display order.
#[uniffi::export]
pub fn flag_palette() -> Vec<String> {
    PALETTE.iter().map(|c| (*c).to_string()).collect()
}

/// The layouts offered for one flag: the right one and five others, in an
/// order fixed by `seed` (so coming back to a question shows the same
/// buttons). An unknown `correct` is still included, as the app's data is
/// checked separately.
#[uniffi::export]
pub fn flag_layout_choices(correct: String, seed: u64) -> Vec<String> {
    let mut pool: Vec<&str> = FLAG_LAYOUTS
        .iter()
        .map(|(id, _)| *id)
        .filter(|id| *id != correct)
        .collect();
    let mut rng = SplitMix64(seed);
    let mut choices: Vec<String> = Vec::with_capacity(LAYOUT_CHOICES as usize);
    while choices.len() < LAYOUT_CHOICES as usize - 1 && !pool.is_empty() {
        choices.push(pool.swap_remove(rng.below(pool.len())).to_string());
    }
    let slot = rng.below(choices.len() + 1);
    choices.insert(slot, correct);
    choices
}

/// Whether a painted colour counts for the flag's colour.
#[uniffi::export]
pub fn flag_colours_match(expected: String, painted: String) -> bool {
    expected == painted
        || CLOSE_SHADES
            .iter()
            .any(|(a, b)| (expected == *a && painted == *b) || (expected == *b && painted == *a))
}

/// How an outline drawing did.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FlagOutlineGrade {
    /// The kid picked the flag's layout.
    pub layout_right: bool,
    /// Per region, in region order: painted a matching colour. Empty when
    /// the layout is wrong (the regions don't line up).
    pub regions_right: Vec<bool>,
    /// The whole flag counts as right: right layout, every region right.
    pub correct: bool,
}

/// Grades an outline drawing: the layout must be the flag's, and every
/// region painted a matching colour (see [`flag_colours_match`]). Unpainted
/// regions (empty strings) are wrong. The emblem is never graded.
#[uniffi::export]
pub fn grade_flag_outline(
    layout: String,
    colors: Vec<String>,
    chosen_layout: String,
    painted: Vec<String>,
) -> FlagOutlineGrade {
    if layout != chosen_layout || painted.len() != colors.len() {
        return FlagOutlineGrade {
            layout_right: layout == chosen_layout,
            regions_right: Vec::new(),
            correct: false,
        };
    }
    let regions_right: Vec<bool> = colors
        .iter()
        .zip(&painted)
        .map(|(want, got)| flag_colours_match(want.clone(), got.clone()))
        .collect();
    let correct = !regions_right.is_empty() && regions_right.iter().all(|r| *r);
    FlagOutlineGrade {
        layout_right: true,
        regions_right,
        correct,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| (*x).to_string()).collect()
    }

    #[test]
    fn france_painted_right_is_right() {
        let g = grade_flag_outline(
            "v3".into(),
            s(&["blue", "white", "red"]),
            "v3".into(),
            s(&["blue", "white", "red"]),
        );
        assert!(g.layout_right && g.correct);
        assert_eq!(g.regions_right, vec![true, true, true]);
    }

    #[test]
    fn stripes_the_wrong_way_round_are_wrong() {
        let g = grade_flag_outline(
            "v3".into(),
            s(&["blue", "white", "red"]),
            "v3".into(),
            s(&["red", "white", "blue"]),
        );
        assert!(!g.correct);
        assert_eq!(g.regions_right, vec![false, true, false]);
    }

    #[test]
    fn wrong_layout_is_wrong_whatever_the_colours() {
        // Italy's colours as horizontal stripes: Hungary's layout, not Italy's.
        let g = grade_flag_outline(
            "v3".into(),
            s(&["green", "white", "red"]),
            "h3".into(),
            s(&["green", "white", "red"]),
        );
        assert!(!g.layout_right && !g.correct);
        assert!(g.regions_right.is_empty());
    }

    #[test]
    fn close_shades_count() {
        // Argentina in plain blue, Latvia in red.
        assert!(
            grade_flag_outline(
                "h3".into(),
                s(&["lightblue", "white", "lightblue"]),
                "h3".into(),
                s(&["blue", "white", "blue"])
            )
            .correct
        );
        assert!(
            grade_flag_outline(
                "h3".into(),
                s(&["maroon", "white", "maroon"]),
                "h3".into(),
                s(&["red", "white", "red"])
            )
            .correct
        );
    }

    #[test]
    fn other_shades_do_not() {
        assert!(!flag_colours_match("orange".into(), "yellow".into()));
        assert!(!flag_colours_match("green".into(), "lightblue".into()));
        assert!(!flag_colours_match("black".into(), "blue".into()));
    }

    #[test]
    fn unpainted_region_is_wrong() {
        let g = grade_flag_outline(
            "h2".into(),
            s(&["white", "red"]),
            "h2".into(),
            s(&["white", ""]),
        );
        assert!(!g.correct);
        assert_eq!(g.regions_right, vec![true, false]);
    }

    #[test]
    fn short_paint_list_is_wrong_not_a_crash() {
        let g = grade_flag_outline(
            "h2".into(),
            s(&["white", "red"]),
            "h2".into(),
            s(&["white"]),
        );
        assert!(g.layout_right && !g.correct);
    }

    #[test]
    fn layout_regions_known_and_unknown() {
        assert_eq!(flag_layout_regions("tri-h5".into()), 6);
        assert_eq!(flag_layout_regions("plain".into()), 1);
        assert_eq!(flag_layout_regions("union-jack".into()), 0);
    }

    #[test]
    fn layout_ids_are_unique() {
        for (i, (a, _)) in FLAG_LAYOUTS.iter().enumerate() {
            assert!(
                FLAG_LAYOUTS[i + 1..].iter().all(|(b, _)| a != b),
                "{a} twice"
            );
        }
    }

    #[test]
    fn palette_has_the_close_shades() {
        for (a, b) in CLOSE_SHADES {
            assert!(PALETTE.contains(&a) && PALETTE.contains(&b));
        }
        assert_eq!(flag_palette().len(), PALETTE.len());
    }

    proptest! {
        #[test]
        fn layout_choices_hold_the_answer_once(i in 0usize..FLAG_LAYOUTS.len(), seed in any::<u64>()) {
            let correct = FLAG_LAYOUTS[i].0.to_string();
            let choices = flag_layout_choices(correct.clone(), seed);
            prop_assert_eq!(choices.len(), LAYOUT_CHOICES as usize);
            prop_assert_eq!(choices.iter().filter(|c| **c == correct).count(), 1);
            let mut sorted = choices.clone();
            sorted.sort();
            sorted.dedup();
            prop_assert_eq!(sorted.len(), choices.len());
            prop_assert!(choices.iter().all(|c| flag_layout_regions(c.clone()) > 0));
            prop_assert_eq!(choices, flag_layout_choices(correct, seed));
        }

        #[test]
        fn painting_the_answer_is_always_right(i in 0usize..FLAG_LAYOUTS.len(), picks in proptest::collection::vec(0usize..PALETTE.len(), 6)) {
            let (layout, n) = FLAG_LAYOUTS[i];
            let colors: Vec<String> = picks.iter().take(n as usize).map(|p| PALETTE[*p].to_string()).collect();
            let g = grade_flag_outline(layout.into(), colors.clone(), layout.into(), colors);
            prop_assert!(g.correct);
        }
    }
}
