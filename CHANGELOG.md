# Changelog

All notable changes to Mi Mundo are recorded here. Every PR adds a line under
**Unreleased**, describing what changed and why. When a build goes onto the
iPad as a named version, the Unreleased entries move under that version.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions: [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Physical features on the map (requirements §3.1): rivers, lakes,
  deserts, mountain ranges and peaks from Natural Earth, with names that
  appear as you zoom in (bigger features first), placed so they don't
  overlap. Built by a new Rust `featuregen` into `Features.bin`, with tests
  against known places and a CI reproducibility check.
- Landmarks: up to three famous places per country, pinned on the map from
  zoom 4 and listed on the card. UNESCO sites ranked by Wikipedia coverage,
  hand-picked lists for ~55 countries, and heavy topics (memorials, camps,
  prisons) never picked automatically.
- Country card: read-aloud button and a one-to-five-people population
  picture, for kids who can't read yet (PR #8 review).
- A star marks the capital (each capital, for countries with several) of the
  selected country; the card's Capital row uses the same star. Capital
  locations come from a new committed Wikidata snapshot
  (`tools/wikidata-capitals.json`, `tools/fetch-capitals.py`), and the build
  fails if a capital has no location or lies outside its country.
- From the PR #9 review:
  - Lake, desert and range labels now always sit inside their shape. The
    label maths had lost precision, and concave lakes now use their deepest
    point. A test checks every label.
  - English river and range names (Amazon, Euphrates, Apennines…), with
    delta channels, non-deserts and minor US peaks dropped and Fuji, the
    Matterhorn and other famous peaks added.
  - Landmarks: no automatic picks that sit in another country, repeat a
    site or are named after the capital. Hand-picked lists for Ireland,
    Panama, Vatican City, North Macedonia, Hungary, Sudan, Malaysia and
    Singapore. Capital fixes for Cyprus, Mexico and Yemen.
  - In quiz mode, names that name a country not yet guessed (the Niger,
    Lake Chad) stay hidden, and so does the capital star.
  - Read-aloud works with the silent switch on, uses the device language,
    pauses between sentences, stops when the app goes to the background,
    and has a bigger button away from Close. The star and pin on the card
    match the map's, and the population picture uses true powers of ten.
  - Smoother map: one shared label halo instead of one per label, steadier
    label placement, only the visible part of each river drawn, and
    nothing placed under the zoom buttons or the card.
  - Generated map files use pure-Rust maths (`libm`) so they rebuild
    byte-for-byte on any machine; featuregen fails on missing data
    instead of guessing; Wikidata fetches retry.
- Quiz label mode (requirements §3.2): feature and landmark names stay
  hidden until the country they sit in is guessed; the quiz PR switches it
  on.
- Explore map in the kid home (requirements §3.1): Equal Earth projection,
  pan, pinch and double-tap zoom, coarse outlines zoomed out and detailed
  ones zoomed in, no country labels so quiz answers stay hidden. Tap a
  country for a card with its flag, capital, population and languages.
  Projection, map format and tap-testing live in the Rust core with tests
  against real places, so the map can't silently drift.
- Data pipeline (`tools/`): Natural Earth outlines, Wikidata facts (with
  hand overrides) and flag-icons flags, built into committed bundle files;
  `THIRD_PARTY_NOTICES.md` credits the sources.
- Each kid's map position is remembered while the app runs, and "Switch
  player" asks first, so a stray tap doesn't lose a kid's place (PR #4
  review).
- From the PR #8 review: zoom-in / zoom-out / whole-world buttons; select
  on the first tap (no double-tap delay); the card opens on the side away
  from the country; a high-contrast highlight with a ring for tiny islands;
  smooth animated zooms; the world can't be dragged off screen; the map
  fits below the real height of the top bar; a Credits screen in parent
  mode (flag-icons MIT notice, "Made with Natural Earth").
- Places with no permanent residents (Antarctica, South Georgia, French
  Southern Lands, British Indian Ocean Territory) show no People row,
  instead of counting visiting researchers or base staff.
- Border policy (requirements §4): Crimea is drawn as part of Ukraine;
  Western Sahara's Moroccan-administered part stays Morocco; Israel and
  Palestine both list Jerusalem; Taiwan's capital is Taipei.
