//! Checks the real bundled map (apple/MiMundo/Resources/World.bin) against
//! known places, so a bad data rebuild fails CI instead of the app.

use mimundo_core::map::{Detail, World, equal_earth};

fn world() -> std::sync::Arc<World> {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../apple/MiMundo/Resources/World.bin"
    );
    World::new(std::fs::read(path).expect("World.bin is committed")).expect("World.bin loads")
}

/// Country id at a lon/lat, with the given tap tolerance in map units.
fn id_at(world: &World, lon: f64, lat: f64, tolerance: f32) -> Option<String> {
    let (x, y) = equal_earth(lon, lat);
    let countries = world.countries();
    world
        .country_at(x as f32, y as f32, tolerance)
        .map(|i| countries[i as usize].id.clone())
}

#[test]
fn has_every_country_with_both_detail_levels() {
    let w = world();
    let countries = w.countries();
    assert!(countries.len() >= 240, "only {} countries", countries.len());
    for shapes in [w.shapes(Detail::Coarse), w.shapes(Detail::Fine)] {
        assert_eq!(shapes.len(), countries.len());
        assert!(shapes.iter().all(|s| !s.rings.is_empty()));
    }
}

#[test]
fn capitals_land_in_their_countries() {
    let w = world();
    let cases = [
        (2.35, 48.86, "FRA"),    // Paris
        (-77.04, 38.91, "USA"),  // Washington, D.C.
        (139.69, 35.69, "JPN"),  // Tokyo
        (-58.38, -34.60, "ARG"), // Buenos Aires
        (28.04, -26.20, "ZAF"),  // Johannesburg
        (27.48, -29.31, "LSO"),  // Maseru: Lesotho is a hole in South Africa
        (149.13, -35.28, "AUS"), // Canberra
        (37.62, 55.75, "RUS"),   // Moscow
        (77.21, 28.61, "IND"),   // New Delhi
        (-47.88, -15.79, "BRA"), // Brasília
    ];
    for (lon, lat, expected) in cases {
        assert_eq!(
            id_at(&w, lon, lat, 0.0).as_deref(),
            Some(expected),
            "at {lon},{lat}"
        );
    }
}

#[test]
fn open_ocean_is_no_country() {
    let w = world();
    assert_eq!(id_at(&w, -30.0, 30.0, 0.0), None); // mid-Atlantic
    assert_eq!(id_at(&w, -150.0, 0.0, 0.0), None); // mid-Pacific
}

#[test]
fn tiny_countries_are_tappable_with_tolerance() {
    let w = world();
    // Just off Malta's coast: a miss exactly, a hit with a fingertip of slack.
    assert_eq!(id_at(&w, 14.65, 35.95, 0.0), None);
    assert_eq!(id_at(&w, 14.65, 35.95, 0.01).as_deref(), Some("MLT"));
}
