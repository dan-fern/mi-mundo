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

typealias Profile = SchemaV1.Profile
typealias Visit = SchemaV1.Visit
typealias Session = SchemaV1.Session

enum MiMundoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

enum Persistence {
    /// Opens the on-device store. If it can't be opened (e.g. a test build
    /// from before the versioned schema), the old files are moved aside —
    /// not deleted — and a fresh store is created, so the app still launches.
    @MainActor
    static func makeContainer() -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration = ModelConfiguration(schema: schema)
        do {
            return try open(schema, configuration)
        } catch {
            dataLog.error("Couldn't open data store, moving it aside: \(error, privacy: .public)")
            moveStoreAside(at: configuration.url)
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
