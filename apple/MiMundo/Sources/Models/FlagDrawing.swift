import Foundation
import MiMundoCore
import SwiftData

/// Version 5 saves every flag drawing for parent review (requirements §5.3).
/// It only adds a model, so V4 stores open with a lightweight migration.
enum SchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }
    static var models: [any PersistentModel.Type] {
        SchemaV4.models + [SchemaV5.FlagDrawing.self]
    }
}

extension SchemaV5 {
    /// One flag drawn for a quiz answer (freehand or on an outline), with
    /// the app's verdict and, once a parent has looked, theirs.
    @Model
    final class FlagDrawing {
        @Attribute(.unique) var id: UUID
        /// The QuizAnswer this drawing answered.
        var answerID: UUID
        var profileID: UUID
        var countryID: String
        /// "freehand" or "outline".
        var methodRaw: String
        /// The drawing itself, as JSON (`FlagDrawingContent`).
        var content: Data
        /// Freehand: share of graded pixels that matched, 0–100. Outline: -1.
        var scorePercent: Int
        /// What the app decided.
        var autoCorrect: Bool
        /// A parent's override, if any (nil: the app's verdict stands).
        var parentVerdict: Bool?
        var reviewedAt: Date?
        var drawnAt: Date

        init(answerID: UUID, profileID: UUID, countryID: String, content: FlagDrawingContent,
             scorePercent: Int, autoCorrect: Bool, drawnAt: Date) {
            self.id = UUID()
            self.answerID = answerID
            self.profileID = profileID
            self.countryID = countryID
            self.methodRaw = content.method
            self.content = (try? JSONEncoder().encode(content)) ?? Data()
            self.scorePercent = scorePercent
            self.autoCorrect = autoCorrect
            self.drawnAt = drawnAt
        }

        var decoded: FlagDrawingContent? { try? JSONDecoder().decode(FlagDrawingContent.self, from: content) }
        /// The verdict that counts: the parent's if they gave one.
        var isCorrect: Bool { parentVerdict ?? autoCorrect }
    }
}

/// What a drawing looked like, enough to draw it again.
enum FlagDrawingContent: Codable, Equatable {
    case freehand(FlagSketch)
    case outline(layout: String, painted: [String], strokes: [FlagStroke])

    var method: String {
        switch self {
        case .freehand: "freehand"
        case .outline: "outline"
        }
    }
}

enum DrawingReview {
    /// Sets (or clears, with nil) a parent's verdict, and rescores the answer:
    /// an answer marked right earns what that question was worth on that
    /// attempt (§5.3); one marked wrong earns nothing.
    @MainActor
    static func setVerdict(_ verdict: Bool?, on drawing: FlagDrawing, in context: ModelContext,
                           now: Date = .now) -> Bool {
        let answerID = drawing.answerID
        let answer = try? context.fetch(FetchDescriptor<QuizAnswer>(
            predicate: #Predicate { $0.id == answerID })).first
        drawing.parentVerdict = verdict
        drawing.reviewedAt = verdict == nil ? nil : now
        if let answer {
            let right = verdict ?? drawing.autoCorrect
            answer.correct = right
            answer.pointsAwarded = right
                ? Int(pointsForAttempt(basePoints: UInt32(clamping: max(answer.basePoints, 0)),
                                       attempt: UInt32(clamping: max(answer.attemptNumber, 1)),
                                       usedMultipleChoice: answer.usedMultipleChoice))
                : 0
        }
        return context.saveOrRollback("review flag drawing")
    }
}
