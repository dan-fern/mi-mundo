//! Game days (requirements §3.7).
//!
//! A game day starts at 10 pm US Eastern time (America/New_York, following
//! daylight saving), wherever the iPad is. Each game day is named after the
//! calendar date it mostly covers: 10 pm ET on Nov 8 starts game day Nov 9.
//!
//! Game days are passed around as `i32` day numbers (days since 1970-01-01)
//! so Swift can store and compare them cheaply.

use chrono::{DateTime, Duration, NaiveDate};
use chrono_tz::America::New_York;

/// Hour (US Eastern, 24 h clock) when a new game day begins.
pub const DAY_START_HOUR_ET: i64 = 22;

const EPOCH: NaiveDate = NaiveDate::from_ymd_opt(1970, 1, 1).expect("valid date");

/// Game day number for an instant given as Unix seconds.
#[uniffi::export]
pub fn game_day(unix_seconds: i64) -> i32 {
    let utc = DateTime::from_timestamp(unix_seconds, 0).unwrap_or(DateTime::UNIX_EPOCH);
    let eastern = utc.with_timezone(&New_York).naive_local();
    // Shift so 10 pm lands on midnight of the next calendar date.
    let shifted = eastern + Duration::hours(24 - DAY_START_HOUR_ET);
    (shifted.date() - EPOCH).num_days() as i32
}

/// ISO date (YYYY-MM-DD) naming a game day, for parent screens and logs.
#[uniffi::export]
pub fn game_day_label(day: i32) -> String {
    (EPOCH + Duration::days(i64::from(day)))
        .format("%Y-%m-%d")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    /// Unix seconds for a wall-clock time in US Eastern.
    fn et(y: i32, m: u32, d: u32, h: u32, min: u32) -> i64 {
        New_York
            .with_ymd_and_hms(y, m, d, h, min, 0)
            .single()
            .expect("unambiguous ET time")
            .timestamp()
    }

    fn label_at(unix: i64) -> String {
        game_day_label(game_day(unix))
    }

    #[test]
    fn day_rolls_over_at_10pm_eastern() {
        assert_eq!(label_at(et(2026, 11, 8, 21, 59)), "2026-11-08");
        assert_eq!(label_at(et(2026, 11, 8, 22, 0)), "2026-11-09");
        assert_eq!(label_at(et(2026, 11, 9, 0, 30)), "2026-11-09");
        assert_eq!(label_at(et(2026, 11, 9, 21, 59)), "2026-11-09");
    }

    #[test]
    fn follows_daylight_saving() {
        // Summer (EDT, UTC-4): 10 pm ET is 02:00 UTC.
        let summer = et(2026, 7, 1, 22, 0);
        assert_eq!(label_at(summer), "2026-07-02");
        assert_eq!(label_at(summer - 1), "2026-07-01");
        // Winter (EST, UTC-5): 10 pm ET is 03:00 UTC.
        let winter = et(2026, 1, 15, 22, 0);
        assert_eq!(label_at(winter), "2026-01-16");
        assert_eq!(label_at(winter - 1), "2026-01-15");
    }

    #[test]
    fn dst_transition_days_are_normal_length_at_the_boundary() {
        // Clocks change at 2 am, well away from the 10 pm boundary.
        assert_eq!(label_at(et(2026, 3, 8, 21, 59)), "2026-03-08");
        assert_eq!(label_at(et(2026, 3, 8, 22, 0)), "2026-03-09");
        assert_eq!(label_at(et(2026, 11, 1, 21, 59)), "2026-11-01");
        assert_eq!(label_at(et(2026, 11, 1, 22, 0)), "2026-11-02");
    }

    #[test]
    fn same_instant_is_same_day_regardless_of_device_timezone() {
        // 8:30 pm in Los Angeles = 11:30 pm ET, so it's already the next day.
        let la_evening = chrono_tz::America::Los_Angeles
            .with_ymd_and_hms(2026, 11, 8, 20, 30, 0)
            .unwrap()
            .timestamp();
        assert_eq!(label_at(la_evening), "2026-11-09");
    }

    #[test]
    fn consecutive_days_are_consecutive_numbers() {
        let a = game_day(et(2026, 12, 31, 12, 0));
        let b = game_day(et(2027, 1, 1, 12, 0));
        assert_eq!(b - a, 1);
        assert_eq!(game_day_label(b), "2027-01-01");
    }

    #[test]
    fn epoch_label() {
        assert_eq!(game_day_label(0), "1970-01-01");
    }
}
