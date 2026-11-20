import Foundation
import SwiftData
import XCTest
@testable import MiMundo

/// Shared helpers for the app's tests.
enum TestSupport {
    /// A fresh in-memory store with the current schema.
    @MainActor
    static func memoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: SchemaV6.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// The real bundled map (the tests are hosted by the app, so
    /// `Bundle.main` is the app). Loaded once.
    @MainActor private static var cachedAtlas: Atlas?
    @MainActor
    static func atlas() async throws -> Atlas {
        if let cachedAtlas { return cachedAtlas }
        let atlas = try await Atlas.load()
        cachedAtlas = atlas
        return atlas
    }

    /// Wednesday 14 Jan 2026, 7 am ET: mid-morning of one game day.
    static let morning = Date(timeIntervalSince1970: 1_768_392_000)
    /// 10:59 pm ET that evening: still the same game day.
    static let lastMinute = Date(timeIntervalSince1970: 1_768_449_540)
    /// 11:00 pm ET that evening: the next game day has begun.
    static let nextDayStart = Date(timeIntervalSince1970: 1_768_449_600)
    /// Mid-morning the day after `morning`.
    static let nextMorning = morning.addingTimeInterval(86_400)
    static func morning(plusDays days: Int) -> Date { morning.addingTimeInterval(Double(days) * 86_400) }
}

@MainActor
final class Family {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let parent = Profile(name: "Mama", emoji: "🦊", role: .parent)
    let kid = Profile(name: "Kid", emoji: "🐼", role: .child)

    init() throws {
        container = try TestSupport.memoryContainer()
        context.insert(parent)
        context.insert(kid)
        try context.save()
    }

    @discardableResult
    func addQuiz(_ title: String, _ ids: [String] = ["FRA"], flag: Bool = false,
                 now: Date = TestSupport.morning) -> QuizSet {
        var draft = QuizDraft()
        draft.title = title
        draft.countryIDs = ids
        draft.asksFlag = flag
        XCTAssertTrue(QuizQueue.add(draft, by: parent, in: context, now: now))
        return QuizQueue.quizzes(in: context).first { $0.title == title }!
    }

    func fetchAll<T: PersistentModel>(_ type: T.Type) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    var record: QueueRecord? { fetchAll(QueueRecord.self).first }
}
