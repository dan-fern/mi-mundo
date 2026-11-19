#if DEBUG
import SwiftData

/// Launch arguments for the UI tests (Debug builds only; none of this is
/// compiled into Release).
///
/// - `-uiTesting`: use a fresh in-memory store, so each test starts empty
///   and nothing touches the iPad's real data.
/// - `-uiTestSeed`: also add a parent ("Pat", PIN 1234), a kid ("Kit"),
///   and a one-country quiz about France asking name, capital and flag.
enum UITestLaunch {
    static let flag = "-uiTesting"
    static let seedFlag = "-uiTestSeed"

    @MainActor
    static func makeContainer() -> ModelContainer? {
        let args = CommandLine.arguments
        guard args.contains(flag) else { return nil }
        let schema = Schema(versionedSchema: SchemaV5.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        guard let container = try? Persistence.open(schema, configuration) else { return nil }
        if args.contains(seedFlag) { seed(container.mainContext) }
        return container
    }

    @MainActor
    private static func seed(_ context: ModelContext) {
        let parent = Profile(name: "Pat", emoji: "🦉", role: .parent)
        PIN.set("1234", on: parent)
        context.insert(parent)
        context.insert(Profile(name: "Kit", emoji: "🦊", role: .child))
        context.saveOrRollback("seed profiles")

        var draft = QuizDraft()
        draft.title = "France test"
        draft.countryIDs = ["FRA"]
        draft.asksName = true
        draft.asksCapital = true
        draft.asksFlag = true
        QuizQueue.add(draft, by: parent, in: context)
    }
}
#endif
