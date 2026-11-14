import Foundation
import MiMundoCore
import SwiftData
import UIKit

/// The kinds of question a quiz asks about a country (requirements §3.2),
/// asked in this order.
enum QuestionKind: String, CaseIterable, Sendable {
    case name
    case capital
    /// Draw the country's flag on a layout outline (full points), or, as
    /// help, pick it from four (half points, §3.3). Flags too detailed for
    /// an outline are always picked from four.
    case flag
}

/// Points a right answer earns on a first try, by the Rust core's rules.
enum QuizScoring {
    static func firstTry(base: Int, multipleChoice: Bool) -> Int {
        Int(pointsForAttempt(basePoints: UInt32(clamping: max(base, 0)), attempt: 1,
                             usedMultipleChoice: multipleChoice))
    }

    /// The most a question can earn on a first try: a flag that can be
    /// drawn earns full points, one that can only be picked from four half.
    /// Without a country (no map yet) a flag counts as drawable.
    static func best(_ kind: QuestionKind, base: Int, country: AtlasCountry?) -> Int {
        let pickOnly = kind == .flag && country.map { FlagOutlines.spec(for: $0) == nil } == true
        return firstTry(base: base, multipleChoice: pickOnly)
    }
}

extension SchemaV4 {
    /// One quiz sitting by anyone, kid or parent (requirements §3.4, §7).
    /// Attempt numbers count within a run, so they start again at 1 when
    /// the quiz comes back around in the queue.
    @Model
    final class QuizAttempt {
        @Attribute(.unique) var id: UUID
        var profileID: UUID
        var roleRaw: String
        var quizSetID: UUID
        /// The queue's run number when the sitting started.
        var run: Int
        /// Game day the sitting started on.
        var day: Int32
        /// 1 for the first sitting in this run, 2 for the second, …
        var number: Int
        var startedAt: Date
        /// Nil until every question has been answered.
        var finishedAt: Date?
        /// The quiz as it was when the sitting started, so later edits
        /// don't change what an old result meant (§3.8 comparisons, §5.2).
        var quizCountryIDs: [String] = []
        var questionCount: Int = 0
        var perfectPoints: Int = 0

        init(profile: Profile, quiz: QuizSet, run: Int, day: Int32, number: Int, startedAt: Date,
             targets: [QuizTarget]) {
            self.id = UUID()
            self.profileID = profile.id
            self.roleRaw = profile.roleRaw
            self.quizSetID = quiz.id
            self.run = run
            self.day = day
            self.number = number
            self.startedAt = startedAt
            self.quizCountryIDs = quiz.countryIDs
            self.questionCount = targets.reduce(0) { $0 + $1.kinds.count }
            self.perfectPoints = targets.reduce(0) { total, target in
                total + target.kinds.reduce(0) {
                    $0 + QuizScoring.best($1, base: quiz.basePoints(for: $1), country: target.country)
                }
            }
        }

        var isKid: Bool { roleRaw == Role.child.rawValue }
    }

    /// One answered question. It stores its own scoring inputs (base
    /// points, attempt number, multiple choice), so a parent can later
    /// overturn a verdict and award what it was worth (requirements §5.3),
    /// and what was offered and picked, for the stats (§5.2: commonly
    /// confused pairs, answer speed).
    @Model
    final class QuizAnswer {
        #Unique<QuizAnswer>([\.attemptID, \.countryID, \.kindRaw])

        @Attribute(.unique) var id: UUID
        var attemptID: UUID
        var profileID: UUID
        /// Natural Earth ADM0_A3 code of the country asked about.
        var countryID: String
        var kindRaw: String
        var chosen: String
        var correctAnswer: String
        var correct: Bool
        var basePoints: Int
        var attemptNumber: Int
        /// Flag questions answered by multiple choice earn half (§3.4);
        /// always false for name and capital questions.
        var usedMultipleChoice: Bool
        var pointsAwarded: Int
        var answeredAt: Date
        /// The country whose name (or capital) was picked, by ADM0_A3 code:
        /// "confused Niger with Nigeria" survives a renamed country.
        var chosenCountryID: String?
        /// The buttons shown, in order.
        var choices: [String] = []
        /// When the question appeared (answer speed, §5.2; never shown to
        /// the child).
        var askedAt: Date?

        init(attempt: QuizAttempt, countryID: String, kind: QuestionKind, chosen: String,
             chosenCountryID: String?, correctAnswer: String, choices: [String],
             basePoints: Int, multipleChoice: Bool, isCorrect: Bool? = nil,
             askedAt: Date?, answeredAt: Date) {
            // A drawn flag can be right without matching exactly (close
            // shades count), so the grader's verdict wins when there is one.
            let right = isCorrect ?? (chosen == correctAnswer)
            self.id = UUID()
            self.attemptID = attempt.id
            self.profileID = attempt.profileID
            self.countryID = countryID
            self.kindRaw = kind.rawValue
            self.chosen = chosen
            self.chosenCountryID = chosenCountryID
            self.correctAnswer = correctAnswer
            self.correct = right
            self.choices = choices
            self.basePoints = basePoints
            self.attemptNumber = attempt.number
            self.usedMultipleChoice = multipleChoice
            self.pointsAwarded = right
                ? Int(pointsForAttempt(basePoints: UInt32(clamping: max(basePoints, 0)),
                                       attempt: UInt32(clamping: max(attempt.number, 1)),
                                       usedMultipleChoice: multipleChoice))
                : 0
            self.askedAt = askedAt
            self.answeredAt = answeredAt
        }

