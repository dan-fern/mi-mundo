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
        (2.35, 48.86, "FRA"),      // Paris
        (-77.04, 38.91, "USA"),    // Washington, D.C.
        (139.69, 35.69, "JPN"),    // Tokyo
        (-58.38, -34.60, "ARG"),   // Buenos Aires
        (28.04, -26.20, "ZAF"),    // Johannesburg
        (27.48, -29.31, "LSO"),    // Maseru: Lesotho is a hole in South Africa
        (149.13, -35.28, "AUS"),   // Canberra
        (37.62, 55.75, "RUS"),     // Moscow
        (77.21, 28.61, "IND"),     // New Delhi
        (-47.88, -15.79, "BRA"),   // Brasília
        (-175.0, 66.0, "RUS"),     // Chukotka, west of the ±180° seam
        (179.0, 68.0, "RUS"),      // Chukotka, east of the seam
        (178.0, -17.8, "FJI"),     // Fiji straddles the seam
        (12.4578, 43.9424, "SMR"), // San Marino, an enclave in Italy
        (34.10, 44.95, "UKR"),     // Simferopol: Crimea is part of Ukraine (§4)
        (33.52, 44.60, "UKR"),     // Sevastopol
        (37.62, 47.10, "UKR"),     // Mariupol
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

#[test]
fn iso_codes_are_unique() {
    let mut seen = std::collections::HashSet::new();
    for c in world().countries() {
        assert!(
            c.iso2 == "-99" || seen.insert(c.iso2.clone()),
            "duplicate {}",
            c.iso2
        );
        assert!(
            !c.name.trim().is_empty() && !c.continent.is_empty(),
            "{}",
            c.id
        );
    }
}

#[test]
fn every_country_lies_inside_the_world() {
    let (edge_x, _) = equal_earth(180.0, 0.0);
    let (_, edge_y) = equal_earth(0.0, 90.0);
    let (edge_x, edge_y) = (edge_x as f32 + 1e-4, edge_y.abs() as f32 + 1e-4);
    for c in world().countries() {
        assert!(c.min_x >= -edge_x && c.max_x <= edge_x, "{}", c.id);
        assert!(c.min_y >= -edge_y && c.max_y <= edge_y, "{}", c.id);
    }
}

#[test]
fn microstates_are_tappable_with_a_fingertip() {
    let w = world();
    for (lon, lat, expected) in [
        (7.42, 43.74, "MCO"),    // Monaco
        (12.433, 41.902, "VAT"), // Vatican City (as drawn by Natural Earth)
        (9.55, 47.15, "LIE"),    // Liechtenstein
        (166.93, -0.52, "NRU"),  // Nauru
        (179.2, -8.52, "TUV"),   // Tuvalu (Funafuti)
        (1.52, 42.51, "AND"),    // Andorra
    ] {
        assert_eq!(
            id_at(&w, lon, lat, 0.01).as_deref(),
            Some(expected),
            "{expected}"
        );
    }
}

#[test]
fn enclaves_win_over_the_country_around_them() {
    let w = world();
    assert_eq!(id_at(&w, 12.433, 41.902, 0.0).as_deref(), Some("VAT"));
    assert_eq!(id_at(&w, 12.49, 41.89, 0.0).as_deref(), Some("ITA")); // Rome, just outside
    assert_eq!(id_at(&w, 28.2, -29.6, 0.0).as_deref(), Some("LSO"));
    assert_eq!(id_at(&w, 26.0, -29.0, 0.0).as_deref(), Some("ZAF"));
}

#[test]
fn western_sahara_follows_the_border_policy() {
    // §4: the Moroccan-administered part is Morocco; east of the Berm stays
    // Western Sahara.
    let w = world();
    assert_eq!(id_at(&w, -13.2, 27.15, 0.0).as_deref(), Some("MAR")); // Laayoune
    assert_eq!(id_at(&w, -10.6, 26.15, 0.0).as_deref(), Some("SAH")); // Tifariti
}

#[test]
fn inland_and_coastal_seas_are_water() {
    let w = world();
    assert_eq!(id_at(&w, 51.0, 41.5, 0.0), None);
    assert_eq!(id_at(&w, 0.0, 0.0, 0.0), None); // Gulf of Guinea
}

#[test]
fn countries_do_not_overlap() {
    use mimundo_core::map::geometry::point_in_rings;
    let w = world();
    let fine = w.shapes(Detail::Fine);
    let meta = w.countries();
    let mut overlaps = Vec::new();
    for lat in (-60..=80).step_by(3) {
        for lon in (-180..180).step_by(3) {
            let (x, y) = equal_earth(f64::from(lon) + 0.5, f64::from(lat) + 0.5);
            let (x, y) = (x as f32, y as f32);
            let hits = fine
                .iter()
                .zip(&meta)
                .filter(|(_, m)| x >= m.min_x && x <= m.max_x && y >= m.min_y && y <= m.max_y)
                .filter(|(s, _)| point_in_rings(&s.rings, x, y))
                .count();
            if hits > 1 {
                overlaps.push((lon, lat));
            }
        }
    }
    assert!(overlaps.is_empty(), "overlaps at {overlaps:?}");
}

#[test]
fn far_south_is_only_antarctica() {
    let w = world();
    for lon in (-180..180).step_by(10) {
        let at = id_at(&w, f64::from(lon), -80.0, 0.0);
        assert!(matches!(at.as_deref(), Some("ATA") | None), "{lon}: {at:?}");
    }
    assert_eq!(id_at(&w, 0.0, -80.0, 0.0).as_deref(), Some("ATA"));
}

#[test]
fn coarse_outlines_are_never_more_detailed_than_fine_ones() {
    let w = world();
    let points = |s: &mimundo_core::map::CountryShape| s.rings.iter().map(Vec::len).sum::<usize>();
    let coarse = w.shapes(Detail::Coarse);
    let fine = w.shapes(Detail::Fine);
    let total = |v: &[mimundo_core::map::CountryShape]| v.iter().map(points).sum::<usize>();
    assert!(
        total(&coarse) * 4 < total(&fine),
        "coarse should be much lighter"
    );
    let heavier: Vec<String> = coarse
        .iter()
        .zip(&fine)
        .filter(|(c, f)| points(c) > points(f))
        .map(|(c, _)| w.countries()[c.index as usize].id.clone())
        .collect();
    assert!(heavier.len() <= 3, "coarse heavier than fine: {heavier:?}");
}

#[test]
fn labels_sit_on_their_country() {
    let w = world();
    let mut off = Vec::new();
    for c in w.countries() {
        if w.country_at(c.label_x, c.label_y, 0.02) != Some(c.index) {
            off.push(c.id.clone());
        }
    }
    assert!(off.len() <= 3, "labels off their country: {off:?}");
}
