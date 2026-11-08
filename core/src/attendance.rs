//! Attendance gauge (requirements §3.7).

/// Highest level the gauge shows.
pub const ATTENDANCE_MAX: u32 = 5;

/// Highest gauge level, exported so the Swift gauge doesn't hard-code it
/// (UniFFI can't export constants directly).
#[uniffi::export]
pub fn attendance_max() -> u32 {
    ATTENDANCE_MAX
}

/// Gauge level from the number of distinct days the app was opened in the
/// last 7 days. Capped at [`ATTENDANCE_MAX`], the fullest and "hottest" level.
#[uniffi::export]
pub fn attendance_level(days_opened_last_7: u32) -> u32 {
    days_opened_last_7.min(ATTENDANCE_MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