- Country facts: a committed, dated Wikidata snapshot; best-rank
  populations; ~110 hand fixes (capitals, language order, stale
  populations) applied offline; download checksums; CI checks the
  committed map data matches the tools.
- Pastel globe-in-a-graduation-cap app icon, drawn as an SVG in
  `apple/MiMundo/Design/` (original artwork, so no licensing questions).
- GitHub Actions CI on every PR and push to `main` (fmt, clippy, Rust tests,
  fresh-clone build, iPad simulator build), so a PR can't break the build
  without anyone noticing — there's no second human reviewer.
- Xcode rebuilds the Rust core before each build when `core/` has changed,
  and fails the build with the Rust error if it can't, so pressing Run never
  silently uses stale Rust. `build-core.sh` gains `--if-stale`,
  `--no-project` and `--check`. The stamp records the build's start time and
  profile, `--check` also catches a debug/release mismatch, and the script
  can't exit silently on a missing input (PR #3 review).
- "Who's playing?" launch screen with parent (PIN) and kid profiles,
  first-run parent setup, a kid-management parent home, and a placeholder
  kid home — the entry point every later feature hangs off.
- Attendance logging when a kid picks their profile, with the gauge next to
  their name and a day streak. Game days start at 10 pm US Eastern; that
  rule, the 7-day window and streaks live in the Rust core with tests so
  they can't drift between screens.
- Parent PIN lockout (30 s / 2 min / 10 min, kept across restarts) and
  "Forgot PIN?" via the iPad's Touch ID or passcode, so kids can't guess
  their way into parent mode and a forgotten PIN doesn't strand the parent.
- Kids can be edited, archived (hidden, progress kept, restorable) and only
  then deleted forever, so removing a kid is never an accident.
- Session records (who, game day, start, end) for every player, so the
  parent stats have history from day one.
- Versioned SwiftData schema (V1) with a migration plan, so later model
  changes don't lose data on the iPad.

### Changed
- Requirements v0.4: multiple parent (admin) accounts; kids can compare
  their quiz scores with their parents' on the same quiz (the family's only
  competition); one family quiz queue of up to 20 quizzes that serves the
  same quiz to everyone, moves on each day only if at least one kid
  attempted it (kids who didn't get no entry), wraps
  around with attempts reset, so practice can be set up ahead of time.
- Parent mode locks the moment the app leaves the screen; kids keep a
  10-minute grace period. Requirements v0.3 records these decisions.
- Build details moved off the parent home into a collapsed "Diagnostics".
- Attendance gauge shows empty segments as outlines and pulses its flame
  when full, so heat doesn't rely on color alone.

### Removed
- The scoring demo screen (`ContentView`), replaced by the launch flow.

### Fixed
- `game_day_label` / `game_day` can no longer panic on extreme input (that
  would crash the app). Day numbers are pinned by tests.
- Only US time zones are compiled in, cutting ~1.1 MB from the app.
- Failed saves roll back and log instead of failing silently.
- PIN pad Cancel/Delete have full-size tap targets.

### Added (earlier)
- Project scaffold — Rust core exported to Swift via UniFFI, a Swift package
  wrapping it, and an iPad-only SwiftUI app generated by XcodeGen — so game
  rules live in one tested place and the Xcode project stays reviewable.
- Retake scoring (full, ½, ¼, then 0; multiple choice halves; at least 1
  point for any correct answer on attempts 1–3) and the attendance gauge, so
  a kid is never shortchanged to 0 by rounding small point values.
- `--release` switch for `scripts/build-core.sh`, defaulting to a debug build
  (~15 s instead of ~2½ min) to keep day-to-day iteration fast.
- Pinned Rust toolchain and per-developer signing file
  (`Config/Local.xcconfig`) so builds match across machines and a real-iPad
  team ID survives project regeneration.

### Changed
- Requirements v0.2 records the scoring, attendance-day (10 pm ET), profile
  picker and override decisions from the PR #1 review.

### Fixed
- UniFFI's CLI is now only built for the Mac-side generator, shrinking the
  iPad library from ~81 MB to ~20 MB.
- Multi-window is off, so two windows can't hold conflicting quiz state.
- Child-facing text scales with the iPad's text-size setting.
- Build script fails clearly when a required tool is missing instead of
  reporting success.

### Added (planning)
- Requirements doc, README, MIT license, `.gitignore` and this changelog, to
  capture what we're building before writing code.
