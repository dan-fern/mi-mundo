import Foundation
import MiMundoCore
import SwiftData

extension SchemaV2 {
    /// One quiz in the family queue (requirements §5.4): a set of countries,
    /// which questions to ask about each, and what they're worth.
    ///
    /// Removing a quiz from the queue sets `removedAt` rather than deleting
    /// it, so past attempts can still say which quiz they were for.
    @Model
    final class QuizSet {
        @Attribute(.unique) var id: UUID
        var title: String
        /// Natural Earth ADM0_A3 codes (`CountryMeta.id`), e.g. "FRA".
        var countryIDs: [String]
        var asksName: Bool
        var asksCapital: Bool
        var asksFlag: Bool
        /// Points for a correct first-attempt answer of each kind.
        var namePoints: Int
        var capitalPoints: Int
        var flagPoints: Int
        /// Order in the queue (lowest first). Gaps are fine.
        var position: Int
        var createdBy: UUID?
        var createdAt: Date
        var removedAt: Date?

        init(draft: QuizDraft, position: Int, createdBy: UUID?, createdAt: Date = .now) {
            self.id = UUID()
            self.title = draft.title
            self.countryIDs = draft.countryIDs
            self.asksName = draft.asksName
            self.asksCapital = draft.asksCapital
            self.asksFlag = draft.asksFlag
            self.namePoints = draft.namePoints
            self.capitalPoints = draft.capitalPoints
            self.flagPoints = draft.flagPoints
            self.position = position
            self.createdBy = createdBy
            self.createdAt = createdAt
        }

        func apply(_ draft: QuizDraft) {
            title = draft.title
            countryIDs = draft.countryIDs
            asksName = draft.asksName
            asksCapital = draft.asksCapital
            asksFlag = draft.asksFlag
            namePoints = draft.namePoints
            capitalPoints = draft.capitalPoints
            flagPoints = draft.flagPoints
        }
    }

    /// The queue's memory between launches: a single record mirroring the
    /// Rust core's `QueueState` (core/src/queue.rs), which owns the rules.
    @Model
    final class QueueRecord {
        var currentQuizID: UUID?
        var position: Int
        var run: Int
        var day: Int32
        var attemptedByKid: Bool
        var started: Bool

        init(_ state: QueueState) {
            self.currentQuizID = state.current.flatMap(UUID.init(uuidString:))
            self.position = Int(state.position)
            self.run = Int(state.run)
            self.day = state.day
            self.attemptedByKid = state.attemptedByKid
            self.started = state.started
        }

        var state: QueueState {
            QueueState(current: currentQuizID?.uuidString, position: UInt32(max(position, 0)),
                       run: UInt32(max(run, 0)), day: day,
                       attemptedByKid: attemptedByKid, started: started)
        }

        func update(_ state: QueueState) {
            currentQuizID = state.current.flatMap(UUID.init(uuidString:))
            position = Int(state.position)
            run = Int(state.run)
            day = state.day
            attemptedByKid = state.attemptedByKid
            started = state.started
        }
    }
}

/// A quiz being created or edited, before it's saved.
struct QuizDraft: Equatable {
    var title = ""
    var countryIDs: [String] = []
    var asksName = true
    var asksCapital = true
    var asksFlag = false
    var namePoints = 10
    var capitalPoints = 10
    var flagPoints = 20

    static let pointsRange = 0...100

    init() {}

    init(_ quiz: QuizSet) {
        title = quiz.title
        countryIDs = quiz.countryIDs
        asksName = quiz.asksName
        asksCapital = quiz.asksCapital
        asksFlag = quiz.asksFlag
        namePoints = quiz.namePoints
        capitalPoints = quiz.capitalPoints
        flagPoints = quiz.flagPoints
    }

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespaces) }
    var asksAnything: Bool { asksName || asksCapital || asksFlag }
    var isValid: Bool { !trimmedTitle.isEmpty && !countryIDs.isEmpty && asksAnything }
}

extension QuizSet {
    /// "Name · Capital", for list rows.
    var questionSummary: String {
        var kinds: [String] = []
        if asksName { kinds.append("Name") }
        if asksCapital { kinds.append("Capital") }
        if asksFlag { kinds.append("Flag") }
        return kinds.joined(separator: " · ")
    }

    /// Most points one sitting can earn (first attempt, no multiple choice).
    var maxPoints: Int {
        countryIDs.count * ((asksName ? namePoints : 0) + (asksCapital ? capitalPoints : 0)
            + (asksFlag ? flagPoints : 0))
    }
}

/// The family quiz queue on this iPad. The rules (when today's quiz moves
/// on) are the Rust core's; this loads and saves around them.
enum QuizQueue {
    /// Quizzes in the queue, in order.
    @MainActor
    static func quizzes(in context: ModelContext) -> [QuizSet] {
        let descriptor = FetchDescriptor<QuizSet>(
            predicate: #Predicate { $0.removedAt == nil },
            sortBy: [SortDescriptor(\.position), SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Brings the queue up to date (new game day, or the queue was edited)
    /// and returns today's quiz. Cheap and safe to call often.
    @MainActor
    @discardableResult
    static func refresh(in context: ModelContext, now: Date = .now) -> QuizSet? {
        let today = Attendance.today(now: now)
        let quizzes = quizzes(in: context)
        let record: QueueRecord
        do {
            if let existing = try context.fetch(FetchDescriptor<QueueRecord>()).first {
                record = existing
            } else {
                record = QueueRecord(queueInitialState(today: today))
                context.insert(record)
            }
        } catch {
            // Don't guess: a second record would fork the queue's memory.
            dataLog.error("Couldn't load the quiz queue state: \(error, privacy: .public)")
            return nil
        }
        let before = record.state
        let after = queueToday(state: before, queue: quizzes.map(\.id.uuidString), today: today)
        if after != before || record.modelContext == nil || record.hasChanges {
            record.update(after)
            context.saveOrRollback("refresh quiz queue")
        }
        return quizzes.first { $0.id == record.currentQuizID }
    }

    /// Adds a quiz at the end of the queue. Returns false if the queue is full.
    @MainActor
    @discardableResult
    static func add(_ draft: QuizDraft, by parent: Profile?, in context: ModelContext) -> Bool {
        let quizzes = quizzes(in: context)
        guard quizzes.count < Int(queueMax()) else { return false }
        let position = (quizzes.map(\.position).max() ?? -1) + 1
        context.insert(QuizSet(draft: draft, position: position, createdBy: parent?.id))
        guard context.saveOrRollback("add quiz") else { return false }
        refresh(in: context)
        return true
    }

    @MainActor
    static func remove(_ quiz: QuizSet, in context: ModelContext, now: Date = .now) {
        quiz.removedAt = now
        guard context.saveOrRollback("remove quiz") else { return }
        refresh(in: context, now: now)
    }

    /// Saves a new order (every quiz in the queue, first to last).
    @MainActor
    static func reorder(_ ordered: [QuizSet], in context: ModelContext) {
        for (index, quiz) in ordered.enumerated() where quiz.position != index {
            quiz.position = index
        }
        guard context.saveOrRollback("reorder quizzes") else { return }
        refresh(in: context)
    }
}
