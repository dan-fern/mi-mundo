//! Mi Mundo core: game rules shared with the SwiftUI app.
//!
//! Everything marked `#[uniffi::export]` is callable from Swift.

pub mod attendance;
pub mod scoring;

pub use attendance::attendance_level;
pub use scoring::points_for_attempt;

uniffi::setup_scaffolding!();

/// Version of the Rust core, shown in the app so we can tell builds apart.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
