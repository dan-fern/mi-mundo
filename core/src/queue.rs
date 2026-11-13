//! The family quiz queue (requirements §5.4): which quiz is "today's quiz".
//!
//! The queue is an ordered list of quiz ids (at most [`QUEUE_MAX`]) that is
//! played as a cycle. One quiz is today's; at the start of a new game day
//! the queue moves on to the next quiz **only if a kid attempted** the
//! current one, so a missed day never skips a quiz. Each time a quiz comes
//! up is a new *run* (attempts reset; see `scoring`).
//!
//! Swift stores the [`QueueState`] and calls [`queue_today`] whenever the
//! app comes to the front or the queue is edited; the call is idempotent.

/// Most quizzes the queue holds.
pub const QUEUE_MAX: u32 = 20;

/// Exported so Swift doesn't hard-code the limit.
#[uniffi::export]
pub fn queue_max() -> u32 {
    QUEUE_MAX
}

/// What the app remembers about the queue between launches.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct QueueState {
    /// Today's quiz; `None` while the queue is empty.
    pub current: Option<String>,
    /// Where `current` sat in the queue when last seen, so that if it is
    /// removed, the quiz that took its place comes up next.
    pub position: u32,
    /// Counts every time a quiz comes up. Attempts are numbered within a
    /// run, so they start again at 1 when a quiz comes back around.
    pub run: u32,
    /// Game day this state was last brought up to date.
    pub day: i32,
    /// A kid has attempted `current` during this run. Parents' attempts
    /// never set this, so a parent can't use up the kids' quiz.
    pub attempted_by_kid: bool,
    /// Someone (kid or parent) has started `current` today. While set, the
    /// app doesn't let parents edit or remove today's quiz.
    pub started: bool,
}

/// State for a brand-new install: no quiz yet.
#[uniffi::export]
pub fn queue_initial_state(today: i32) -> QueueState {
    QueueState {
        current: None,
        position: 0,
        run: 0,
        day: today,
        attempted_by_kid: false,
        started: false,
    }
}

/// Brings the state up to date for `today` and the queue as it is now.
///
/// - Empty queue: no quiz.
/// - No quiz yet, or today's quiz was removed from the queue: the quiz at
///   the remembered position comes up (a new run).
/// - A new game day and a kid attempted the current quiz: the next quiz in
///   the cycle comes up (a new run), even if that's the same quiz again
///   (a queue of one).
/// - A new game day and no kid attempted it: the same quiz stays up.
/// - Same day: nothing changes, except that `position` follows the quiz
///   if the queue was reordered.
/// - The clock went backwards (someone corrected a clock that was set
///   ahead): nothing moves on, but the state takes the earlier day, so the
///   queue isn't stuck until real time catches up with the wrong date.
#[uniffi::export]
pub fn queue_today(state: QueueState, queue: Vec<String>, today: i32) -> QueueState {
    let len = queue.len() as u32;
    let new_day = today > state.day;
    let day = today;
    if len == 0 {
        return QueueState {
            current: None,
            position: 0,
            day,
            attempted_by_kid: false,
            started: false,
            ..state
        };
    }
    let come_up = |index: u32| QueueState {
        current: Some(queue[index as usize].clone()),
        position: index,
        // Wrapping: the run is only ever compared for equality.
        run: state.run.wrapping_add(1),
        day,
        attempted_by_kid: false,
        started: false,
    };
    let found = state
        .current
        .as_ref()
        .and_then(|id| queue.iter().position(|q| q == id));
    match found {
        // Nothing current, or it was removed: whatever now sits in its place
        // (removing the last quiz wraps to the top, as the cycle would).
        None => come_up(state.position % len),
        Some(index) => {
            let index = index as u32;
            if new_day && state.attempted_by_kid {
                come_up((index + 1) % len)
            } else {
                QueueState {
                    position: index,
                    day,
                    // A new day lifts the edit lock even if the quiz stays.
                    started: state.started && !new_day,
                    ..state
                }
            }
        }
    }
}

