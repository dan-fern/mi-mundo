//! World map: Equal Earth projection, the bundled country outlines and hit
//! testing. Requirements §3.1.

pub mod geometry;
pub mod projection;
pub mod world;

pub use projection::{MapPoint, equal_earth, project, world_outline};
pub use world::{CountryData, CountryMeta, CountryShape, Detail, MapError, World};
