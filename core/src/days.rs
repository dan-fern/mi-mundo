//! Game days (requirements §3.7).
//!
//! A game day starts at 11 pm US Eastern time (America/New_York, following
//! daylight saving), wherever the iPad is. Each game day is named after the
//! calendar date it mostly covers: 11 pm ET on Nov 8 starts game day Nov 9.
//!
//! Game days are passed around as `i32` day numbers (days since 1970-01-01)
//! so Swift can store and compare them cheaply.

use chrono::{DateTime, Duration, NaiveDate};
use chrono_tz::America::New_York;

/// Hour (US Eastern, 24 h clock) when a new game day begins.
pub const DAY_START_HOUR_ET: i64 = 23;

const EPOCH: NaiveDate = NaiveDate::from_ymd_opt(1970, 1, 1).expect("valid date");

/// Earliest and latest instants we accept (1900-01-01 and 9999-12-31 UTC).
/// A device clock can't sensibly be outside this; clamping keeps the date
/// math far from chrono's limits so nothing here can panic.
const MIN_UNIX_SECONDS: i64 = -2_208_988_800;
const MAX_UNIX_SECONDS: i64 = 253_402_300_799;

/// Game day number for an instant given as Unix seconds. Out-of-range
/// instants are clamped (see [`MIN_UNIX_SECONDS`]).
#[uniffi::export]
pub fn game_day(unix_seconds: i64) -> i32 {
    let clamped = unix_seconds.clamp(MIN_UNIX_SECONDS, MAX_UNIX_SECONDS);
    let utc = DateTime::from_timestamp(clamped, 0).expect("clamped into chrono's range");
    let eastern = utc.with_timezone(&New_York).naive_local();
    // Shift so 11 pm lands on midnight of the next calendar date.
    let shifted = eastern + Duration::hours(24 - DAY_START_HOUR_ET);
    (shifted.date() - EPOCH).num_days() as i32
}

/// ISO date (YYYY-MM-DD) naming a game day, for parent screens and logs.
/// Never panics: a day number chrono can't represent comes back as "day N".
#[uniffi::export]
pub fn game_day_label(day: i32) -> String {
    EPOCH
        .checked_add_signed(Duration::days(i64::from(day)))
        .map(|date| date.format("%Y-%m-%d").to_string())
        .unwrap_or_else(|| format!("day {day}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use proptest::prelude::*;

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
    fn day_rolls_over_at_11pm_eastern() {
        assert_eq!(label_at(et(2026, 11, 8, 22, 59)), "2026-11-08");
        assert_eq!(label_at(et(2026, 11, 8, 23, 0)), "2026-11-09");
        assert_eq!(label_at(et(2026, 11, 9, 0, 30)), "2026-11-09");
        assert_eq!(label_at(et(2026, 11, 9, 22, 59)), "2026-11-09");
    }

    #[test]
    fn follows_daylight_saving() {
        // Summer (EDT, UTC-4): 11 pm ET is 03:00 UTC.
        let summer = et(2026, 7, 1, 23, 0);
        assert_eq!(label_at(summer), "2026-07-02");
        assert_eq!(label_at(summer - 1), "2026-07-01");
        // Winter (EST, UTC-5): 11 pm ET is 04:00 UTC.
        let winter = et(2026, 1, 15, 23, 0);
        assert_eq!(label_at(winter), "2026-01-16");
        assert_eq!(label_at(winter - 1), "2026-01-15");
    }

    #[test]
    fn dst_transition_days_are_normal_length_at_the_boundary() {
        // Clocks change at 2 am, well away from the 11 pm boundary.
        assert_eq!(label_at(et(2026, 3, 8, 22, 59)), "2026-03-08");
        assert_eq!(label_at(et(2026, 3, 8, 23, 0)), "2026-03-09");
        assert_eq!(label_at(et(2026, 11, 1, 22, 59)), "2026-11-01");
        assert_eq!(label_at(et(2026, 11, 1, 23, 0)), "2026-11-02");
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

    /// Day numbers are stored on the iPad, so their values must never shift.
    #[test]
    fn day_numbers_are_pinned() {
        assert_eq!(game_day(et(2026, 11, 9, 12, 0)), 20_766);
        assert_eq!(game_day_label(20_766), "2026-11-09");
        // 1970-01-01 00:00 UTC is 7 pm ET on Dec 31, 1969: before 11 pm.
        assert_eq!(game_day(0), -1);
    }

    #[test]
    fn repeated_hour_on_fall_back_day_is_one_day() {
        // Nov 1 2026, 1:30 am happens twice (EDT then EST); both are Nov 1.
        let first = New_York
            .with_ymd_and_hms(2026, 11, 1, 1, 30, 0)
            .earliest()
            .unwrap()
            .timestamp();
        let second = first + 3600;
        assert_eq!(label_at(first), "2026-11-01");
        assert_eq!(label_at(second), "2026-11-01");
    }

    #[test]
    fn extreme_inputs_do_not_panic() {
        assert_eq!(game_day(i64::MIN), game_day(MIN_UNIX_SECONDS));
        assert_eq!(game_day(i64::MAX), game_day(MAX_UNIX_SECONDS));
        assert_eq!(game_day_label(i32::MAX), format!("day {}", i32::MAX));
        assert_eq!(game_day_label(i32::MIN), format!("day {}", i32::MIN));
    }

    proptest! {
        #[test]
        fn noon_on_consecutive_dates_is_consecutive_days(offset in 0i64..47_000) {
            // Any date from 1970 to ~2098.
            let date = EPOCH + Duration::days(offset);
            let noon = |d: NaiveDate| New_York
                .from_local_datetime(&d.and_hms_opt(12, 0, 0).unwrap())
                .single()
                .unwrap()
                .timestamp();
            prop_assert_eq!(game_day(noon(date + Duration::days(1))) - game_day(noon(date)), 1);
            prop_assert_eq!(game_day_label(game_day(noon(date))), date.format("%Y-%m-%d").to_string());
        }
    }

    #[test]
    fn leap_day_is_a_game_day_of_its_own() {
        assert_eq!(label_at(et(2028, 2, 28, 12, 0)), "2028-02-28");
        assert_eq!(label_at(et(2028, 2, 29, 12, 0)), "2028-02-29");
        assert_eq!(label_at(et(2028, 3, 1, 12, 0)), "2028-03-01");
        assert_eq!(
            game_day(et(2028, 3, 1, 12, 0)) - game_day(et(2028, 2, 28, 12, 0)),
            2
        );
    }

    #[test]
    fn rollover_is_11pm_in_every_month() {
        for month in 1..=12 {
            assert_eq!(
                label_at(et(2027, month, 10, 22, 59)),
                format!("2027-{month:02}-10")
            );
            assert_eq!(
                label_at(et(2027, month, 10, 23, 0)),
                format!("2027-{month:02}-11")
            );
        }
    }

    #[test]
    fn new_year_rolls_over_at_11pm_on_new_years_eve() {
        assert_eq!(label_at(et(2026, 12, 31, 22, 59)), "2026-12-31");
        assert_eq!(label_at(et(2026, 12, 31, 23, 0)), "2027-01-01");
    }
}
