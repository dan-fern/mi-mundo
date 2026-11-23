//! The map data tools (mapgen, featuregen) as the CI runs them: wrong
//! arguments print usage and exit 2; a failed build says why and exits 1.
#![cfg(feature = "mapgen")]

use std::process::Command;

fn run(tool: &str, args: &[&str]) -> (i32, String) {
    let out = Command::new(tool)
        .args(args)
        .output()
        .expect("the tool runs");
    (
        out.status.code().expect("exited"),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

#[test]
fn mapgen_explains_its_arguments_and_reports_failures() {
    let mapgen = env!("CARGO_BIN_EXE_mapgen");
    let (code, err) = run(mapgen, &[]);
    assert_eq!(code, 2);
    assert!(err.contains("usage: mapgen"), "{err}");
    let (code, err) = run(
        mapgen,
        &[
            "/nonexistent/a.json",
            "/nonexistent/b.json",
            "/nonexistent/out.bin",
        ],
    );
    assert_eq!(code, 1);
    assert!(
        err.starts_with("mapgen: ") && err.contains("/nonexistent/a.json"),
        "{err}"
    );
}

#[test]
fn featuregen_explains_its_arguments_and_reports_failures() {
    let featuregen = env!("CARGO_BIN_EXE_featuregen");
    let (code, err) = run(featuregen, &["only-one"]);
    assert_eq!(code, 2);
    assert!(err.contains("usage: featuregen"), "{err}");
    let missing = [
        "/nonexistent/r",
        "/nonexistent/l",
        "/nonexistent/g",
        "/nonexistent/p",
        "/nonexistent/out",
    ];
    let (code, err) = run(featuregen, &missing);
    assert_eq!(code, 1);
    assert!(err.starts_with("featuregen: "), "{err}");
}
