import Foundation
import SwiftData

/// Version 5 saves every flag drawing for parent review (requirements §5.3).
/// It only adds a model, so V4 stores open with a lightweight migration.
///
/// Frozen: `SchemaV5.FlagDrawing` is the drawing model as version 5 shipped
/// it. Never edit it; change `SchemaV6.FlagDrawing` (or add a version).
enum SchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }
    static var models: [any PersistentModel.Type] {
        SchemaV4.models + [SchemaV5.FlagDrawing.self]
    }
}

extension SchemaV5 {
    @Model
    final class FlagDrawing {
        @Attribute(.unique) var id: UUID
        var answerID: UUID
        var profileID: UUID
        var countryID: String
        var methodRaw: String
        var content: Data
        var scorePercent: Int
        var autoCorrect: Bool
        var parentVerdict: Bool?
        var reviewedAt: Date?
        var drawnAt: Date

        init(id: UUID = UUID(), answerID: UUID, profileID: UUID, countryID: String, methodRaw: String,
             content: Data, scorePercent: Int, autoCorrect: Bool, drawnAt: Date) {
            self.id = id
            self.answerID = answerID
            self.profileID = profileID
            self.countryID = countryID
            self.methodRaw = methodRaw
            self.content = content
            self.scorePercent = scorePercent
            self.autoCorrect = autoCorrect
            self.drawnAt = drawnAt
        }
    }
}
