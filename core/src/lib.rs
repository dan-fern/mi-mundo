//! Mi Mundo core: game rules shared with the SwiftUI app.
//!
//! Everything marked `#[uniffi::export]` is callable from Swift.

pub mod attendance;
#[cfg(feature = "mapgen")]
pub mod datagen;
pub mod days;
pub mod flags;
pub mod freehand;
pub mod map;
pub mod queue;
pub mod quiz;
pub mod random_quiz;
pub mod scoring;

pub use attendance::{
    AttendanceSummary, attendance_level, attendance_level_for, attendance_summary, day_streak,
    days_played_last_7,
};
pub use days::{game_day, game_day_label};
pub use flags::{
    FlagOutlineGrade, flag_colours_match, flag_layout_choices, flag_layout_regions, flag_palette,
    grade_flag_outline,
};
pub use freehand::{
    DrawCredit, FreehandGrade, classify_pixels, draw_credit_percent, grade_freehand,
    mirror_credit_allowed,
};
pub use queue::{
    QueueState, queue_from_today, queue_initial_state, queue_max, queue_set_today, queue_today,
};
pub use quiz::{quiz_choices, quiz_stars};
pub use random_quiz::{QuizCandidate, RandomQuiz, RandomQuizScope, random_quiz, shuffled_queue};
pub use scoring::{points_for_attempt, points_with_credit};

uniffi::setup_scaffolding!();

/// Version of the Rust core, shown in the app so we can tell builds apart.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