        var kind: QuestionKind? { QuestionKind(rawValue: kindRaw) }
    }
}

extension QuizSet {
    func asks(_ kind: QuestionKind) -> Bool {
        switch kind {
        case .name: asksName
        case .capital: asksCapital
        case .flag: asksFlag
        }
    }

    func basePoints(for kind: QuestionKind) -> Int {
        switch kind {
        case .name: namePoints
        case .capital: capitalPoints
        case .flag: flagPoints
        }
    }
}

/// Starting, resuming and recording quiz sittings. Scoring and the queue's
/// rules are the Rust core's; this loads and saves around them.
enum QuizPlay {
    /// The sitting to play now: an unfinished one from this run if there is
    /// one (leaving a quiz and coming back carries on), else a new one. A
    /// kid's sitting locks today's quiz against edits for the rest of its
    /// run (§5.4); a parent trying it out doesn't. Nil if the quiz is no
    /// longer today's or has nothing to ask.
    @MainActor
    static func begin(_ quiz: QuizSet, targets: [QuizTarget], for profile: Profile,
                      in context: ModelContext, now: Date = .now) -> QuizAttempt? {
        guard !targets.isEmpty else { return nil }
        QuizQueue.refresh(in: context, now: now)
        guard let record = try? context.fetch(FetchDescriptor<QueueRecord>()).first,
              record.currentQuizID == quiz.id else { return nil }
        let (profileID, quizID, run) = (profile.id, quiz.id, record.run)
        let descriptor = FetchDescriptor<QuizAttempt>(
            predicate: #Predicate { $0.profileID == profileID && $0.quizSetID == quizID && $0.run == run },
            sortBy: [SortDescriptor(\.number)]
        )
        guard let earlier = try? context.fetch(descriptor) else { return nil }
        let attempt: QuizAttempt
        if let unfinished = earlier.last(where: { $0.finishedAt == nil }) {
            attempt = unfinished
        } else {
            attempt = QuizAttempt(profile: profile, quiz: quiz, run: run, day: Attendance.today(now: now),
                                  number: (earlier.map(\.number).max() ?? 0) + 1, startedAt: now,
                                  targets: targets)
            context.insert(attempt)
        }
        if !profile.isParent { record.started = true }
        return context.saveOrRollback("start quiz attempt") ? attempt : nil
    }

    /// Saves one answer; nil if it couldn't be saved (nothing changes then,
    /// so the question can be answered again). A kid's first answer is what
    /// counts as "a kid attempted today's quiz", which lets the queue move on
    /// at the next game day. The queue is brought up to date first, so an
    /// answer given just after 11 pm ET counts for the day it was given.
    @MainActor
    static func record(_ chosen: String, correctAnswer: String, kind: QuestionKind,
                       country: AtlasCountry, chosenCountry: AtlasCountry?, choices: [String],
                       multipleChoice: Bool = false, isCorrect: Bool? = nil,
                       quiz: QuizSet, attempt: QuizAttempt, askedAt: Date?,
                       in context: ModelContext, now: Date = .now) -> QuizAnswer? {
        QuizQueue.refresh(in: context, now: now)
        let answer = QuizAnswer(attempt: attempt, countryID: country.meta.id, kind: kind,
                                chosen: chosen, chosenCountryID: chosenCountry?.meta.id,
                                correctAnswer: correctAnswer, choices: choices,
                                basePoints: quiz.basePoints(for: kind), multipleChoice: multipleChoice,
                                isCorrect: isCorrect, askedAt: askedAt, answeredAt: now)
        context.insert(answer)
        if attempt.isKid,
           let record = try? context.fetch(FetchDescriptor<QueueRecord>()).first,
           record.currentQuizID == quiz.id, record.run == attempt.run {
            record.attemptedByKid = true
            record.started = true
        }
        return context.saveOrRollback("record quiz answer") ? answer : nil
    }

    @MainActor
    static func finish(_ attempt: QuizAttempt, in context: ModelContext, now: Date = .now) {
        guard attempt.finishedAt == nil else { return }
        attempt.finishedAt = now
        context.saveOrRollback("finish quiz attempt")
    }
}

/// One country in a quiz, with the questions it gets. A place with no
/// capital (a few territories) isn't asked for one. City-states named like
/// their capital (Singapore, Monaco) are asked: the answer being the same
/// name is fine (owner's decision).
struct QuizTarget: Identifiable {
    let country: AtlasCountry
    let kinds: [QuestionKind]

