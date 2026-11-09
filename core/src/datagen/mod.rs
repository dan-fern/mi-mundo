//! Mac-side map data builders (the `mapgen` feature; never in the app):
//! Natural Earth GeoJSON in, the app's binary map files out. The `mapgen`
//! and `featuregen` binaries are thin wrappers, so the logic is testable.

pub mod features;
pub mod world;

#[cfg(test)]
mod testutil;
