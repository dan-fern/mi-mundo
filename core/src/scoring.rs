//! Quiz scoring (requirements §3.4).

/// Last quiz sitting that still earns points.
pub const LAST_SCORED_ATTEMPT: u32 = 3;

/// Points earned for a correct answer.
///
/// - `base_points`: value the parent assigned to the question.
/// - `attempt`: which sitting of this quiz this is, starting at 1. Every
///   question is scored again on each retake. `0` is not a valid attempt and
///   scores 0 (debug builds assert).
/// - `used_multiple_choice`: flag questions answered via the multiple-choice
///   fallback earn half, on top of the attempt factor.
///
/// Attempts 1, 2, 3 earn full, ½ and ¼; attempt 4 and later earn nothing.
/// Fractions round down, but a correct answer on attempts 1–3 always earns
/// at least 1 point (unless the parent set the question to 0).
#[uniffi::export]
pub fn points_for_attempt(base_points: u32, attempt: u32, used_multiple_choice: bool) -> u32 {
    debug_assert!(attempt >= 1, "attempt numbers start at 1");
    if base_points == 0 || attempt == 0 || attempt > LAST_SCORED_ATTEMPT {
        return 0;
    }
    // Attempt n divides by 2^(n-1); multiple choice divides by 2 once more.
    let shift = (attempt - 1) + u32::from(used_multiple_choice);
    (base_points >> shift).max(1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    #[test]
    fn attempts_halve_then_quarter_then_stop() {
        assert_eq!(points_for_attempt(100, 1, false), 100);
        assert_eq!(points_for_attempt(100, 2, false), 50);
        assert_eq!(points_for_attempt(100, 3, false), 25);
        assert_eq!(points_for_attempt(100, 4, false), 0);
        assert_eq!(points_for_attempt(100, 9, false), 0);
    }

    #[test]
    fn multiple_choice_halves_on_top_of_attempt() {
        assert_eq!(points_for_attempt(100, 1, true), 50);
        assert_eq!(points_for_attempt(100, 2, true), 25);
        assert_eq!(points_for_attempt(100, 3, true), 12);
        assert_eq!(points_for_attempt(100, 4, true), 0);
    }

    #[test]
    fn odd_values_round_down() {
        assert_eq!(points_for_attempt(7, 2, false), 3);
        assert_eq!(points_for_attempt(7, 3, false), 1);
        assert_eq!(points_for_attempt(7, 1, true), 3);
    }

    #[test]
    fn correct_answers_earn_at_least_one_point() {
        assert_eq!(points_for_attempt(1, 1, false), 1);
        assert_eq!(points_for_attempt(1, 2, false), 1);
        assert_eq!(points_for_attempt(3, 3, false), 1);
        assert_eq!(points_for_attempt(1, 1, true), 1);
        assert_eq!(points_for_attempt(1, 3, true), 1);
    }

    #[test]
    fn minimum_does_not_apply_after_last_scored_attempt() {
        assert_eq!(points_for_attempt(1, 4, false), 0);
        assert_eq!(points_for_attempt(1, 4, true), 0);
    }

    #[test]
    fn zero_base_scores_zero() {
        for attempt in 1..=4 {
            assert_eq!(points_for_attempt(0, attempt, false), 0);
            assert_eq!(points_for_attempt(0, attempt, true), 0);
        }
    }

    #[test]
    fn max_base_does_not_overflow() {
        assert_eq!(points_for_attempt(u32::MAX, 1, false), u32::MAX);
        assert_eq!(points_for_attempt(u32::MAX, 2, true), u32::MAX / 2 / 2);
    }

    #[test]
    #[cfg(debug_assertions)]
    #[should_panic(expected = "attempt numbers start at 1")]
    fn attempt_zero_asserts_in_debug() {
        points_for_attempt(100, 0, false);
    }

    proptest! {
        #[test]
        fn later_attempts_never_earn_more(base in 0u32..10_000, mc: bool) {
            for attempt in 1..=5 {
                prop_assert!(points_for_attempt(base, attempt + 1, mc) <= points_for_attempt(base, attempt, mc));
            }
        }

        #[test]
        fn multiple_choice_never_earns_more(base in 0u32..10_000, attempt in 1u32..6) {
            prop_assert!(points_for_attempt(base, attempt, true) <= points_for_attempt(base, attempt, false));
        }

        #[test]
        fn never_more_than_the_question_is_worth(base: u32, attempt in 1u32..6, mc: bool) {
            prop_assert!(points_for_attempt(base, attempt, mc) <= base);
        }
    }
}