    var id: UInt32 { country.id }

    static func all(for quiz: QuizSet, in atlas: Atlas) -> [QuizTarget] {
        all(countryIDs: quiz.countryIDs, asks: quiz.asks, in: atlas)
    }

    static func all(countryIDs: [String], asks: (QuestionKind) -> Bool, in atlas: Atlas) -> [QuizTarget] {
        let wanted = Set(countryIDs)
        return atlas.countries.filter { wanted.contains($0.meta.id) }.compactMap { country in
            let kinds = QuestionKind.allCases.filter { kind in
                switch kind {
                case .name: asks(kind)
                case .capital: asks(kind) && hasCapitalQuestion(country)
                case .flag: asks(kind) && country.hasFlag
                }
            }
            return kinds.isEmpty ? nil : QuizTarget(country: country, kinds: kinds)
        }
    }

    static func hasCapitalQuestion(_ country: AtlasCountry) -> Bool {
        country.facts?.capitals.isEmpty == false
    }
}

extension Atlas {
    /// The right answer and the buttons for a question. Wrong answers come
    /// from the nearest other countries, so they're plausible neighbours:
    /// distance is measured from each capital (the label point of a big
    /// country like Russia sits far from its neighbours) and wraps around
    /// the ±180° line (Tonga's neighbours are Samoa and Fiji, not Mexico).
    /// Countries in `excluding` aren't offered (targets already answered:
    /// their names are on the map, so they could be ruled out). Which ones,
    /// and the order, come from `seed`.
    func choices(for kind: QuestionKind, about country: AtlasCountry, excluding: Set<UInt32> = [],
                 seed: UInt64) -> (correct: String, all: [String], countries: [String: AtlasCountry]) {
        func anchor(_ c: AtlasCountry) -> CGPoint {
            c.capitals.first ?? CGPoint(x: CGFloat(c.meta.labelX), y: CGFloat(c.meta.labelY))
        }
        let here = anchor(country)
        let width = bounds.width
        let nearest = countries
            .filter { $0.id != country.id && $0.facts?.independent == true && !excluding.contains($0.id) }
            .map { other -> (AtlasCountry, CGFloat) in
                let p = anchor(other)
                var dx = abs(p.x - here.x)
                dx = min(dx, width - dx)
                let dy = p.y - here.y
                return (other, dx * dx + dy * dy)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        let correct: String
        var byAnswer: [String: AtlasCountry] = [:]
        switch kind {
        case .name:
            correct = country.name
            for other in nearest where byAnswer[other.name] == nil { byAnswer[other.name] = other }
            byAnswer[correct] = country
            let candidates = nearest.map(\.name)
            return (correct, quizChoices(correct: correct, candidates: candidates, seed: seed), byAnswer)
        case .flag:
            // Buttons are flags: the choices are country codes, drawn as
            // flags. Look-alikes that can't be told apart at button size
            // (Monaco and Indonesia, Chad and Romania) never meet.
            let lookAlikes = Self.flagLookAlikes[country.meta.iso2] ?? []
            var candidates: [String] = []
            for other in nearest where other.hasFlag && !lookAlikes.contains(other.meta.iso2) {
                candidates.append(other.meta.id)
                byAnswer[other.meta.id] = other
            }
            correct = country.meta.id
            byAnswer[correct] = country
            return (correct, quizChoices(correct: correct, candidates: candidates, seed: seed), byAnswer)
        case .capital:
            let capitals = country.facts?.capitals ?? []
            correct = capitals.first ?? ""
            // Never offer as "wrong" one of this country's other capitals, or
            // a capital sharing a word with one ("East Jerusalem" for Israel,
            // "Jerusalem" for Palestine: both are arguably right).
            let words = Set(capitals.flatMap(Self.words))
            var candidates: [String] = []
            for other in nearest {
                guard let capital = other.facts?.capitals.first,
                      !capitals.contains(capital), words.isDisjoint(with: Self.words(capital)) else { continue }
                candidates.append(capital)
                if byAnswer[capital] == nil { byAnswer[capital] = other }
            }
            byAnswer[correct] = country
            return (correct, quizChoices(correct: correct, candidates: candidates, seed: seed), byAnswer)
        }
    }

    /// Flags too alike to tell apart as small buttons (by ISO code).
    static let flagLookAlikes: [String: Set<String>] = [
        "MC": ["ID"], "ID": ["MC"],
        "TD": ["RO"], "RO": ["TD"],
    ]

    /// Distinctive words of a name (4+ letters), lowercased.
    private static func words(_ name: String) -> [String] {
        name.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 && $0 != "city" }
    }
}

/// A seed for one question that stays the same within a sitting, so going
/// to another country and coming back shows the same four buttons (no
/// re-rolling until only the right answer keeps turning up), but differs
/// between sittings. FNV-1a: stable across launches, unlike `Hasher`.
enum QuestionSeed {
    static func make(attempt: UUID, country: String, kind: QuestionKind) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in "\(attempt.uuidString)|\(country)|\(kind.rawValue)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
