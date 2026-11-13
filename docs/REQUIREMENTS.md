# Mi Mundo — Requirements

_Status: draft v0.5 · 2026-11-08_

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
- **Any number of parents.** Every parent is an equal admin with their own
  PIN; any parent can add another parent from parent mode. The last parent
  can't be archived or deleted.
- Local profiles on the device to start; cross-device sync (CloudKit) later.
- On launch the app asks **who's playing**. Picking a child goes straight to
  the explore worldview and logs attendance for that child (§3.7); picking a
  parent asks for the PIN and does not log attendance.
- **Parent mode locks as soon as the app leaves the screen.** A kid's
  session survives up to 10 minutes in the background; after that the app
  asks who's playing again. Coming back sooner keeps the same kid (and logs
  attendance again if a new day has started).
- First launch sets up the parent (name, avatar, PIN entered twice); the
  parent then adds kids (name + avatar) from parent mode.
- **PIN:** 4 digits, stored as a salted hash. Wrong guesses lock the PIN pad
  for 30 s after 3, 2 min after 5, and 10 min after 7 or more (survives
  restarts). **Forgot PIN?** uses the iPad's own Touch ID / Face ID /
  passcode, then sets a new PIN.
- **Kids can be edited** (name, avatar) and **archived**: hidden from
  "Who's playing?" with all progress kept, and restorable. Deleting a kid
  forever is a separate, confirmed action on an archived kid.
- **Sessions** are recorded for every player (who, game day, start, end) so
  the parent stats (§5.2) have usage history from day one.
- Parent home shows the day-start rule; build details ("Diagnostics") are
  tucked away in a collapsed section.
- Children never compete with each other (no head-to-head rankings for now).
  The only competition is **kid vs. grown-ups** (§3.8).

## 3. Child mode

### 3.1 Explore mode
- Free-panning, zoomable world map ("worldview pane"), drawn by the app —
  **no built-in country labels**, so the map never gives quiz answers away.
- Tap any country to see a card with: name, capital, flag, approximate
  population, top 1–3 languages, 1–3 major landmarks.
- When zoomed in far enough, show major rivers, lakes, mountain ranges,
  peaks and deserts, with their names. Bigger features appear first
  (Natural Earth's own zoom hints).
- The selected country's capital is marked with a **star** (every capital,
  where a country has more than one), and its **landmarks are pinned**, at
  any zoom. Landmarks of other countries stay hidden so the map isn't
  cluttered.
- The card has a **read-aloud** button and shows population as a picture
  (one to five people) for kids who can't read numbers yet.
- Low word count, large child-friendly fonts.

### 3.2 Quiz mode
- The parent pre-selects a region or a custom set of countries — usually
  through the family **quiz queue** (§5.4), which picks **today's quiz**.
