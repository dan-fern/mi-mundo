# Mi Mundo — Requirements

_Status: draft v0.2 · 2026-11-08_

A gamified geography app for a family: kids explore and get quizzed on a
world map, parents choose what to practise, set rewards and track progress.
Age-agnostic — fun for a young child, still useful for an adult.

## 1. Platform & constraints

| Item | Decision |
|---|---|
| First device | iPad mini 6 (iPadOS, Apple Pencil 2 + finger input) |
| UI | SwiftUI |
| Core logic | Rust, bridged to Swift with UniFFI (XCFramework) |
| Connectivity | Fully usable offline; refreshes map/fact data and syncs stats when online |
| Distribution | Sideload from Xcode for now; App Store possibly later |
| Source | Public, open source (MIT) on GitHub (`dan-fern/mi-mundo`) |
| Change tracking | Every PR adds an entry to `CHANGELOG.md` |

## 2. Accounts

- **Parent** accounts (PIN-protected) and **child** accounts (one per kid).
- Local profiles on the device to start; cross-device sync (CloudKit) later.
- On launch the app asks **who's playing**. Picking a child goes straight to
  the explore worldview and logs attendance for that child (§3.7); picking a
  parent asks for the PIN and does not log attendance.
- After the app has been in the background for 10 minutes or more, it asks
  who's playing again. Coming back sooner keeps the same player (and logs
  attendance again if a new day has started).
- First launch sets up the parent (name, avatar, PIN entered twice); the
  parent then adds kids (name + avatar) from parent mode.
- Children never compete with each other (no head-to-head rankings for now).

## 3. Child mode

### 3.1 Explore mode
- Free-panning, zoomable world map ("worldview pane"), drawn by the app —
  **no built-in country labels**, so the map never gives quiz answers away.
- Tap any country to see a card with: name, capital, flag, approximate
  population, top 1–3 languages, 1–3 major landmarks.
- When zoomed in far enough, show major rivers, mountain ranges, deserts and
  landmarks.
- Low word count, large child-friendly fonts.

### 3.2 Quiz mode
- The parent pre-selects a region or a custom set of countries.
- The map zooms to that set; target countries get a coloured border.
- The child picks targets **in any order**; no timer.
- A corner counter shows how many countries are left.
- Question types per country:
  1. Country name
  2. Capital
  3. Flag (see 3.3)

### 3.3 Flag drawing
Escalating help, from hardest to easiest:

1. **Freehand** — draw the flag with Pencil or finger.
2. **Layout outline** (no point penalty) — pick a layout (stripes, cross,
   canton, …), fill regions with colours, then draw the emblem.
3. **Multiple choice** — half the points; **no penalty to stats**.

Grading:
- Automatically graded on colours and approximate placement.
- Very lenient on emblems and other hand-drawn detail.
- Every drawing and its automatic verdict is saved for parent review (5.3).

### 3.4 Scoring

| Attempt at a quiz | Points per correct answer |
|---|---|
| 1st | full |
| 2nd | ½ |
| 3rd | ¼ |
| 4th+ | 0 (still recorded in stats) |

- An **attempt is one quiz sitting**. Every question is scored again on each
  retake, including ones already answered correctly. The extra points from
  retakes are intended; the parent prices rewards to offset them.
- Flag multiple choice halves the points for that attempt, on top of the
  attempt factor (e.g. 2nd attempt + multiple choice = ¼).
- Fractions round down, but a correct answer on attempts 1–3 always earns
  **at least 1 point** (unless the parent set the question to 0).

### 3.5 Rewards shop
- Spend points on parent-defined rewards (often real-world, e.g. ice cream).
- Redemptions are logged for the parent.

### 3.6 Personal board (not a competition)
Shows the child's own:
- Total score
- Day streak
- Strongest countries
- Strongest continents
- Most improved area / continent / country over the last 30 days

### 3.7 Attendance gauge
- Shown next to the child's name.
- Counts days the child **picked their profile** in the last 7 days, capped
  at 5. Parent sessions never count.
- A day starts at **10 pm US Eastern time** (America/New_York, so it follows
  daylight saving), wherever the iPad is. The day streak uses the same
  definition.
- The gauge fills up and gets "hotter" in colour as it approaches 5.

## 4. Data & content

- Map geometry: Natural Earth (public domain) — countries, rivers, lakes,
  mountain ranges, deserts, populated places.
- Flags: open-source SVG flag set (MIT-licensed or similar).
- Country facts: Wikidata (CC0), bundled with the app and refreshed when online.
- Everything needed for explore and quiz modes ships with the app.

## 5. Parent mode

### 5.1 Setup
- Assign point values.
- Create rewards and their point prices.
- Choose regions or custom country sets for quizzes, per child.
- The app suggests areas to practise based on what each child is forgetting.

### 5.2 Stats & review
Pick a region, see each child's strengths and weaknesses. There are far more
stats here than in child mode:
- First-try accuracy per country, split by question type (name/capital/flag).
- Commonly confused pairs (e.g. Niger ↔ Nigeria).
- Memory strength and decay over time (drives the suggestions).
- Mastery heatmap of the region.
- Trends: accuracy, streak history, points earned vs. spent.
- Answer speed — recorded silently, never shown to the child.
- Hint usage: how often outlines / multiple choice were needed for flags.

### 5.3 Drawing review
- Browse every flag drawing with the app's verdict.
- Override any verdict and award any lost points. An overturned answer earns
  what that question was worth on that attempt, so each answer stores its
  scoring inputs (base points, attempt, multiple choice) when it's made.
- A reward balance may go negative (e.g. after an override is reversed);
  most rewards are redeemed outside the app, so this is an accepted edge case.

## 6. Open questions

- Whether answer-speed data should be recorded at all.
- Sync design once there is more than one device.
- Licensing if the app is ever sold (currently MIT).
