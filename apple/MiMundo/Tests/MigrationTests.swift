import Foundation
import SwiftData
import XCTest
@testable import MiMundo

/// A real store from each shipped schema version (V1–V4, committed under
/// Fixtures/, see FixtureWriter.swift) must open with the current migration
/// plan and keep the family's data. Each test opens a copy.
@MainActor
final class MigrationTests: XCTestCase {
    private var directory: URL!
    private typealias F = FixtureWriter

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A scratch copy of the committed fixture for `version`.
    private func fixtureCopy(_ version: Int) throws -> URL {
        let bundle = Bundle(for: MigrationTests.self)
        let source = try XCTUnwrap(bundle.url(forResource: "v\(version)", withExtension: "store"),
                                   "Missing fixture v\(version).store")
        let copy = directory.appendingPathComponent("v\(version).store")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func openCurrent(_ url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV5.self)
        return try Persistence.open(schema, ModelConfiguration(schema: schema, url: url))
    }

    /// Run once per new schema version (see FixtureWriter): writes the
    /// fixtures to $WRITE_FIXTURES_TO. Skipped otherwise.
    func testWriteFixtures() throws {
        guard let path = ProcessInfo.processInfo.environment["WRITE_FIXTURES_TO"], !path.isEmpty else {
            throw XCTSkip("Only runs with TEST_RUNNER_WRITE_FIXTURES_TO set")
        }
        for version in 1...4 {
            let url = URL(fileURLWithPath: path).appendingPathComponent("v\(version).store")
            try? FileManager.default.removeItem(at: url)
            try F.write(version: version, to: url)
        }
    }

    // MARK: - What survives