/// The queue as a cycle starting from today's quiz: today's first, then the
/// ones that follow it, wrapping around. With no current quiz (or one not
/// in the queue) the queue is returned as is.
#[uniffi::export]
pub fn queue_from_today(queue: Vec<String>, current: Option<String>) -> Vec<String> {
    let start = current
        .and_then(|id| queue.iter().position(|q| *q == id))
        .unwrap_or(0);
    let mut ordered = queue;
    ordered.rotate_left(start);
    ordered
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn ids(names: &[&str]) -> Vec<String> {
        names.iter().map(|s| s.to_string()).collect()
    }

    fn current(state: &QueueState) -> Option<&str> {
        state.current.as_deref()
    }

    /// A state where `id` is today's quiz on `day`.
    fn playing(id: &str, position: u32, day: i32) -> QueueState {
        QueueState {
            current: Some(id.into()),
            position,
            run: 1,
            day,
            attempted_by_kid: false,
            started: false,
        }
    }

    #[test]
    fn an_empty_queue_has_no_quiz() {
        let state = queue_today(queue_initial_state(100), vec![], 100);
        assert_eq!(state.current, None);
        assert_eq!(state.run, 0);
    }

    #[test]
    fn the_first_quiz_added_is_todays_right_away() {
        let state = queue_today(queue_initial_state(100), ids(&["a", "b"]), 100);
        assert_eq!(current(&state), Some("a"));
        assert_eq!(state.run, 1);
        assert!(!state.attempted_by_kid && !state.started);
    }

    #[test]
    fn it_moves_on_the_day_after_a_kid_attempts() {
        let queue = ids(&["a", "b", "c"]);
        let mut state = playing("a", 0, 100);
        state.attempted_by_kid = true;
        // Later the same day: still a.
        assert_eq!(
            current(&queue_today(state.clone(), queue.clone(), 100)),
            Some("a")
        );
        let next = queue_today(state, queue, 101);
        assert_eq!(current(&next), Some("b"));
        assert_eq!((next.run, next.position, next.day), (2, 1, 101));
        assert!(!next.attempted_by_kid);
    }

    #[test]
    fn a_missed_day_never_skips_a_quiz() {
        let queue = ids(&["a", "b"]);
        let state = queue_today(playing("a", 0, 100), queue.clone(), 101);
        assert_eq!(current(&state), Some("a"));
        assert_eq!(state.run, 1, "same run: attempts don't reset");
        // A week away changes nothing either.
        let state = queue_today(state, queue, 108);
        assert_eq!(current(&state), Some("a"));
        assert_eq!(state.day, 108);
    }

    #[test]
    fn several_days_away_after_an_attempt_moves_on_only_once() {
        let mut state = playing("a", 0, 100);
        state.attempted_by_kid = true;
        let state = queue_today(state, ids(&["a", "b", "c"]), 105);
        assert_eq!(current(&state), Some("b"));
        // b hasn't been attempted, so it stays.
        assert_eq!(
            current(&queue_today(state, ids(&["a", "b", "c"]), 106)),
            Some("b")
        );
    }

    #[test]
    fn a_parent_starting_the_quiz_does_not_move_it_on() {
        let mut state = playing("a", 0, 100);
        state.started = true; // a parent played; no kid did
        let next = queue_today(state, ids(&["a", "b"]), 101);
        assert_eq!(current(&next), Some("a"));
        assert!(!next.started, "a new day lifts the edit lock");
    }

    #[test]
    fn the_edit_lock_holds_for_the_rest_of_the_day() {
        let mut state = playing("a", 0, 100);
        state.started = true;
        assert!(queue_today(state, ids(&["a", "b"]), 100).started);
    }

    #[test]
    fn the_end_of_the_queue_wraps_to_the_top() {
        let mut state = playing("c", 2, 100);
        state.attempted_by_kid = true;
        let next = queue_today(state, ids(&["a", "b", "c"]), 101);
        assert_eq!(current(&next), Some("a"));
        assert_eq!(next.position, 0);
    }

    #[test]
    fn a_queue_of_one_comes_back_as_a_fresh_run() {
        let mut state = playing("a", 0, 100);
        state.attempted_by_kid = true;
        let next = queue_today(state, ids(&["a"]), 101);
        assert_eq!(current(&next), Some("a"));
        assert_eq!(next.run, 2, "attempts start again at 1");
        assert!(!next.attempted_by_kid);
    }

    #[test]
    fn quizzes_added_at_the_end_are_played_before_the_wrap() {
        let mut state = playing("b", 1, 100);
        state.attempted_by_kid = true;
        // "c" was added while b was up.
        assert_eq!(
            current(&queue_today(state, ids(&["a", "b", "c"]), 101)),
            Some("c")
        );
    }

    #[test]
    fn todays_quiz_does_not_change_when_the_queue_is_reordered() {
        let state = queue_today(playing("a", 0, 100), ids(&["c", "b", "a"]), 100);
        assert_eq!(current(&state), Some("a"));
        assert_eq!((state.position, state.run), (2, 1));
        // …and tomorrow continues from where a now sits (wrapping to c).
        let mut attempted = state;
        attempted.attempted_by_kid = true;
        assert_eq!(
            current(&queue_today(attempted, ids(&["c", "b", "a"]), 101)),
            Some("c")
        );
    }

    #[test]
    fn removing_todays_quiz_brings_up_the_one_that_took_its_place() {
        let state = queue_today(playing("b", 1, 100), ids(&["a", "c", "d"]), 100);
        assert_eq!(current(&state), Some("c"));
        assert_eq!(state.run, 2);
        // Removing the last one wraps to the top, as the cycle would.
        let state = queue_today(playing("d", 3, 100), ids(&["a", "b", "c"]), 100);
        assert_eq!(current(&state), Some("a"));
    }

    #[test]
    fn emptying_the_queue_clears_today_and_refilling_starts_again() {
        let mut state = playing("a", 0, 100);
        state.attempted_by_kid = true;
        state.started = true;
        let empty = queue_today(state, vec![], 100);
        assert_eq!(empty.current, None);
        assert!(!empty.attempted_by_kid && !empty.started);
        let refilled = queue_today(empty, ids(&["z"]), 100);
        assert_eq!(current(&refilled), Some("z"));
        assert_eq!(refilled.run, 2);
    }

    #[test]
    fn a_clock_set_backwards_moves_nothing_on() {
        let mut state = playing("a", 0, 100);
        state.attempted_by_kid = true;
        let back = queue_today(state.clone(), ids(&["a", "b"]), 90);
        assert_eq!(current(&back), Some("a"));
        assert_eq!((back.run, back.attempted_by_kid), (1, true));
        assert_eq!(back.day, 90, "the state follows the corrected clock");
    }

    #[test]
    fn a_clock_set_ahead_then_corrected_does_not_freeze_the_queue() {
        // Someone sets the iPad to a date far ahead, then puts it right.
        let state = queue_today(playing("a", 0, 100), ids(&["a", "b"]), 900);
        let corrected = queue_today(state, ids(&["a", "b"]), 101);
        assert_eq!(corrected.day, 101);
        // The next real day still moves on after a kid's attempt.
        let mut attempted = corrected;
        attempted.attempted_by_kid = true;
        assert_eq!(
            current(&queue_today(attempted, ids(&["a", "b"]), 102)),
            Some("b")
        );
    }

    #[test]
    fn removing_todays_quiz_on_a_new_day_brings_up_its_replacement() {
        let mut state = playing("b", 1, 100);
        state.attempted_by_kid = true;
        let next = queue_today(state, ids(&["a", "c"]), 101);
        assert_eq!(current(&next), Some("c"));
        assert!(!next.attempted_by_kid, "a fresh run");
    }

    #[test]
    fn a_remembered_position_past_the_end_wraps() {
        let mut state = playing("gone", 7, 100);
        state.current = None;
        assert_eq!(
            current(&queue_today(state, ids(&["a", "b", "c"]), 100)),
            Some("b")
        );
    }

    #[test]
    fn the_run_counter_wraps_instead_of_sticking() {
        let mut state = playing("a", 0, 100);
        state.run = u32::MAX;
        state.attempted_by_kid = true;
        let next = queue_today(state, ids(&["a"]), 101);
        assert_eq!(next.run, 0, "still a different run");
    }

    #[test]
    fn from_today_rotates_the_cycle() {
        let queue = ids(&["a", "b", "c", "d"]);
        assert_eq!(
            queue_from_today(queue.clone(), Some("c".into())),
            ids(&["c", "d", "a", "b"])
        );
        assert_eq!(queue_from_today(queue.clone(), None), queue);
        assert_eq!(queue_from_today(queue.clone(), Some("zzz".into())), queue);
        assert!(queue_from_today(vec![], Some("a".into())).is_empty());
    }

    #[test]
    fn exported_max_matches_const() {
        assert_eq!(queue_max(), 20);
    }

    proptest! {
        /// Kids attempting every day play every quiz in order, round and
        /// round, with a new run each day.
        #[test]
        fn a_kid_playing_daily_meets_every_quiz_in_order(len in 1usize..=20, days in 1usize..60) {
            let queue: Vec<String> = (0..len).map(|i| format!("q{i}")).collect();
            let mut state = queue_today(queue_initial_state(0), queue.clone(), 0);
            for day in 0..days {
                prop_assert_eq!(state.current.as_deref(), Some(queue[day % len].as_str()));
                prop_assert_eq!(state.run as usize, day + 1);
                state.attempted_by_kid = true;
                state = queue_today(state, queue.clone(), day as i32 + 1);
            }
        }

        /// Whatever happens, calling again with the same inputs changes
        /// nothing, and today's quiz is always one that's in the queue.
        #[test]
        fn idempotent_and_always_in_the_queue(
            len in 0usize..=20,
            current in prop::option::of(0usize..25),
            position in 0u32..30,
            attempted: bool,
            started: bool,
            day in 0i32..10,
            today in 0i32..10,
        ) {
            let queue: Vec<String> = (0..len).map(|i| format!("q{i}")).collect();
            let state = QueueState {
                current: current.map(|i| format!("q{i}")),
                position,
                run: 7,
                day,
                attempted_by_kid: attempted,
                started,
            };
            let once = queue_today(state, queue.clone(), today);
            prop_assert_eq!(queue_today(once.clone(), queue.clone(), today), once.clone());
            match &once.current {
                None => prop_assert!(queue.is_empty()),
                Some(id) => prop_assert_eq!(queue.get(once.position as usize), Some(id)),
            }
        }

        /// However many days pass, the queue moves at most one quiz forward
        /// per attempt, and not at all without one.
        #[test]
        fn never_skips(len in 2usize..=20, start in 0usize..20, attempted: bool, gap in 1i32..400) {
            let start = start % len;
            let queue: Vec<String> = (0..len).map(|i| format!("q{i}")).collect();
            let mut state = playing(&queue[start], start as u32, 0);
            state.attempted_by_kid = attempted;
            let next = queue_today(state, queue.clone(), gap);
            let expected = if attempted { (start + 1) % len } else { start };
            prop_assert_eq!(next.current.as_deref(), Some(queue[expected].as_str()));
        }
    }
}
