//! Attendance gauge and day streak (requirements §3.6, §3.7).
//!
//! Visits are game-day numbers from [`crate::days::game_day`], logged when a
//! child picks their profile. Duplicates and unsorted input are fine.

use std::collections::BTreeSet;

/// Highest level the gauge shows.
pub const ATTENDANCE_MAX: u32 = 5;

/// Length of the attendance window, including today.
pub const ATTENDANCE_WINDOW_DAYS: i32 = 7;

/// Highest gauge level, exported so the Swift gauge doesn't hard-code it
/// (UniFFI can't export constants directly).
#[uniffi::export]
pub fn attendance_max() -> u32 {
    ATTENDANCE_MAX
}

/// Gauge level from the number of distinct days the child played in the
/// last 7 days. Capped at [`ATTENDANCE_MAX`], the fullest and "hottest" level.
#[uniffi::export]
pub fn attendance_level(days_opened_last_7: u32) -> u32 {
    days_opened_last_7.min(ATTENDANCE_MAX)
}

/// Distinct days played in the 7-day window ending on `today` (today and the
/// 6 days before it). Visits after `today` are ignored.
#[uniffi::export]
pub fn days_played_last_7(visit_days: Vec<i32>, today: i32) -> u32 {
    let first = today.saturating_sub(ATTENDANCE_WINDOW_DAYS - 1);
    visit_days
        .into_iter()
        .filter(|day| (first..=today).contains(day))
        .collect::<BTreeSet<_>>()
        .len() as u32
}

/// Gauge level straight from the visit log.
#[uniffi::export]
pub fn attendance_level_for(visit_days: Vec<i32>, today: i32) -> u32 {
    attendance_level(days_played_last_7(visit_days, today))
}

/// Consecutive days played, ending today. If the child hasn't played yet
/// today, the streak ending yesterday still counts (it isn't broken until
/// today ends).
#[uniffi::export]
pub fn day_streak(visit_days: Vec<i32>, today: i32) -> u32 {
    let days: BTreeSet<i32> = visit_days.into_iter().filter(|d| *d <= today).collect();
    let mut day = if days.contains(&today) {
        today
    } else {
        today.saturating_sub(1)
    };
    let mut streak = 0;
    while days.contains(&day) {
        streak += 1;
        day = match day.checked_sub(1) {
            Some(previous) => previous,
            None => break,
        };
    }
    streak
}

#[cfg(test)]
mod tests {
    use super::*;

    const TODAY: i32 = 20_000;

    #[test]
    fn caps_at_max() {
        assert_eq!(attendance_level(0), 0);
        assert_eq!(attendance_level(3), 3);
        assert_eq!(attendance_level(5), 5);
        assert_eq!(attendance_level(7), 5);
        assert_eq!(attendance_level(u32::MAX), ATTENDANCE_MAX);
    }

    #[test]
    fn exported_max_matches_const() {
        assert_eq!(attendance_max(), ATTENDANCE_MAX);
    }

    #[test]
    fn window_is_today_plus_previous_six_days() {
        let days = vec![TODAY, TODAY - 6, TODAY - 7, TODAY + 1];
        assert_eq!(days_played_last_7(days, TODAY), 2);
    }

    #[test]
    fn duplicates_and_order_do_not_matter() {
        let days = vec![TODAY - 2, TODAY, TODAY - 2, TODAY, TODAY - 1];
        assert_eq!(days_played_last_7(days, TODAY), 3);
    }

    #[test]
    fn level_for_caps_a_full_week_at_five() {
        let week: Vec<i32> = (TODAY - 6..=TODAY).collect();
        assert_eq!(days_played_last_7(week.clone(), TODAY), 7);
        assert_eq!(attendance_level_for(week, TODAY), 5);
        assert_eq!(attendance_level_for(vec![], TODAY), 0);
    }

    #[test]
    fn streak_counts_back_from_today() {
        assert_eq!(day_streak(vec![TODAY, TODAY - 1, TODAY - 2], TODAY), 3);
        assert_eq!(day_streak(vec![TODAY, TODAY - 2], TODAY), 1);
    }

    #[test]
    fn streak_survives_until_today_ends() {
        assert_eq!(day_streak(vec![TODAY - 1, TODAY - 2], TODAY), 2);
        assert_eq!(day_streak(vec![TODAY - 2, TODAY - 3], TODAY), 0);
    }

    #[test]
    fn streak_ignores_future_and_empty() {
        assert_eq!(day_streak(vec![], TODAY), 0);
        assert_eq!(day_streak(vec![TODAY + 1], TODAY), 0);
    }

    #[test]
    fn extreme_day_numbers_do_not_overflow() {
        assert_eq!(days_played_last_7(vec![i32::MIN], i32::MIN), 1);
        assert_eq!(day_streak(vec![i32::MIN], i32::MIN), 1);
    }
}
