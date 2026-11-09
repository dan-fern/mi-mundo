//! Mi Mundo core: game rules shared with the SwiftUI app.
//!
//! Everything marked `#[uniffi::export]` is callable from Swift.

pub mod attendance;
#[cfg(feature = "mapgen")]
pub mod datagen;
pub mod days;
pub mod map;
pub mod scoring;

pub use attendance::{
    AttendanceSummary, attendance_level, attendance_level_for, attendance_summary, day_streak,
    days_played_last_7,
};
pub use days::{game_day, game_day_label};
pub use scoring::points_for_attempt;

uniffi::setup_scaffolding!();

/// Version of the Rust core, shown in the app so we can tell builds apart.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
