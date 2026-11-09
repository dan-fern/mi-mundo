//! Checks the real bundled physical features (apple/MiMundo/Resources/
//! Features.bin) against well-known places.

use mimundo_core::map::{FeatureKind, PhysicalFeature, equal_earth, load_features};

fn features() -> Vec<PhysicalFeature> {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../apple/MiMundo/Resources/Features.bin"
    );
    load_features(std::fs::read(path).expect("Features.bin is committed")).expect("loads")
}

fn find<'a>(all: &'a [PhysicalFeature], kind: FeatureKind, name: &str) -> &'a PhysicalFeature {
    all.iter()
        .find(|f| f.kind == kind && f.name == name)
        .unwrap_or_else(|| panic!("no {kind:?} named {name}"))
}

/// Label lies within `degrees` of a lon/lat (compared in map units).
fn label_near(f: &PhysicalFeature, lon: f64, lat: f64, degrees: f64) -> bool {
    let (x, y) = equal_earth(lon, lat);
    let (dx, dy) = (f.label_x as f64 - x, f.label_y as f64 - y);
    (dx * dx + dy * dy).sqrt() < degrees.to_radians()
}

#[test]
fn has_every_kind() {
    let all = features();
    for kind in [
        FeatureKind::River,
        FeatureKind::Lake,
        FeatureKind::Desert,
        FeatureKind::Range,
        FeatureKind::Peak,
    ] {
        assert!(
            all.iter().filter(|f| f.kind == kind).count() >= 20,
            "{kind:?}"
        );
    }
}

#[test]
fn famous_features_are_where_they_belong() {
    let all = features();
    assert!(label_near(
        find(&all, FeatureKind::Desert, "Sahara"),
        10.0,
        22.0,
        15.0
    ));
    assert!(label_near(
        find(&all, FeatureKind::Range, "Himalayas"),
        84.0,
        29.0,
        8.0
    ));
    assert!(label_near(
        find(&all, FeatureKind::Range, "Andes"),
        -68.0,
        -20.0,
        25.0
    ));
    assert!(label_near(
        find(&all, FeatureKind::Lake, "Lake Victoria"),
        33.0,
        -1.0,
        2.0
    ));
    let everest = find(&all, FeatureKind::Peak, "Mount Everest");
    assert!(label_near(everest, 86.93, 27.99, 0.5));
    assert_eq!(everest.elevation_m, 8848);
}

#[test]
fn big_features_show_early_and_small_ones_later() {
    let all = features();
    let first_nile = all
        .iter()
        .filter(|f| f.kind == FeatureKind::River && f.name == "Nile")
        .map(|f| f.min_zoom)
        .fold(f32::MAX, f32::min);
    assert_eq!(first_nile, 1.0, "the Nile is visible at whole-world zoom");
    assert!(
        all.iter()
            .any(|f| f.kind == FeatureKind::River && f.min_zoom >= 8.0)
    );
    assert!(all.iter().all(|f| f.label_min_zoom >= f.min_zoom));
}

#[test]
fn area_labels_sit_inside_their_own_shape() {
    use mimundo_core::map::geometry::point_in_rings;
    let all = features();
    let outside: Vec<&str> = all
        .iter()
        .filter(|f| {
            matches!(
                f.kind,
                FeatureKind::Lake | FeatureKind::Desert | FeatureKind::Range
            )
        })
        .filter(|f| !point_in_rings(&f.parts, f.label_x, f.label_y))
        .map(|f| f.name.as_str())
        .collect();
    assert!(
        outside.is_empty(),
        "labels outside their shape: {outside:?}"
    );
}

#[test]
fn names_are_tidy_english() {
    let all = features();
    for f in &all {
        assert_eq!(f.name.trim(), f.name, "untrimmed name {:?}", f.name);
        assert!(!f.name.contains("  "), "double space in {:?}", f.name);
        assert!(f.label_angle.abs() <= std::f32::consts::FRAC_PI_2 + 1e-4);
    }
    // Local or headwater names that must have been renamed or dropped.
    for local in [
        "Amazonas",
        "Rhein",
        "Firat",
        "Al Furat",
        "Huang",
        "Tongtian",
        "Damqogkanbab",
        "Madison",
        "Punjab",
        "Ahag",
        "Appennino Ligure",
        "Gora Elbrus",
    ] {
        assert!(
            all.iter().all(|f| f.name != local),
            "{local} is still in Features.bin"
        );
    }
    for (kind, name) in [
        (FeatureKind::River, "Amazon"),
        (FeatureKind::River, "Euphrates"),
        (FeatureKind::River, "Mississippi"),
        (FeatureKind::River, "Yangtze"),
        (FeatureKind::River, "Danube"),
        (FeatureKind::Range, "Apennines"),
        (FeatureKind::Desert, "Gobi Desert"),
        (FeatureKind::Peak, "Mount Fuji"),
        (FeatureKind::Peak, "Matterhorn"),
    ] {
        find(&all, kind, name);
    }
}

#[test]
fn quiz_reveals_go_to_the_right_country() {
    use mimundo_core::map::World;
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../apple/MiMundo/Resources/World.bin"
    );
    let world = World::new(std::fs::read(path).unwrap()).unwrap();
    let countries = world.countries();
    let all = features();
    // The app reveals a feature's name with the country under its label.
    for (kind, name, iso2) in [
        (FeatureKind::Lake, "Lake Malawi", "MW"),
        (FeatureKind::Lake, "Lake Titicaca", "PE"),
        (FeatureKind::Peak, "Mount Fuji", "JP"),
        (FeatureKind::Peak, "Matterhorn", "CH"),
        (FeatureKind::Peak, "Mount Everest", "NP"),
    ] {
        let f = find(&all, kind, name);
        let at = world
            .country_at(f.label_x, f.label_y, 0.01)
            .map(|i| countries[i as usize].iso2.clone());
        assert_eq!(at.as_deref(), Some(iso2), "{name}");
    }
}