    private func assertSurvived(version: Int, in container: ModelContainer, file: StaticString = #filePath,
                                line: UInt = #line) throws {
        let context = container.mainContext
        let profiles = try context.fetch(FetchDescriptor<Profile>())
        XCTAssertEqual(Set(profiles.map(\.name)), ["Mama", "Kid"], file: file, line: line)
        let parent = try XCTUnwrap(profiles.first { $0.id == F.parentID }, file: file, line: line)
        XCTAssertEqual(parent.pinHash, Data([4, 5, 6]), "PIN survives", file: file, line: line)
        XCTAssertEqual(parent.pinSalt, Data([1, 2, 3]), file: file, line: line)
        XCTAssertEqual(parent.role, .parent, file: file, line: line)
        let visits = try context.fetch(FetchDescriptor<Visit>())
        XCTAssertEqual(visits.map(\.childID), [F.kidID], file: file, line: line)
        XCTAssertEqual(visits.first?.day, F.day, file: file, line: line)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 1, file: file, line: line)
        guard version >= 2 else { return }
        let quizzes = try context.fetch(FetchDescriptor<QuizSet>())
        XCTAssertEqual(quizzes.map(\.title), ["Europe"], file: file, line: line)
        XCTAssertEqual(quizzes.first?.countryIDs, ["FRA", "ESP"], file: file, line: line)
        XCTAssertEqual(quizzes.first?.asksFlag, true, file: file, line: line)
        let queue = try XCTUnwrap(try context.fetch(FetchDescriptor<QueueRecord>()).first, file: file, line: line)
        XCTAssertEqual(queue.currentQuizID, F.quizID, file: file, line: line)
        XCTAssertEqual(queue.run, 3, file: file, line: line)
        XCTAssertTrue(queue.attemptedByKid, file: file, line: line)
        guard version >= 3 else { return }
        let attempts = try context.fetch(FetchDescriptor<QuizAttempt>())
        XCTAssertEqual(attempts.count, 1, file: file, line: line)
        XCTAssertEqual(attempts.first?.id, F.attemptID, file: file, line: line)
        XCTAssertEqual(attempts.first?.number, 2, file: file, line: line)
        XCTAssertEqual(attempts.first?.run, 3, file: file, line: line)
        XCTAssertEqual(attempts.first?.roleRaw, "child", file: file, line: line)
        XCTAssertEqual(attempts.first?.quizSetID, F.quizID, file: file, line: line)
    }

    func testEveryOldVersionOpensAndKeepsItsData() throws {
        for version in [1, 2, 4] {
            let container = try openCurrent(try fixtureCopy(version))
            try assertSurvived(version: version, in: container)
            // The newest tables exist and work after migrating.
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<FlagDrawing>()), 0)
        }
    }

    func testV4AnswersAndAttemptKeepTheirStats() throws {
        let container = try openCurrent(try fixtureCopy(4))
        let context = container.mainContext
        try assertSurvived(version: 4, in: container)
        let attempt = try XCTUnwrap(try context.fetch(FetchDescriptor<QuizAttempt>()).first)
        XCTAssertEqual(attempt.finishedAt, F.when.addingTimeInterval(120))
        XCTAssertEqual(attempt.questionCount, 3)
        XCTAssertEqual(attempt.perfectPoints, 40)
        XCTAssertEqual(attempt.quizCountryIDs, ["FRA", "ESP"])
        let answers = try context.fetch(FetchDescriptor<QuizAnswer>(sortBy: [SortDescriptor(\.answeredAt)]))
        XCTAssertEqual(answers.map(\.kindRaw), ["name", "flag"])
        let name = answers[0], flag = answers[1]
        XCTAssertEqual(name.pointsAwarded, 5, "attempt 2 earns half of 10")
        XCTAssertTrue(name.correct)
        XCTAssertEqual(name.chosenCountryID, "FRA")
        XCTAssertEqual(name.choices, ["France", "Spain", "Italy", "Peru"])
        XCTAssertEqual(name.askedAt, F.when)
        XCTAssertEqual(name.answeredAt, F.when.addingTimeInterval(7))
        XCTAssertFalse(flag.correct)
        XCTAssertEqual(flag.pointsAwarded, 0)
        XCTAssertTrue(flag.usedMultipleChoice)
        XCTAssertEqual(flag.chosenCountryID, "ESP")
    }

    // MARK: - Version 3

    /// Version 3 had no uniqueness rule, and version 4 adds one on
    /// (sitting, country, question). A store holding two answers to the same
    /// question has to open anyway (MiMundoMigrationPlan's custom stage drops
    /// the later duplicate): otherwise the family's data would be moved aside.
    func testV3StoreWithDuplicateAnswersStillOpens() throws {
        let container = try openCurrent(try fixtureCopy(3))
        try assertSurvived(version: 3, in: container)
        let answers = try container.mainContext.fetch(FetchDescriptor<QuizAnswer>())
        // The earliest answer to each question is kept; the duplicate is dropped.
        let france = answers.filter { $0.countryID == "FRA" }
        XCTAssertEqual(france.count, 1)
        XCTAssertEqual(france.first?.chosen, "France")
        XCTAssertEqual(france.first?.pointsAwarded, 5)
        XCTAssertTrue(answers.contains { $0.countryID == "ESP" && $0.correct && $0.pointsAwarded == 5 })
        XCTAssertEqual(answers.count, 2)
        // And the store keeps working afterwards.
        try container.mainContext.save()
    }

    func testV3AnswersGainDefaultedFields() throws {
        let container = try openCurrent(try fixtureCopy(3))
        let context = container.mainContext
        let answers = try context.fetch(FetchDescriptor<QuizAnswer>())
        XCTAssertFalse(answers.isEmpty)
        for answer in answers {
            XCTAssertEqual(answer.choices, [])
            XCTAssertNil(answer.askedAt)
            XCTAssertNil(answer.chosenCountryID)
        }
        let attempt = try XCTUnwrap(try context.fetch(FetchDescriptor<QuizAttempt>()).first)
        XCTAssertEqual(attempt.quizCountryIDs, [])
        XCTAssertEqual(attempt.questionCount, 0)
        XCTAssertEqual(attempt.perfectPoints, 0)
        // Version 5 adds only the drawings table, empty.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FlagDrawing>()), 0)
    }

    // MARK: - After migrating

    func testMigratedStoreAcceptsNewWritesAndReopens() throws {
        let store = try fixtureCopy(4)
        do {
            let container = try openCurrent(store)
            let context = container.mainContext
            context.insert(FlagDrawing(answerID: UUID(), profileID: F.kidID, countryID: "FRA",
                                       content: .freehand(FlagSketch()), scorePercent: 90,
                                       autoCorrect: true, drawnAt: F.when))
            try context.save()
        }
        let reopened = try openCurrent(store)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<FlagDrawing>()), 1)
        try assertSurvived(version: 4, in: reopened)
    }

    // MARK: - A store that can't be opened

    func testUnreadableStoreIsMovedAsideNotDeleted() throws {
        let store = directory.appendingPathComponent("default.store")
        let garbage = Data("not a database".utf8)
        try garbage.write(to: store)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "migration-\(UUID().uuidString)"))

        let container = Persistence.makeContainer(at: store, defaults: defaults)

        // The parent is told (parent home shows it)...
        XCTAssertNotNil(defaults.object(forKey: Persistence.movedAsideKey))
        // ...the old file is kept next to the new store, untouched...
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("default.store.unreadable-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(aside[0])), garbage)
        // ...and the app starts fresh, with a store that works.
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Profile>()), 0)
        container.mainContext.insert(Profile(name: "New", emoji: "🐢", role: .parent))
        try container.mainContext.save()
    }

    func testReadableStoreIsNeverMovedAside() throws {
        let store = try fixtureCopy(4)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "migration-\(UUID().uuidString)"))
        let container = Persistence.makeContainer(at: store, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: Persistence.movedAsideKey))
        try assertSurvived(version: 4, in: container)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains { $0.contains("unreadable") })
    }
}
