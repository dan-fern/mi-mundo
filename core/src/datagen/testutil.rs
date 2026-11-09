//! Helpers for the datagen tests: small GeoJSON files in a temp folder.

use std::path::PathBuf;

use serde_json::{Value, json};

/// A fresh, empty folder for one test.
pub fn temp_dir(test: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("mimundo-{test}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Writes a FeatureCollection and returns its path as a String.
pub fn write_collection(dir: &std::path::Path, name: &str, features: Vec<Value>) -> String {
    let path = dir.join(name);
    std::fs::write(
        &path,
        json!({"type": "FeatureCollection", "features": features}).to_string(),
    )
    .unwrap();
    path.to_string_lossy().into_owned()
}

/// A closed lon/lat rectangle ring.
pub fn rect(lon0: f64, lat0: f64, lon1: f64, lat1: f64) -> Value {
    json!([
        [lon0, lat0],
        [lon1, lat0],
        [lon1, lat1],
        [lon0, lat1],
        [lon0, lat0]
    ])
}
