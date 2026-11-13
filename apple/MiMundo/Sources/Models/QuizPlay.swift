import Foundation
import MiMundoCore
import SwiftData

/// The kinds of question a quiz asks about a country (requirements §3.2).
/// Flag questions arrive with flag drawing.
enum QuestionKind: String, CaseIterable, Sendable {
    case name
    case capital
}

extension SchemaV3 {
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

        init(profile: Profile, quiz: QuizSet, run: Int, day: Int32, number: Int, startedAt: Date) {
            self.id = UUID()
            self.profileID = profile.id
            self.roleRaw = profile.roleRaw
            self.quizSetID = quiz.id
            self.run = run
            self.day = day
            self.number = number
            self.startedAt = startedAt
        }
    }

    /// One answered question. It stores its own scoring inputs (base
    /// points, attempt number, multiple choice), so a parent can later
    /// overturn a verdict and award what it was worth (requirements §5.3).
    @Model
    final class QuizAnswer {
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

        init(attempt: QuizAttempt, countryID: String, kind: QuestionKind, chosen: String,
             correctAnswer: String, basePoints: Int, answeredAt: Date) {
            self.id = UUID()
            self.attemptID = attempt.id
            self.profileID = attempt.profileID
            self.countryID = countryID
            self.kindRaw = kind.rawValue
            self.chosen = chosen
            self.correctAnswer = correctAnswer
            self.correct = chosen == correctAnswer
            self.basePoints = basePoints
            self.attemptNumber = attempt.number
            self.usedMultipleChoice = false
            self.pointsAwarded = chosen == correctAnswer
                ? Int(pointsForAttempt(basePoints: UInt32(max(basePoints, 0)),
                                       attempt: UInt32(max(attempt.number, 1)),
                                       usedMultipleChoice: false))
                : 0
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
        }
    }

    func basePoints(for kind: QuestionKind) -> Int {
        switch kind {
        case .name: namePoints
        case .capital: capitalPoints
        }
    }
}

/// Starting, resuming and recording quiz sittings. Scoring and the queue's
/// rules are the Rust core's; this loads and saves around them.
enum QuizPlay {
    /// The sitting to play now: an unfinished one from this run if there is
    /// one (leaving a quiz and coming back carries on), else a new one.
    /// Starting a sitting locks today's quiz against edits (§5.4).
    @MainActor
    static func begin(_ quiz: QuizSet, for profile: Profile, in context: ModelContext,
                      now: Date = .now) -> QuizAttempt? {
        QuizQueue.refresh(in: context, now: now)
        guard let record = try? context.fetch(FetchDescriptor<QueueRecord>()).first,
              record.currentQuizID == quiz.id else { return nil }
        let (profileID, quizID, run) = (profile.id, quiz.id, record.run)
        let descriptor = FetchDescriptor<QuizAttempt>(
            predicate: #Predicate { $0.profileID == profileID && $0.quizSetID == quizID && $0.run == run },
            sortBy: [SortDescriptor(\.number)]
        )
        guard let earlier = try? context.fetch(descriptor) else { return nil }
        if let unfinished = earlier.last(where: { $0.finishedAt == nil }) {
            return unfinished
        }
        let attempt = QuizAttempt(profile: profile, quiz: quiz, run: run,
                                  day: Attendance.today(now: now),
                                  number: (earlier.map(\.number).max() ?? 0) + 1, startedAt: now)
        context.insert(attempt)
        record.started = true
        return context.saveOrRollback("start quiz attempt") ? attempt : nil
    }

    /// Saves one answer. A kid's first answer is what counts as "a kid
    /// attempted today's quiz", which lets the queue move on tomorrow.
    @MainActor
    @discardableResult
    static func record(_ chosen: String, correctAnswer: String, kind: QuestionKind,
                       country: AtlasCountry, quiz: QuizSet, attempt: QuizAttempt,
                       in context: ModelContext, now: Date = .now) -> QuizAnswer? {
        let answer = QuizAnswer(attempt: attempt, countryID: country.meta.id, kind: kind,
                                chosen: chosen, correctAnswer: correctAnswer,
                                basePoints: quiz.basePoints(for: kind), answeredAt: now)
        context.insert(answer)
        if attempt.roleRaw == Role.child.rawValue,
           let record = try? context.fetch(FetchDescriptor<QueueRecord>()).first,
           record.currentQuizID == quiz.id, record.run == attempt.run, !record.attemptedByKid {
            record.attemptedByKid = true
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
/// capital (none among independent countries, a few territories) simply
/// isn't asked for one.
struct QuizTarget: Identifiable {
    let country: AtlasCountry
    let kinds: [QuestionKind]

    var id: UInt32 { country.id }

    static func all(for quiz: QuizSet, in atlas: Atlas) -> [QuizTarget] {
        let wanted = Set(quiz.countryIDs)
        return atlas.countries.filter { wanted.contains($0.meta.id) }.compactMap { country in
            let kinds = QuestionKind.allCases.filter { kind in
                quiz.asks(kind) && (kind != .capital || country.facts?.capitals.isEmpty == false)
            }
            return kinds.isEmpty ? nil : QuizTarget(country: country, kinds: kinds)
        }
    }
}

extension Atlas {
    /// The right answer and the buttons for a question: wrong answers come
    /// from the nearest other countries (by map distance), so they are
    /// plausible neighbours. Which ones, and the order, come from `seed`.
    func choices(for kind: QuestionKind, about country: AtlasCountry, seed: UInt64) -> (correct: String, all: [String]) {
        let here = CGPoint(x: CGFloat(country.meta.labelX), y: CGFloat(country.meta.labelY))
        let nearest = countries
            .filter { $0.id != country.id && $0.facts?.independent == true }
            .map { other -> (AtlasCountry, CGFloat) in
                let dx = CGFloat(other.meta.labelX) - here.x, dy = CGFloat(other.meta.labelY) - here.y
                return (other, dx * dx + dy * dy)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        let correct: String
        let candidates: [String]
        switch kind {
        case .name:
            correct = country.name
            candidates = nearest.map(\.name)
        case .capital:
            let capitals = country.facts?.capitals ?? []
            correct = capitals.first ?? ""
            // Never offer one of the country's other capitals as "wrong".
            candidates = nearest.compactMap { $0.facts?.capitals.first }.filter { !capitals.contains($0) }
        }
        return (correct, quizChoices(correct: correct, candidates: candidates, seed: seed))
    }
}
