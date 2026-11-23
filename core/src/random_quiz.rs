//! Random quizzes and a shuffled queue (requirements §5.4): the parent asks
//! for a number of countries from one region, one continent, or anywhere,
//! and the app picks them. Seeded, so the same seed gives the same quiz.

use crate::quiz::SplitMix64;
use std::collections::BTreeMap;

/// A country the random quiz may pick, with where it is.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct QuizCandidate {
    pub id: String,
    /// Its quiz region (e.g. "Western Europe").
    pub region: String,
    pub continent: String,
}

/// Where a random quiz's countries come from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RandomQuizScope {
    /// All from one region, picked at random: neighbours.
    Region,
    /// All from one continent, picked at random.
    Continent,
    /// From anywhere.
    World,
}

/// A random quiz: the countries (sorted by id), and the region or continent
/// they came from (nil for the whole world).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RandomQuiz {
    pub country_ids: Vec<String>,
    pub area: Option<String>,
}

/// Picks `count` different countries for a random quiz.
///
/// For a region or continent, one is picked at random among those with at
/// least `count` countries. If none is that big, the biggest is used whole
/// (fewer countries than asked). Asking for more than there are gives all
/// of them; asking for 0 gives none.
#[uniffi::export]
pub fn random_quiz(
    candidates: Vec<QuizCandidate>,
    count: u32,
    scope: RandomQuizScope,
    seed: u64,
) -> RandomQuiz {
    if count == 0 {
        return RandomQuiz {
            country_ids: Vec::new(),
            area: None,
        };
    }
    let mut rng = SplitMix64(seed);
    let mut unique: BTreeMap<String, QuizCandidate> = BTreeMap::new();
    for c in candidates {
        unique.entry(c.id.clone()).or_insert(c);
    }
    let all: Vec<QuizCandidate> = unique.into_values().collect();
    let (pool, area): (Vec<&QuizCandidate>, Option<String>) = match scope {
        RandomQuizScope::World => (all.iter().collect(), None),
        RandomQuizScope::Region | RandomQuizScope::Continent => {
            let mut groups: BTreeMap<&str, Vec<&QuizCandidate>> = BTreeMap::new();
            for c in &all {
                let key = if scope == RandomQuizScope::Region {
                    &c.region
                } else {
                    &c.continent
                };
                // A country with no region or continent can't make one up.
                if !key.trim().is_empty() {
                    groups.entry(key.as_str()).or_default().push(c);
                }
            }
            let big: Vec<(&str, &Vec<&QuizCandidate>)> = groups
                .iter()
                .filter(|(_, members)| members.len() >= count as usize)
                .map(|(name, members)| (*name, members))
                .collect();
            let chosen = if big.is_empty() {
                // Biggest; ties go to the first name.
                groups
                    .iter()
                    .max_by(|a, b| a.1.len().cmp(&b.1.len()).then(b.0.cmp(a.0)))
                    .map(|(name, members)| (*name, members))
            } else {
                Some(big[rng.below(big.len())])
            };
            match chosen {
                Some((name, members)) => (members.clone(), Some(name.to_string())),
                None => (Vec::new(), None),
            }
        }
    };
    let mut ids: Vec<String> = sample(
        pool.iter().map(|c| c.id.clone()).collect(),
        count as usize,
        &mut rng,
    );
    ids.sort();
    RandomQuiz {
        country_ids: ids,
        area,
    }
}

/// The queue's quiz ids in a random order (every id once).
#[uniffi::export]
pub fn shuffled_queue(ids: Vec<String>, seed: u64) -> Vec<String> {
    let n = ids.len();
    sample(ids, n, &mut SplitMix64(seed))
}

