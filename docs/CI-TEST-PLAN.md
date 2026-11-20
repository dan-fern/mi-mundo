# CI test coverage plan

Written 2026-11-14, to pick up on Wednesday. Nothing here is implemented yet.

## Where we are

- **Rust core (`core/`)** is well covered: about 190 unit and property tests
  plus 4 data-file test suites (World.bin, Features.bin, Countries.json,
  FlagLayouts.json). CI runs fmt, clippy and `cargo test --features mapgen`
  (64 proptest cases each) and checks the committed map data against the tools.
- **Swift app (`apple/MiMundo/`)** has **no tests at all**. CI only proves it
  compiles for the simulator. All the persistence, scoring glue, migrations and
  quiz flow live here, and that's where every bug we've hit so far came from:
  the streak not resetting, the edit lock, the V3→V4 migration, the card
  overflowing so "Check my flag" couldn't be tapped, and the thin-stripe flags
  passing freehand.
- **Budget:** keep CI under about 10 minutes (your earlier ask). Today it's
  roughly 6–7 minutes, mostly the Xcode build.

## Principles

1. Test anything that touches production data or points: SwiftData models,
   migrations, scoring, queue/lock rules, grading.
2. Put logic in Rust where we can (fast to test, 1 s per run) and keep Swift
   tests for what only Swift does: persistence, migrations and wiring.
3. Prefer a few fast unit tests over UI tests; add a small number of UI smoke
   tests only for flows that have broken before.

## Phase A: Swift test target (biggest gap, do first)

Add a `MiMundoTests` unit-test target in `project.yml` (hosted by the app,
in-memory `ModelContainer`) and run it in CI with `xcodebuild test` on the
simulator that's already built. That adds about 2–3 minutes.

Tests to write, by risk:

| Area | File(s) | Tests |
|---|---|---|
| **Migrations** | `Schema.swift`, `SchemaV3Frozen.swift`, `FlagDrawing.swift` | Commit a tiny fixture store for each old version (V1, V2, V3, V4) under `apple/MiMundoTests/Fixtures/`; open each with the current migration plan and assert that profiles, quizzes, attempts and answers survive. Add one fixture per future schema bump. This is the single most valuable test: a failed migration moves the family's data aside. |
| **Recording answers** | `QuizPlay.record`, `QuizAnswer.init` | Points per attempt (1st, 2nd, 3rd, 4th+), half points for multiple choice, a drawn flag at full points, a grader verdict overriding `chosen == correct`, a `FlagDrawing` saved with a drawn answer, and the `#Unique` attempt/country/kind constraint (a second answer is rejected, not duplicated). |
| **Queue and edit lock** | `QuizQueue.refresh/edit/remove/reorder` | The kid's first answer locks today's quiz; a parent's doesn't; the queue moves on at 11 pm ET only if a kid attempted; removing today's quiz; lock released after the queue moves. Use an injectable `now`. |
| **Parent review** | `DrawingReview.setVerdict` | Right → points for that attempt, wrong → 0, clear → back to the app's verdict, a missing answer doesn't crash. |
| **Targets and totals** | `QuizTarget.all`, `QuizSet.perfectPoints`, `QuizScoring.best` | City-states keep their capital question; places with no capital are skipped; flags only where a picture exists; Europe totals match what the editor shows. |
| **Choices** | `Atlas.choices` (with the real bundled atlas) | Flag look-alikes never appear together; the answer is always included; four choices; same seed gives the same buttons. |
| **Attendance / streak** | `Attendance.swift` | A missed day resets the streak (the bug from #14); the day boundary at 22:59 / 23:00 ET. |
| **PIN** | `PIN.swift` | Hash/verify round-trip, salts differ, lockout timings (30 s after 3 tries, 2 min after 5, 10 min after 7). |
| **Flag data in-app** | `FlagGrid`, `FreehandSelfCheck` | Turn the existing DEBUG `-flagSelfCheck` into a real test: every flag passes as its own drawing, every outline passes without its emblem, blank canvases fail. Run all 237 flags; the 55k-pair cross-check stays a local script. |

## Phase B: Rust gaps (cheap, all within the 1 s budget)

- `freehand.rs`: regression tests for **thin-stripe flags** (a Greece-like
  9-stripe flag drawn as 2 stripes should fail once we tighten it), plus a few
  golden real-flag grids exported from the app as fixtures.
- `flags.rs`: every layout's region count matches the Swift `FlagLayoutShape`
  (export the counts to a JSON fixture from Swift, or move the region
  geometry into Rust and test it there; the second is the better long-term
  fix).
- `queue.rs` / `days.rs`: DST transition days in US Eastern (the 11 pm
  boundary on the spring-forward and fall-back nights).
- `scoring.rs`: overflow/saturation at very large base points.
- A UniFFI round-trip smoke test in Swift (one call per exported function),
  so a bindings change can't drift silently.

## Phase C: a few UI smoke tests (optional, about 2 minutes)

XCUITest on the simulator, three flows only:
1. First run: create a parent, add a kid, reach kid home.
2. Kid plays one country end to end: name, capital, flag picked from four;
   the summary shows the points.
3. Freehand pad: open it, draw, check; "Check my flag" is visible and
   tappable (this broke once because the card overflowed).

Run them on `main` only, or nightly if they push CI past 10 minutes.

Done: target `MiMundoUITests`, driven by the DEBUG-only launch arguments
`-uiTesting` (in-memory store) and `-uiTestSeed` (parent, kid, one-country
France quiz), see `Sources/UITestLaunch.swift`. About 1.5 min locally, so CI
runs them on pushes to `main` and nightly, not on PRs.

## Phase D: CI plumbing

- Add `xcodebuild test` to the workflow (the build is already there, so it reuses the build products).
- Report Swift coverage with `xcrun xccov`, and Rust coverage with
  `cargo llvm-cov` on main only, uploaded as artifacts; no thresholds at
  first, so we only watch the trend.
- Keep PROPTEST_CASES=64 on PRs; maybe 256 nightly.
- Data-checker step: run `tools/check-flag-layouts.py` in CI (it only needs
  `sips`, which macOS runners have) so the flag data can't drift from the pictures.

## Suggested order and size

1. Phase A test target + migration fixtures + answer/queue tests (one PR).
2. The rest of Phase A + Phase D plumbing (one PR).
3. Phase B Rust gaps, including the thin-stripe grading fix if you want it
   stricter (one PR).
4. Phase C only if CI time allows.
