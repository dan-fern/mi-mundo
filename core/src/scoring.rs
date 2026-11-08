//! Quiz scoring (requirements §3.4).

/// Points earned for a correct answer.
///
/// - `base_points`: value the parent assigned to the question.
/// - `attempt`: which time this quiz is being taken (1 = first).
/// - `used_multiple_choice`: flag questions answered via the multiple-choice
///   fallback earn half.
///
/// Attempts 1, 2, 3 earn full, ½ and ¼; attempt 4 and later earn nothing.
/// Fractions round down to whole points.
#[uniffi::export]
pub fn points_for_attempt(base_points: u32, attempt: u32, used_multiple_choice: bool) -> u32 {
    let mut points = match attempt {
        1 => base_points,
        2 => base_points / 2,
        3 => base_points / 4,
        _ => 0,
    };
    if used_multiple_choice {
        points /= 2;
    }
    points
}

#[cfg(test)]
mod tests {
    use super::*;

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
    }

    #[test]
    fn attempt_zero_is_treated_as_no_points() {
        assert_eq!(points_for_attempt(100, 0, false), 0);
    }
}
