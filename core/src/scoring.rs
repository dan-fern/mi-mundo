//! Quiz scoring (requirements §3.4).

/// Last quiz sitting that still earns points.
pub const LAST_SCORED_ATTEMPT: u32 = 3;

/// Share of the question's points each scored sitting is worth, in quarters:
/// the 1st sitting full, the 2nd three quarters, the 3rd half.
const QUARTERS_BY_ATTEMPT: [u64; LAST_SCORED_ATTEMPT as usize] = [4, 3, 2];

/// Points earned for a correct answer.
///
/// - `base_points`: value the parent assigned to the question.
/// - `attempt`: which sitting of this quiz this is, starting at 1. Every
///   question is scored again on each retake. `0` is not a valid attempt and
///   scores 0 (debug builds assert).
/// - `used_multiple_choice`: flag questions answered via the multiple-choice
///   fallback earn half, on top of the attempt factor.
///
/// Attempts 1, 2, 3 earn full, ¾ and ½; attempt 4 and later are just for
/// fun and earn nothing. Fractions round down, but a correct answer on
/// attempts 1–3 always earns at least 1 point (unless the parent set the
/// question to 0).
#[uniffi::export]
pub fn points_for_attempt(base_points: u32, attempt: u32, used_multiple_choice: bool) -> u32 {
    points_with_credit(base_points, attempt, used_multiple_choice, 100)
}

/// Points for an answer that earned `credit_percent` of a right answer
/// (0–100; above 100 counts as 100). A drawn flag can be partly right
/// (all the right colours, or a mirror image: see `freehand::DrawCredit`);
/// every other answer is 100 (right) or 0 (wrong).
///
/// The credit applies on top of the attempt and multiple-choice factors.
/// Any credit above 0 on a scored attempt earns at least 1 point.
#[uniffi::export]
pub fn points_with_credit(
    base_points: u32,
    attempt: u32,
    used_multiple_choice: bool,
    credit_percent: u32,
) -> u32 {
    debug_assert!(attempt >= 1, "attempt numbers start at 1");
    if base_points == 0 || attempt == 0 || attempt > LAST_SCORED_ATTEMPT || credit_percent == 0 {
        return 0;
    }
    // Widened so the largest base can't overflow before dividing.
    let quarters = QUARTERS_BY_ATTEMPT[(attempt - 1) as usize];
    let credit = u64::from(credit_percent.min(100));
    let halves = if used_multiple_choice { 2 } else { 1 };
    let points = u64::from(base_points) * quarters * credit / (4 * 100 * halves);
    (points as u32).max(1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    #[test]
    fn attempts_earn_full_then_three_quarters_then_half_then_stop() {
        assert_eq!(points_for_attempt(100, 1, false), 100);
        assert_eq!(points_for_attempt(100, 2, false), 75);
        assert_eq!(points_for_attempt(100, 3, false), 50);
        assert_eq!(points_for_attempt(100, 4, false), 0);
        assert_eq!(points_for_attempt(100, 9, false), 0);
    }

    #[test]
    fn multiple_choice_halves_on_top_of_attempt() {
        assert_eq!(points_for_attempt(100, 1, true), 50);
        assert_eq!(points_for_attempt(100, 2, true), 37);
        assert_eq!(points_for_attempt(100, 3, true), 25);
        assert_eq!(points_for_attempt(100, 4, true), 0);
    }

    #[test]
    fn odd_values_round_down() {
        assert_eq!(points_for_attempt(7, 2, false), 5);
        assert_eq!(points_for_attempt(7, 3, false), 3);
        assert_eq!(points_for_attempt(7, 1, true), 3);
        assert_eq!(points_for_attempt(15, 2, false), 11);
    }

    #[test]
    fn correct_answers_earn_at_least_one_point() {
        assert_eq!(points_for_attempt(1, 1, false), 1);
        assert_eq!(points_for_attempt(1, 2, false), 1);
        assert_eq!(points_for_attempt(1, 3, false), 1);
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
    fn credit_scales_on_top_of_attempt_and_choice() {
        // A drawn flag worth 15: mirror image (¾) and colours only (½).
        assert_eq!(points_with_credit(15, 1, false, 100), 15);
        assert_eq!(points_with_credit(15, 1, false, 75), 11);
        assert_eq!(points_with_credit(15, 1, false, 50), 7);
        assert_eq!(points_with_credit(100, 2, false, 75), 56);
        assert_eq!(points_with_credit(100, 3, false, 50), 25);
        assert_eq!(points_with_credit(100, 1, true, 50), 25);
        // No credit, or past the last scored sitting: nothing.
        assert_eq!(points_with_credit(100, 1, false, 0), 0);
        assert_eq!(points_with_credit(100, 4, false, 100), 0);
        // Any credit earns at least a point; above 100 counts as 100.
        assert_eq!(points_with_credit(1, 3, true, 50), 1);
        assert_eq!(points_with_credit(100, 1, false, 250), 100);
    }

    /// A no-overflow guard (the arithmetic is widened to 64 bits). Literal
    /// expectations, so a change in the rule shows up.
    #[test]
    fn huge_bases_never_overflow_at_any_attempt() {
        assert_eq!(points_for_attempt(u32::MAX, 1, false), 4_294_967_295);
        assert_eq!(points_for_attempt(u32::MAX, 1, true), 2_147_483_647);
        assert_eq!(points_for_attempt(u32::MAX, 2, false), 3_221_225_471);
        assert_eq!(points_for_attempt(u32::MAX, 2, true), 1_610_612_735);
        assert_eq!(points_for_attempt(u32::MAX, 3, false), 2_147_483_647);
        assert_eq!(points_for_attempt(u32::MAX, 3, true), 1_073_741_823);
        assert_eq!(points_for_attempt(u32::MAX, 4, false), 0);
        assert_eq!(points_with_credit(u32::MAX, 1, false, 100), u32::MAX);
        // Attempt numbers far past the last scored one earn nothing.
        assert_eq!(points_for_attempt(u32::MAX, u32::MAX, true), 0);
        assert_eq!(points_for_attempt(u32::MAX, u32::MAX, false), 0);
    }

    #[test]
    fn points_never_exceed_the_base() {
        for base in [0, 1, 2, 3, 7, 100, 1 << 31, u32::MAX] {
            for attempt in 1..=6 {
                for mc in [false, true] {
                    for credit in [0, 50, 75, 100] {
                        assert!(points_with_credit(base, attempt, mc, credit) <= base);
                    }
                }
            }
        }
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
        fn more_credit_never_earns_less(base in 0u32..10_000, attempt in 1u32..6, mc: bool, credit in 0u32..100) {
            prop_assert!(points_with_credit(base, attempt, mc, credit) <= points_with_credit(base, attempt, mc, credit + 1));
        }

        #[test]
        fn never_more_than_the_question_is_worth(base: u32, attempt in 1u32..6, mc: bool, credit in 0u32..=100) {
            prop_assert!(points_with_credit(base, attempt, mc, credit) <= base);
        }
    }
}