- The map zooms to that set; target countries get a coloured border.
- The child picks targets **in any order**; no timer.
- A corner counter shows how many countries are left.
- **Names stay hidden until earned:** landmark pins and the names of
  rivers, lakes, ranges, peaks and deserts are hidden in quiz mode (the
  rivers, lakes and peaks themselves still draw). Once a country is guessed
  correctly, the names inside it appear, and its landmark pins too (as a
  reward; no need to select it). A feature belongs to the country
  its label sits in (so Lake Geneva's name shows with France).
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
- Attempts are counted **per time the quiz comes up** in the queue (§5.4):
  when a quiz comes back around, its attempts reset to the 1st (full points).
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

### 3.8 Kid vs. grown-ups
- Parents take the **same quiz** as the kids: the family queue (§5.4) gives
  everyone the same quiz of the day. It plays exactly as it does for a kid.
- After a quiz, and on the personal board, the kid sees **their score next
  to each parent's** on that same quiz, e.g. "You 42 · Dad 38 · Mom 45",
  with a celebration when they beat a parent.
- Comparisons use **first attempts only** (a retake can't beat a parent's
  first try, and vice versa) from the same time the quiz came up, shown as
  points and as % correct.
- Parent scores are for comparison only: parents have no reward balance,
  never count toward attendance, and are left out of the kids' stats (§5.2).
- Kids never see each other's scores.
- **Later:** a points multiplier or special rewards when a kid beats a parent.

## 4. Data & content

- Map geometry: Natural Earth (public domain) — countries, rivers, lakes,
  mountain ranges, deserts, populated places.
- Flags: open-source SVG flag set (MIT-licensed or similar).
- Country facts: Wikidata (CC0), bundled with the app and refreshed when online.
- Landmarks: UNESCO World Heritage Sites from Wikidata, ranked by how many
  Wikipedias cover them, with hand-picked lists for ~55 well-known
  countries. Sad or heavy sites (memorials, camps, prisons) are never picked
  automatically.
- Everything needed for explore and quiz modes ships with the app.
- **Borders and disputed places** (Dan's decisions; the map otherwise follows
  Natural Earth's default, de facto borders):
  - **Crimea is part of Ukraine** (moved from Russia by `mapgen`'s TRANSFERS
    table, with a test).
  - **Western Sahara**: the Moroccan-administered part is shown as Morocco;
    the strip east of the Berm stays "Western Sahara".
  - **Israel and Palestine** may both list Jerusalem as a capital
    (Israel: Jerusalem; Palestine: East Jerusalem, Ramallah).
  - **Taiwan** is shown as its own country with its capital, Taipei.
  - Other disputed places (Kosovo, Northern Cyprus, Somaliland) are shown as
    in Natural Earth / Wikidata.

## 5. Parent mode

### 5.1 Setup
- Assign point values.
- Create rewards and their point prices.
- Choose regions or custom country sets for quizzes (via the family quiz
  queue, §5.4).
- The app suggests areas to practise based on what each child is forgetting.
- Add, edit and archive other parents (§2).

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

### 5.4 Quiz queue
So a parent can set up practice ahead of time (e.g. before work travel):
- **One family queue** of up to 20 quizzes, shared by every kid and parent.
  A queued quiz is a region or custom set of countries plus its question
  types and point values.
- The front of the queue is **today's quiz** for everyone. At the start of
  each game day (10 pm US Eastern, §3.7) the queue moves on to the next quiz
  **if at least one kid attempted** the current one. If no kid did, the same
  quiz stays up, so a missed day never skips a quiz. Parents' attempts don't
  count, so a parent can never use up the kids' quiz.
- A kid who doesn't attempt a quiz before it moves on simply has **no entry**
  for it: no score, no zero, and nothing counted against them in stats. They
  meet it again the next time the queue wraps around.
- At the end of the queue it **starts over from the top**. Quizzes added in
  the meantime go on the end, so they're played before it wraps around.
- **Each time a quiz comes up again it's a fresh start:** attempts reset to
  the 1st, worth full points (§3.4).
- Parents can add, edit, reorder and remove queued quizzes and see which one
  is today's and which comes next. Today's quiz stays today's whatever is
  reordered or added, and **once anyone has started it, it can't be edited
  or removed until the next game day**. Before that a parent may still fix
  or remove it (removing it brings up the quiz that takes its place).
- The first quiz added to an empty queue is today's quiz straight away.
- A quiz is built from a **whole region** (the independent countries of a
  continent) or any hand-picked set, territories included if wanted.
- An empty queue means no quiz of the day (explore mode still works).

## 6. Open questions

- Whether answer-speed data should be recorded at all.
- Sync design once there is more than one device.
- Licensing if the app is ever sold (currently MIT).

## 7. Design notes (data model sketch)

How the v0.4 features fit the on-device data (SwiftData, versioned schema):

| Model | Key fields | Notes |
|---|---|---|
| `Profile` | role (parent/child), name, avatar, PIN, archivedAt | Already exists; multiple parents need no schema change. |
| `QuizSet` | id, title, country codes, question types, point values, position, createdBy, removedAt | One quiz in the family queue (max 20), ordered by position. Removing it sets `removedAt` so old attempts can still name it. (Built; there is no separate `QueueEntry`.) |
| `QueueRecord` | current quiz, position, run number, day last checked, attempted by a kid, started by anyone | Single record mirroring the Rust core's `QueueState`. At a new game day it advances only if at least one kid attempted it; each advance starts a new run. The "today's quiz" rule lives in the Rust core (`core/src/queue.rs`) so it's unit-tested. (Built.) |
| `Attempt` | id, profileID, quizSetID, run number, game day, attempt number, started/finished | One quiz sitting by anyone, kid or parent. Attempt numbers count within a run, so they reset when a quiz comes back around. |
| `Answer` | attemptID, country, question type, correct, base points, multiple choice, points awarded | Scoring inputs stored per answer (§5.3). |

Kid-vs-grown-up comparisons are then a query: first `Attempt` per profile
for a given `QuizSet` and run.
