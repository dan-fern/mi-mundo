//! Checks the bundled flag outlines (apple/MiMundo/Resources/FlagLayouts.json,
//! written by tools/check-flag-layouts.py) against the core's layouts and
//! paint box, and against the flag pictures and countries the app has.

use std::collections::BTreeSet;

use mimundo_core::flags::{FLAG_LAYOUTS, PALETTE, flag_layout_regions, grade_flag_outline};
use serde_json::Value;

const RESOURCES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../apple/MiMundo/Resources");

fn outlines() -> serde_json::Map<String, Value> {
    let text = std::fs::read_to_string(format!("{RESOURCES}/FlagLayouts.json")).unwrap();
    serde_json::from_str::<Value>(&text)
        .unwrap()
        .as_object()
        .unwrap()
        .clone()
}

fn colours(entry: &Value) -> Vec<String> {
    entry["colors"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c.as_str().unwrap().to_string())
        .collect()
}

#[test]
fn every_outline_uses_a_known_layout_with_the_right_number_of_colours() {
    for (code, entry) in outlines() {
        let layout = entry["layout"].as_str().unwrap();
        let regions = flag_layout_regions(layout.to_string());
        assert!(regions > 0, "{code}: unknown layout {layout}");
        assert_eq!(
            colours(&entry).len(),
            regions as usize,
            "{code}: colours for {layout}"
        );
        assert!(entry["emblem"].is_boolean(), "{code}: emblem flag");
    }
}

#[test]
fn every_colour_is_in_the_paint_box() {
    for (code, entry) in outlines() {
        for colour in colours(&entry) {
            assert!(PALETTE.contains(&colour.as_str()), "{code}: {colour}");
        }
    }
}

#[test]
fn every_outline_has_a_flag_picture() {
    for code in outlines().keys() {
        let png = format!("{RESOURCES}/Flags.xcassets/flag-{code}.imageset/flag-{code}.png");
        assert!(
            std::path::Path::new(&png).exists(),
            "{code}: no flag picture"
        );
    }
}

#[test]
fn painting_the_data_grades_right() {
    for (code, entry) in outlines() {
        let layout = entry["layout"].as_str().unwrap().to_string();
        let g = grade_flag_outline(layout.clone(), colours(&entry), layout, colours(&entry));
        assert!(g.correct, "{code}");
    }
}

#[test]
fn most_flags_and_most_layouts_are_covered() {
    let all = outlines();
    // Most of the ~240 flags fit an outline; the rest stay pick-from-four.
    assert!(all.len() >= 150, "only {} outlines", all.len());
    let used: BTreeSet<&str> = all
        .values()
        .map(|e| e["layout"].as_str().unwrap())
        .collect();
    for (layout, _) in FLAG_LAYOUTS {
        assert!(
            used.contains(layout),
            "layout {layout} isn't used by any flag"
        );
    }
}

#[test]
fn well_known_flags_are_right() {
    let all = outlines();
    let check = |code: &str, layout: &str, want: &[&str]| {
        let e = &all[code];
        assert_eq!(e["layout"], layout, "{code}");
        assert_eq!(colours(e), want, "{code}");
    };
    check("fr", "v3", &["blue", "white", "red"]);
    check("de", "h3", &["black", "red", "yellow"]);
    check("jp", "disc", &["white", "red"]);
    check("se", "nordic", &["blue", "yellow"]);
    check("no", "nordic-bordered", &["red", "white", "blue"]);
    check("cz", "tri-h2", &["white", "red", "blue"]);
    check("jm", "saltire", &["green", "black", "yellow"]);
    check("ua", "h2", &["blue", "yellow"]);
}
