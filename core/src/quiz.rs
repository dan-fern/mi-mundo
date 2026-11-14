//! Playing a quiz (requirements §3.2): building the pick-from-four answer
//! choices and rating a finished sitting.

/// Buttons shown for each question: the right answer and up to three others.
pub const QUIZ_CHOICES: u32 = 4;

/// How many of the nearest candidates the wrong answers are drawn from:
/// enough for variety between sittings, few enough that they stay plausible
/// neighbours (asking about Peru offers Bolivia, not Mongolia).
pub const DISTRACTOR_POOL: usize = 8;

/// The answer buttons for one question, in display order.
///
/// - `correct`: the right answer.
/// - `candidates`: possible wrong answers, **most plausible first** (the
///   app passes neighbours nearest-first). Blanks, repeats and anything
///   equal to `correct` are ignored.
/// - `seed`: picks which candidates are used and the button order, so a
///   question redraws the same way but differs between sittings.
///
/// Returns `correct` plus up to three distinct wrong answers drawn from the
/// first [`DISTRACTOR_POOL`] usable candidates. With fewer candidates there
/// are fewer buttons; with none, just the right answer.
#[uniffi::export]
pub fn quiz_choices(correct: String, candidates: Vec<String>, seed: u64) -> Vec<String> {
    let mut pool: Vec<String> = Vec::new();
    for candidate in candidates {
        let usable = !candidate.trim().is_empty() && candidate != correct;
        if usable && !pool.contains(&candidate) {
            pool.push(candidate);
            if pool.len() == DISTRACTOR_POOL {
                break;
            }
        }
    }
    let mut rng = SplitMix64(seed);
    let mut choices = Vec::with_capacity(QUIZ_CHOICES as usize);
    while choices.len() < QUIZ_CHOICES as usize - 1 && !pool.is_empty() {
        choices.push(pool.swap_remove(rng.below(pool.len())));
    }
    let slot = rng.below(choices.len() + 1);
    choices.insert(slot, correct);
    choices
}

/// Stars for a finished sitting, from how many answers were right: three
/// for 90% or more, two for 60% or more, one for anything right, none
/// otherwise (or for an empty quiz).
#[uniffi::export]
pub fn quiz_stars(correct: u32, total: u32) -> u32 {
    if total == 0 || correct == 0 {
        return 0;
    }
    let correct = u64::from(correct.min(total));
    let total = u64::from(total);
    if correct * 10 >= total * 9 {
        3
    } else if correct * 10 >= total * 6 {
        2
    } else {
        1
    }
}

/// Small, well-known generator (SplitMix64): the same on every device, so
/// tests can pin results. Not for anything secret.
pub(crate) struct SplitMix64(pub(crate) u64);

