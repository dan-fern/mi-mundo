import Foundation
import SwiftData
import XCTest
@testable import MiMundo

/// A store written by each older schema must open with the current migration
/// plan and keep the family's data. The old stores are built here from the
/// real versioned schema types (the V3 quiz models are the frozen copies in
/// SchemaV3Frozen.swift), not committed as binary fixtures: that way they
/// can't go stale against the OS's SQLite/SwiftData, and every future schema
/// bump just adds a `write` case.
@MainActor
final class MigrationTests: XCTestCase {
    private var directory: URL!
    private let parentID = UUID(), kidID = UUID(), quizID = UUID(), attemptID = UUID()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent("\(name).store") }

    private func openCurrent(_ url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV5.self)
        return try Persistence.open(schema, ModelConfiguration(schema: schema, url: url))
    }

    /// Writes a store the way version `version` of the app would have.
    private func write(version: Int, to url: URL) throws {
        let schemas: [any VersionedSchema.Type] = [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self]
        let schema = Schema(versionedSchema: schemas[version - 1])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = container.mainContext
        let day: Int32 = 20_000
        let parent = Profile(name: "Mama", emoji: "🦊", role: .parent)
        parent.id = parentID
        parent.pinSalt = Data([1, 2, 3])
        parent.pinHash = Data([4, 5, 6])
        let kid = Profile(name: "Kid", emoji: "🐼", role: .child)
        kid.id = kidID
        context.insert(parent)
        context.insert(kid)
        context.insert(Visit(childID: kidID, day: day))
        context.insert(Session(profile: kid, day: day, startedAt: TestSupport.morning))
        if version >= 2 {
            var draft = QuizDraft()
            draft.title = "Europe"
            draft.countryIDs = ["FRA", "ESP"]
            draft.asksFlag = true
            let quiz = QuizSet(draft: draft, position: 0, createdBy: parentID)
            quiz.id = quizID
            context.insert(quiz)
            context.insert(QueueRecord(.init(current: quizID.uuidString, position: 0, run: 3, day: day,
                                             attemptedByKid: true, started: true)))
        }
        if version == 3 {
            context.insert(SchemaV3.QuizAttempt(id: attemptID, profileID: kidID, roleRaw: "child", quizSetID: quizID,
                                                run: 3, day: day, number: 2, startedAt: TestSupport.morning))
            context.insert(SchemaV3.QuizAnswer(id: UUID(), attemptID: attemptID, profileID: kidID, countryID: "FRA",
                                               kindRaw: "name", chosen: "France", correctAnswer: "France",
                                               correct: true, basePoints: 10, attemptNumber: 2,
                                               usedMultipleChoice: false, pointsAwarded: 5,
                                               answeredAt: TestSupport.morning))
        }
        if version == 4 {
            let quiz = try XCTUnwrap(try context.fetch(FetchDescriptor<QuizSet>()).first)
            let attempt = SchemaV4.QuizAttempt(profile: kid, quiz: quiz, run: 3, day: day, number: 2,
                                               startedAt: TestSupport.morning, targets: [])
            attempt.id = attemptID
            context.insert(attempt)
            context.insert(SchemaV4.QuizAnswer(attempt: attempt, countryID: "FRA", kind: .name, chosen: "France",
                                               chosenCountryID: "FRA", correctAnswer: "France",
                                               choices: ["France", "Spain"], basePoints: 10, multipleChoice: false,
                                               askedAt: TestSupport.morning, answeredAt: TestSupport.morning))
        }
        try context.save()
    }

    private func assertSurvived(version: Int, in container: ModelContainer, file: StaticString = #filePath,
                                line: UInt = #line) throws {
        let context = container.mainContext
        let profiles = try context.fetch(FetchDescriptor<Profile>())
        XCTAssertEqual(Set(profiles.map(\.name)), ["Mama", "Kid"], file: file, line: line)
        let parent = try XCTUnwrap(profiles.first { $0.id == parentID }, file: file, line: line)
        XCTAssertEqual(parent.pinHash, Data([4, 5, 6]), "PIN survives", file: file, line: line)
        XCTAssertEqual(parent.role, .parent, file: file, line: line)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Visit>()), 1, file: file, line: line)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 1, file: file, line: line)
        guard version >= 2 else { return }
        let quizzes = try context.fetch(FetchDescriptor<QuizSet>())
        XCTAssertEqual(quizzes.map(\.title), ["Europe"], file: file, line: line)
        XCTAssertEqual(quizzes.first?.countryIDs, ["FRA", "ESP"], file: file, line: line)
        XCTAssertEqual(quizzes.first?.asksFlag, true, file: file, line: line)
        let queue = try XCTUnwrap(try context.fetch(FetchDescriptor<QueueRecord>()).first, file: file, line: line)
        XCTAssertEqual(queue.currentQuizID, quizID, file: file, line: line)
        XCTAssertEqual(queue.run, 3, file: file, line: line)
        XCTAssertTrue(queue.attemptedByKid, file: file, line: line)
        guard version >= 3 else { return }
        let attempts = try context.fetch(FetchDescriptor<QuizAttempt>())
        XCTAssertEqual(attempts.count, 1, file: file, line: line)
        XCTAssertEqual(attempts.first?.id, attemptID, file: file, line: line)
        XCTAssertEqual(attempts.first?.number, 2, file: file, line: line)
        XCTAssertEqual(attempts.first?.run, 3, file: file, line: line)
        XCTAssertEqual(attempts.first?.roleRaw, "child", file: file, line: line)
        let answers = try context.fetch(FetchDescriptor<QuizAnswer>())
        XCTAssertEqual(answers.count, 1, file: file, line: line)
        XCTAssertEqual(answers.first?.attemptID, attemptID, file: file, line: line)
        XCTAssertEqual(answers.first?.countryID, "FRA", file: file, line: line)
        XCTAssertEqual(answers.first?.correct, true, file: file, line: line)
        if version == 3 {
            XCTAssertEqual(answers.first?.pointsAwarded, 5, file: file, line: line)
            XCTAssertEqual(answers.first?.basePoints, 10, file: file, line: line)
        }
    }

    func testEveryOldVersionOpensAndKeepsItsData() throws {
        for version in 1...4 {
            let store = url("v\(version)")
            try write(version: version, to: store)
            let container = try openCurrent(store)
            try assertSurvived(version: version, in: container)
            // The new tables exist and work after migrating.
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<FlagDrawing>()), 0)
        }
    }

    func testMigratedStoreAcceptsNewWritesAndReopens() throws {
        let store = url("v4")
        try write(version: 4, to: store)
        do {
            let container = try openCurrent(store)
            let context = container.mainContext
            context.insert(FlagDrawing(answerID: UUID(), profileID: kidID, countryID: "FRA",
                                       content: .freehand(FlagSketch()), scorePercent: 90,
                                       autoCorrect: true, drawnAt: TestSupport.morning))
            try context.save()
        }
        let reopened = try openCurrent(store)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<FlagDrawing>()), 1)
        try assertSurvived(version: 4, in: reopened)
    }

    func testV3AnswersCanBeMarkedAsCurrentModels() throws {
        // V3 → V4 adds fields with defaults: they must read back sensibly.
        let store = url("v3")
        try write(version: 3, to: store)
        let container = try openCurrent(store)
        let answer = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<QuizAnswer>()).first)
        XCTAssertEqual(answer.choices, [])
        XCTAssertNil(answer.askedAt)
        XCTAssertNil(answer.chosenCountryID)
        let attempt = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<QuizAttempt>()).first)
        XCTAssertEqual(attempt.quizCountryIDs, [])
        XCTAssertEqual(attempt.questionCount, 0)
    }

    func testUnreadableStoreIsRejectedNotSilentlyEmptied() throws {
        let store = url("garbage")
        try Data("not a database".utf8).write(to: store)
        XCTAssertThrowsError(try openCurrent(store))
    }
}