/// The first `count` of a Fisher–Yates shuffle.
fn sample(mut items: Vec<String>, count: usize, rng: &mut SplitMix64) -> Vec<String> {
    let count = count.min(items.len());
    for i in 0..count {
        let j = i + rng.below(items.len() - i);
        items.swap(i, j);
    }
    items.truncate(count);
    items
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use std::collections::BTreeSet;

    fn c(id: &str, region: &str, continent: &str) -> QuizCandidate {
        QuizCandidate {
            id: id.into(),
            region: region.into(),
            continent: continent.into(),
        }
    }

    fn world() -> Vec<QuizCandidate> {
        vec![
            c("FRA", "Western Europe", "Europe"),
            c("DEU", "Western Europe", "Europe"),
            c("BEL", "Western Europe", "Europe"),
            c("NLD", "Western Europe", "Europe"),
            c("ESP", "Southern Europe", "Europe"),
            c("ITA", "Southern Europe", "Europe"),
            c("PRT", "Southern Europe", "Europe"),
            c("BRA", "South America", "South America"),
            c("ARG", "South America", "South America"),
            c("PER", "South America", "South America"),
            c("KEN", "East Africa", "Africa"),
            c("TZA", "East Africa", "Africa"),
        ]
    }

    fn region_of(id: &str) -> String {
        world().into_iter().find(|c| c.id == id).unwrap().region
    }

    fn continent_of(id: &str) -> String {
        world().into_iter().find(|c| c.id == id).unwrap().continent
    }

    #[test]
    fn a_region_quiz_stays_in_one_region_big_enough() {
        for seed in 0..100 {
            let q = random_quiz(world(), 3, RandomQuizScope::Region, seed);
            assert_eq!(q.country_ids.len(), 3);
            let area = q.area.clone().unwrap();
            assert!(
                q.country_ids.iter().all(|id| region_of(id) == area),
                "{q:?}"
            );
            // Only regions with at least 3 countries can be picked.
            assert!(
                ["Western Europe", "Southern Europe", "South America"].contains(&area.as_str())
            );
        }
    }

    #[test]
    fn a_continent_quiz_stays_on_one_continent() {
        for seed in 0..100 {
            let q = random_quiz(world(), 5, RandomQuizScope::Continent, seed);
            assert_eq!(q.area.as_deref(), Some("Europe"), "only Europe has 5");
            assert_eq!(q.country_ids.len(), 5);
            assert!(q.country_ids.iter().all(|id| continent_of(id) == "Europe"));
        }
    }

    #[test]
    fn every_big_enough_region_comes_up() {
        let areas: BTreeSet<String> = (0..200)
            .filter_map(|seed| random_quiz(world(), 2, RandomQuizScope::Region, seed).area)
            .collect();
        assert_eq!(areas.len(), 4, "{areas:?}");
    }

    #[test]
    fn too_many_for_any_region_uses_the_biggest_whole() {
        let q = random_quiz(world(), 9, RandomQuizScope::Region, 7);
        assert_eq!(q.area.as_deref(), Some("Western Europe"));
        assert_eq!(q.country_ids, ["BEL", "DEU", "FRA", "NLD"]);
    }

    #[test]
    fn a_world_quiz_can_mix_continents_and_caps_at_everything() {
        let continents: BTreeSet<String> = (0..50)
            .flat_map(|seed| random_quiz(world(), 4, RandomQuizScope::World, seed).country_ids)
            .map(|id| continent_of(&id))
            .collect();
        assert_eq!(continents.len(), 3);
        let all = random_quiz(world(), 99, RandomQuizScope::World, 1);
        assert_eq!(all.country_ids.len(), 12);
        assert_eq!(all.area, None);
    }

    #[test]
    fn zero_or_nothing_to_pick_from_gives_no_countries() {
        assert!(
            random_quiz(world(), 0, RandomQuizScope::World, 1)
                .country_ids
                .is_empty()
        );
        let empty = random_quiz(vec![], 5, RandomQuizScope::Region, 1);
        assert_eq!(
            empty,
            RandomQuiz {
                country_ids: vec![],
                area: None
            }
        );
    }

    #[test]
    fn no_countries_means_no_area() {
        let none = random_quiz(world(), 0, RandomQuizScope::Region, 1);
        assert_eq!(
            none,
            RandomQuiz {
                country_ids: vec![],
                area: None
            }
        );
    }

    #[test]
    fn a_blank_region_or_continent_is_never_an_area() {
        let mut list = world();
        list.push(c("XXA", "", ""));
        list.push(c("XXB", " ", " "));
        for seed in 0..50 {
            for scope in [RandomQuizScope::Region, RandomQuizScope::Continent] {
                let q = random_quiz(list.clone(), 2, scope, seed);
                assert!(
                    q.area.as_deref().is_some_and(|a| !a.trim().is_empty()),
                    "{q:?}"
                );
            }
        }
    }

    #[test]
    fn duplicates_are_picked_once() {
        let mut list = world();
        list.extend(world());
        let q = random_quiz(list, 12, RandomQuizScope::World, 3);
        assert_eq!(q.country_ids.len(), 12);
    }

    #[test]
    fn the_same_seed_gives_the_same_quiz_and_order() {
        let a = random_quiz(world(), 4, RandomQuizScope::World, 42);
        assert_eq!(a, random_quiz(world(), 4, RandomQuizScope::World, 42));
        let ids: Vec<String> = ["a", "b", "c", "d", "e"].map(String::from).to_vec();
        assert_eq!(shuffled_queue(ids.clone(), 5), shuffled_queue(ids, 5));
    }

    #[test]
    fn shuffling_varies_the_order() {
        let ids: Vec<String> = ["a", "b", "c", "d", "e"].map(String::from).to_vec();
        let orders: BTreeSet<Vec<String>> = (0..50)
            .map(|seed| shuffled_queue(ids.clone(), seed))
            .collect();
        assert!(orders.len() > 10);
    }

    #[test]
    fn a_one_country_quiz_works_in_every_scope() {
        for scope in [
            RandomQuizScope::Region,
            RandomQuizScope::Continent,
            RandomQuizScope::World,
        ] {
            for seed in 0..20 {
                let q = random_quiz(world(), 1, scope, seed);
                assert_eq!(q.country_ids.len(), 1, "{scope:?}");
                assert_eq!(q.area.is_some(), scope != RandomQuizScope::World);
            }
        }
    }

    #[test]
    fn a_region_exactly_big_enough_is_used_whole() {
        let mut seen = false;
        for seed in 0..100 {
            let q = random_quiz(world(), 3, RandomQuizScope::Region, seed);
            if q.area.as_deref() == Some("Southern Europe") {
                assert_eq!(q.country_ids, ["ESP", "ITA", "PRT"]);
                seen = true;
            }
        }
        assert!(seen, "Southern Europe (3 countries) comes up");
    }

    #[test]
    fn when_no_region_is_big_enough_a_tie_goes_to_the_first_name() {
        let small = vec![
            c("B1", "Bravo", "X"),
            c("B2", "Bravo", "X"),
            c("A1", "Alpha", "Y"),
            c("A2", "Alpha", "Y"),
        ];
        for seed in 0..20 {
            let q = random_quiz(small.clone(), 5, RandomQuizScope::Region, seed);
            assert_eq!(q.area.as_deref(), Some("Alpha"));
            assert_eq!(q.country_ids, ["A1", "A2"]);
        }
    }

    #[test]
    fn a_repeated_country_keeps_its_first_region() {
        let candidates = vec![
            c("FRA", "Western Europe", "Europe"),
            c("FRA", "Nowhere", "Nowhere"),
        ];
        let q = random_quiz(candidates, 1, RandomQuizScope::Region, 3);
        assert_eq!(q.area.as_deref(), Some("Western Europe"));
        assert_eq!(q.country_ids, ["FRA"]);
    }

    #[test]
    fn shuffling_nothing_or_one_quiz() {
        assert!(shuffled_queue(Vec::new(), 9).is_empty());
        assert_eq!(shuffled_queue(vec!["only".into()], 9), ["only"]);
    }

    proptest! {
        #[test]
        fn shuffle_keeps_every_quiz_once(n in 0usize..30, seed: u64) {
            let ids: Vec<String> = (0..n).map(|i| i.to_string()).collect();
            let mut out = shuffled_queue(ids.clone(), seed);
            out.sort();
            let mut sorted = ids;
            sorted.sort();
            prop_assert_eq!(out, sorted);
        }

        #[test]
        fn random_quizzes_are_distinct_known_countries(count in 0u32..20, seed: u64, which in 0usize..3) {
            let scope = [RandomQuizScope::Region, RandomQuizScope::Continent, RandomQuizScope::World][which];
            let q = random_quiz(world(), count, scope, seed);
            let set: BTreeSet<&String> = q.country_ids.iter().collect();
            prop_assert_eq!(set.len(), q.country_ids.len());
            prop_assert!(q.country_ids.len() <= count as usize);
            prop_assert!(q.country_ids.iter().all(|id| world().iter().any(|c| &c.id == id)));
        }
    }

    proptest! {
        #[test]
        fn the_order_candidates_come_in_never_matters(count in 0u32..14, seed: u64, which in 0usize..3) {
            let scope = [RandomQuizScope::Region, RandomQuizScope::Continent, RandomQuizScope::World][which];
            let mut reversed = world();
            reversed.reverse();
            prop_assert_eq!(random_quiz(world(), count, scope, seed), random_quiz(reversed, count, scope, seed));
        }

        #[test]
        fn region_and_continent_quizzes_name_their_area(count in 1u32..14, seed: u64, region: bool) {
            let scope = if region { RandomQuizScope::Region } else { RandomQuizScope::Continent };
            let q = random_quiz(world(), count, scope, seed);
            let area = q.area.clone().expect("an area");
            for id in &q.country_ids {
                let home = if region { region_of(id) } else { continent_of(id) };
                prop_assert_eq!(&home, &area);
            }
            prop_assert!(random_quiz(world(), count, RandomQuizScope::World, seed).area.is_none());
        }
    }
}