impl SplitMix64 {
    pub(crate) fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// A number in `0..n` (`n` > 0). The tiny bias of `%` doesn't matter
    /// for shuffling four buttons.
    pub(crate) fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn names(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    const PINNED_42: [&str; 4] = ["Peru", "Paraguay", "Uruguay", "Bolivia"];

    const NEIGHBOURS: &[&str] = &[
        "Bolivia",
        "Ecuador",
        "Chile",
        "Colombia",
        "Brazil",
        "Paraguay",
        "Argentina",
        "Uruguay",
        "Venezuela",
        "Guyana",
        "Suriname",
        "Panama",
    ];

    #[test]
    fn four_choices_with_the_right_answer_once() {
        let choices = quiz_choices("Peru".into(), names(NEIGHBOURS), 1);
        assert_eq!(choices.len(), 4);
        assert_eq!(choices.iter().filter(|c| *c == "Peru").count(), 1);
    }

    #[test]
    fn wrong_answers_come_from_the_nearest_candidates() {
        for seed in 0..200 {
            for choice in quiz_choices("Peru".into(), names(NEIGHBOURS), seed) {
                let near = NEIGHBOURS[..DISTRACTOR_POOL].contains(&choice.as_str());
                assert!(choice == "Peru" || near, "{choice} is too far away");
            }
        }
    }

    #[test]
    fn the_same_seed_gives_the_same_buttons() {
        let a = quiz_choices("Peru".into(), names(NEIGHBOURS), 42);
        assert_eq!(a, quiz_choices("Peru".into(), names(NEIGHBOURS), 42));
    }

    #[test]
    fn the_generator_is_pinned() {
        // Reference output of SplitMix64 for seed 0, and a fixed draw: if
        // either changes, every iPad's buttons would change too.
        assert_eq!(SplitMix64(0).next(), 0xE220_A839_7B1D_CDAF);
        assert_eq!(
            quiz_choices("Peru".into(), names(NEIGHBOURS), 42),
            PINNED_42.map(String::from)
        );
    }

    #[test]
    fn a_blank_right_answer_is_still_offered_once() {
        let choices = quiz_choices("  ".into(), names(&["Lima", "Quito"]), 1);
        assert_eq!(choices.iter().filter(|c| *c == "  ").count(), 1);
        assert_eq!(choices.len(), 3);
    }

    #[test]
    fn different_sittings_vary_the_order_and_the_wrong_answers() {
        let all: Vec<Vec<String>> = (0..100)
            .map(|seed| quiz_choices("Peru".into(), names(NEIGHBOURS), seed))
            .collect();
        for slot in 0..4 {
            assert!(
                all.iter().any(|c| c[slot] == "Peru"),
                "never in slot {slot}"
            );
        }
        let used: std::collections::HashSet<&String> = all.iter().flatten().collect();
        assert_eq!(
            used.len(),
            1 + DISTRACTOR_POOL,
            "every near candidate gets used"
        );
    }

    #[test]
    fn the_answer_itself_blanks_and_repeats_are_never_wrong_choices() {
        let candidates = names(&["Lima", "", "  ", "Quito", "Quito", "Lima", "La Paz"]);
        let mut choices = quiz_choices("Lima".into(), candidates, 7);
        choices.sort();
        assert_eq!(choices, names(&["La Paz", "Lima", "Quito"]));
    }

    #[test]
    fn with_no_candidates_there_is_just_the_answer() {
        assert_eq!(quiz_choices("Peru".into(), vec![], 3), names(&["Peru"]));
    }

    #[test]
    fn stars_follow_the_share_of_right_answers() {
        assert_eq!(quiz_stars(0, 0), 0);
        assert_eq!(quiz_stars(0, 10), 0);
        assert_eq!(quiz_stars(1, 10), 1);
        assert_eq!(quiz_stars(5, 10), 1);
        assert_eq!(quiz_stars(6, 10), 2);
        assert_eq!(quiz_stars(8, 10), 2);
        assert_eq!(quiz_stars(9, 10), 3);
        assert_eq!(quiz_stars(10, 10), 3);
        assert_eq!(quiz_stars(24, 24), 3);
        assert_eq!(quiz_stars(99, 10), 3, "more right than asked is capped");
        assert_eq!(quiz_stars(u32::MAX, u32::MAX), 3);
    }

    proptest! {
        #[test]
        fn choices_are_always_well_formed(
            correct in "[a-f]{1,3}",
            candidates in prop::collection::vec("[a-f ]{0,3}", 0..20),
            seed: u64,
        ) {
            let choices = quiz_choices(correct.clone(), candidates.clone(), seed);
            prop_assert!((1..=4).contains(&choices.len()));
            prop_assert_eq!(choices.iter().filter(|c| **c == correct).count(), 1);
            let distinct: std::collections::HashSet<&String> = choices.iter().collect();
            prop_assert_eq!(distinct.len(), choices.len());
            for c in &choices {
                prop_assert!(*c == correct || candidates.contains(c));
                prop_assert!(!c.trim().is_empty() || *c == correct);
            }
        }

        #[test]
        fn stars_never_go_down_with_more_right_answers(total in 1u32..500, a in 0u32..500, b in 0u32..500) {
            let (low, high) = (a.min(b), a.max(b));
            prop_assert!(quiz_stars(low, total) <= quiz_stars(high, total));
            prop_assert!(quiz_stars(high, total) <= 3);
        }
    }
}
