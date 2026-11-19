import Foundation
import MiMundoCore
import SwiftData

/// Version 6 lets a drawing earn part of the points (a mirror image ¾, the
/// right colours ½: `DrawCredit` in the Rust core), so a drawing remembers
/// the app's credit, not just right or wrong. The new field is optional, so
/// V5 stores open with a lightweight migration. SchemaV5's drawing model is
/// the frozen copy in SchemaV5Frozen.swift.
enum SchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }
    static var models: [any PersistentModel.Type] {
        SchemaV4.models + [SchemaV6.FlagDrawing.self]
    }
}

extension SchemaV6 {
    /// One flag drawn for a quiz answer, with the app's verdict and, once a
    /// parent has looked, theirs.
    @Model
    final class FlagDrawing {
        @Attribute(.unique) var id: UUID
        /// The QuizAnswer this drawing answered.
        var answerID: UUID
        var profileID: UUID
        var countryID: String
        /// "freehand" or "outline" (outline drawings are from before the
        /// outline became a tracing guide on the freehand pad).
        var methodRaw: String
        /// The drawing itself, as JSON (`FlagDrawingContent`).
        var content: Data
        /// Freehand: share of graded pixels that matched, 0–100. Outline: -1.
        var scorePercent: Int
        /// What the app decided: right or not.
        var autoCorrect: Bool
        /// The app's share of the points, 0–100: 75 for a mirror image, 50
        /// for the right colours. Nil for drawings from before version 6,
        /// which were only right (100) or wrong (0).
        var autoCreditPercent: Int?
        /// A parent's override, if any (nil: the app's verdict stands).
        var parentVerdict: Bool?
        var reviewedAt: Date?
        var drawnAt: Date

        init(answerID: UUID, profileID: UUID, countryID: String, content: FlagDrawingContent,
             scorePercent: Int, autoCorrect: Bool, autoCreditPercent: Int? = nil, drawnAt: Date) {
            self.id = UUID()
            self.answerID = answerID
            self.profileID = profileID
            self.countryID = countryID
            self.methodRaw = content.method
            self.content = (try? JSONEncoder().encode(content)) ?? Data()
            self.scorePercent = scorePercent
            self.autoCorrect = autoCorrect
            self.autoCreditPercent = autoCreditPercent
            self.drawnAt = drawnAt
        }

        var decoded: FlagDrawingContent? { try? JSONDecoder().decode(FlagDrawingContent.self, from: content) }
        /// The app's share of the points.
        var appCreditPercent: Int { autoCreditPercent ?? (autoCorrect ? 100 : 0) }
        /// The share that counts: a parent's verdict is all or nothing.
        var creditPercent: Int { parentVerdict.map { $0 ? 100 : 0 } ?? appCreditPercent }
        /// The verdict that counts: the parent's if they gave one.
        var isCorrect: Bool { creditPercent == 100 }
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
    /// attempt (§5.3); one marked wrong earns nothing; clearing puts back
    /// the app's share (which may be part of the points).
    @MainActor
    static func setVerdict(_ verdict: Bool?, on drawing: FlagDrawing, in context: ModelContext,
                           now: Date = .now) -> Bool {
        let answerID = drawing.answerID
        let answer = try? context.fetch(FetchDescriptor<QuizAnswer>(
            predicate: #Predicate { $0.id == answerID })).first
        drawing.parentVerdict = verdict
        drawing.reviewedAt = verdict == nil ? nil : now
        if let answer {
            let credit = drawing.creditPercent
            answer.correct = credit == 100
            answer.pointsAwarded = Int(pointsWithCredit(
                basePoints: UInt32(clamping: max(answer.basePoints, 0)),
                attempt: UInt32(clamping: max(answer.attemptNumber, 1)),
                usedMultipleChoice: answer.usedMultipleChoice,
                creditPercent: UInt32(clamping: credit)))
        }
        return context.saveOrRollback("review flag drawing")
    }
}
