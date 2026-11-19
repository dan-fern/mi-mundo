import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import MiMundo

/// Writes the migration fixtures (`Fixtures/v1.store` … `v4.store`): one real
/// store per shipped schema version. They are committed as binaries and
/// never regenerated for an old version, so that editing a model in place
/// (instead of adding a new schema version) makes the migration tests fail
/// the way a real iPad's old store would. Only a NEW version's fixture is
/// ever written: add a `case`, run `testWriteFixtures` once with
///
///     TEST_RUNNER_WRITE_FIXTURES_TO=$PWD/apple/MiMundo/Tests/Fixtures \
///       xcodebuild test -only-testing:MiMundoTests/MigrationTests/testWriteFixtures …
///
/// and commit the new file. (v1–v4 were written from the app's models at
/// the time version 5 was added, which only added a model.)
enum FixtureWriter {
    static let parentID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let kidID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    static let quizID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    static let attemptID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    static let day: Int32 = 20_000
    static let when = Date(timeIntervalSince1970: 1_768_392_000)

    @MainActor
    static func write(version: Int, to url: URL) throws {
        let schemas: [any VersionedSchema.Type] = [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self]
        let schema = Schema(versionedSchema: schemas[version - 1])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = container.mainContext
        let parent = Profile(name: "Mama", emoji: "🦊", role: .parent, createdAt: when)
        parent.id = parentID
        parent.pinSalt = Data([1, 2, 3])
        parent.pinHash = Data([4, 5, 6])
        let kid = Profile(name: "Kid", emoji: "🐼", role: .child, createdAt: when)
        kid.id = kidID
        context.insert(parent)
        context.insert(kid)
        context.insert(Visit(childID: kidID, day: day, firstOpenedAt: when))
        context.insert(Session(profile: kid, day: day, startedAt: when))
        if version >= 2 {
            var draft = QuizDraft()
            draft.title = "Europe"
            draft.countryIDs = ["FRA", "ESP"]
            draft.asksFlag = true
            let quiz = QuizSet(draft: draft, position: 0, createdBy: parentID, createdAt: when)
            quiz.id = quizID
            context.insert(quiz)
            context.insert(QueueRecord(.init(current: quizID.uuidString, position: 0, run: 3, day: day,
                                             attemptedByKid: true, started: true)))
        }
        if version == 3 {
            context.insert(SchemaV3.QuizAttempt(id: attemptID, profileID: kidID, roleRaw: "child", quizSetID: quizID,
                                                run: 3, day: day, number: 2, startedAt: when))
            func answer(_ chosen: String, correct: Bool, points: Int, at time: Date) -> SchemaV3.QuizAnswer {
                SchemaV3.QuizAnswer(id: UUID(), attemptID: attemptID, profileID: kidID, countryID: "FRA",
                                    kindRaw: "name", chosen: chosen, correctAnswer: "France", correct: correct,
                                    basePoints: 10, attemptNumber: 2, usedMultipleChoice: false,
                                    pointsAwarded: points, answeredAt: time)
            }
            context.insert(answer("France", correct: true, points: 5, at: when))
            // Version 3 had no uniqueness rule, so a store could hold a second
            // answer to the same question (same sitting, country and kind).
            context.insert(answer("Spain", correct: false, points: 0, at: when.addingTimeInterval(30)))
            context.insert(SchemaV3.QuizAnswer(id: UUID(), attemptID: attemptID, profileID: kidID, countryID: "ESP",
                                               kindRaw: "name", chosen: "Spain", correctAnswer: "Spain",
                                               correct: true, basePoints: 10, attemptNumber: 2,
                                               usedMultipleChoice: false, pointsAwarded: 5, answeredAt: when))
        }
        if version == 4 {
            let quiz = try XCTUnwrap(try context.fetch(FetchDescriptor<QuizSet>()).first)
            let attempt = SchemaV4.QuizAttempt(profile: kid, quiz: quiz, run: 3, day: day, number: 2,
                                               startedAt: when, targets: [])
            attempt.id = attemptID
            attempt.finishedAt = when.addingTimeInterval(120)
            attempt.questionCount = 3
            attempt.perfectPoints = 40
            context.insert(attempt)
            context.insert(SchemaV4.QuizAnswer(attempt: attempt, countryID: "FRA", kind: .name, chosen: "France",
                                               chosenCountryID: "FRA", correctAnswer: "France",
                                               choices: ["France", "Spain", "Italy", "Peru"], basePoints: 10,
                                               multipleChoice: false, askedAt: when, answeredAt: when.addingTimeInterval(7)))
            context.insert(SchemaV4.QuizAnswer(attempt: attempt, countryID: "FRA", kind: .flag, chosen: "ESP",
                                               chosenCountryID: "ESP", correctAnswer: "FRA",
                                               choices: ["FRA", "ESP"], basePoints: 20, multipleChoice: true,
                                               askedAt: when, answeredAt: when.addingTimeInterval(30)))
        }
        try context.save()
        try checkpoint(url)
    }

    /// Folds the write-ahead log into the main file and removes the side
    /// files, so each fixture is one self-contained file.
    private static func checkpoint(_ url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }
}
