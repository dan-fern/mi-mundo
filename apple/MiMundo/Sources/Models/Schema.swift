import Foundation
import SwiftData
import os

let dataLog = Logger(subsystem: "com.danfern.mimundo", category: "data")

/// Version 1 of the on-device data model. When a model changes, add
/// `SchemaV2` (copying the models), point the typealiases at it, and add a
/// migration stage to `MiMundoMigrationPlan`, so data on the iPad survives.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [Profile.self, Visit.self, Session.self]
    }
}

/// Version 2 adds the family quiz queue (`QuizSet`, `QueueRecord`). The
/// version 1 models are unchanged, so they are reused as they are and the
/// migration is lightweight (new, empty tables).
enum SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        SchemaV1.models + [QuizSet.self, QueueRecord.self]
    }
}

/// Version 3 adds quiz sittings (`QuizAttempt`, `QuizAnswer`). Earlier
/// models are unchanged; the migration is lightweight.
enum SchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] {
        SchemaV2.models + [SchemaV3.QuizAttempt.self, SchemaV3.QuizAnswer.self]
    }
}

/// Version 4 adds stats fields to quiz sittings and answers (what was
/// offered and picked, when it was asked, a snapshot of the quiz) and makes
/// an answer unique per sitting, country and question. SchemaV3's quiz
/// models are frozen copies in SchemaV3Frozen.swift.
enum SchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }
    static var models: [any PersistentModel.Type] {
        SchemaV2.models + [SchemaV4.QuizAttempt.self, SchemaV4.QuizAnswer.self]
    }
}

typealias Profile = SchemaV1.Profile
typealias Visit = SchemaV1.Visit
typealias Session = SchemaV1.Session
typealias QuizSet = SchemaV2.QuizSet
typealias QueueRecord = SchemaV2.QueueRecord
typealias QuizAttempt = SchemaV4.QuizAttempt
typealias QuizAnswer = SchemaV4.QuizAnswer
typealias FlagDrawing = SchemaV5.FlagDrawing

enum MiMundoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self, SchemaV5.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self),
         .lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self),
         .lightweight(fromVersion: SchemaV3.self, toVersion: SchemaV4.self),
         .lightweight(fromVersion: SchemaV4.self, toVersion: SchemaV5.self)]
    }
}

enum Persistence {
    /// Set when the store couldn't be opened and was moved aside.
    static let movedAsideKey = "storeMovedAsideAt"

    /// Opens the on-device store. If it can't be opened (e.g. a test build
    /// from before the versioned schema), the old files are moved aside —
    /// not deleted — and a fresh store is created, so the app still launches.
    @MainActor
    static func makeContainer() -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV5.self)
        let configuration = ModelConfiguration(schema: schema)
        do {
            return try open(schema, configuration)
        } catch {
            dataLog.error("Couldn't open data store, moving it aside: \(error, privacy: .public)")
            moveStoreAside(at: configuration.url)
            // Tell a parent (parent home shows it) rather than silently
            // starting over: the old files are kept next to the new store.
            UserDefaults.standard.set(Date.now, forKey: Persistence.movedAsideKey)
            do {
                return try open(schema, configuration)
            } catch {
                fatalError("Couldn't create a data store: \(error)")
            }
        }
    }

    private static func open(_ schema: Schema, _ configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            migrationPlan: MiMundoMigrationPlan.self,
            configurations: configuration
        )
    }

    private static func moveStoreAside(at url: URL) {
        let stamp = Int(Date.now.timeIntervalSince1970)
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: file.path) else { continue }
            let aside = URL(fileURLWithPath: url.path + ".unreadable-\(stamp)" + suffix)
            try? fileManager.moveItem(at: file, to: aside)
        }
    }
}

extension ModelContext {
    /// Saves; on failure rolls back the pending changes and logs, so one bad
    /// change can't make every later autosave fail. Returns whether it saved.
    @discardableResult
    func saveOrRollback(_ action: String) -> Bool {
        do {
            try save()
            return true
        } catch {
            dataLog.error("Save failed (\(action, privacy: .public)): \(error, privacy: .public)")
            rollback()
            return false
        }
    }
}
