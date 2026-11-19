import MiMundoCore
import XCTest
@testable import MiMundo

/// One call per function the Rust core exports, checking the answer comes
/// back through the generated bindings intact (types, strings, byte buffers,
/// records, optionals and errors). The Rust tests cover the logic; this only
/// catches a bindings change drifting silently.
final class UniFFISmokeTests: XCTestCase {
    private func resource(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: ext))
        return try Data(contentsOf: url)
    }

    func testCoreVersion() {
        XCTAssertFalse(coreVersion().isEmpty)
    }

    func testAttendance() {
        XCTAssertGreaterThan(attendanceMax(), 0)
        XCTAssertEqual(attendanceLevel(daysOpenedLast7: 0), 0)
        let days: [Int32] = [98, 99, 100]
        XCTAssertEqual(daysPlayedLast7(visitDays: days, today: 100), 3)
        XCTAssertEqual(dayStreak(visitDays: days, today: 100), 3)
        XCTAssertEqual(attendanceLevelFor(visitDays: days, today: 100), attendanceLevel(daysOpenedLast7: 3))
        let summary = attendanceSummary(visitDays: days, today: 100)
        XCTAssertEqual(summary.daysPlayedLast7, 3)
        XCTAssertEqual(summary.streak, 3)
        XCTAssertEqual(summary.maxLevel, attendanceMax())
        XCTAssertEqual(summary.level, attendanceLevelFor(visitDays: days, today: 100))
    }

    func testGameDays() {
        // Wednesday 14 Jan 2026, 7 am ET; 11 pm ET that night starts the next game day.
        let day = gameDay(unixSeconds: 1_768_392_000)
        XCTAssertEqual(gameDayLabel(day: day), "2026-01-14")
        XCTAssertEqual(gameDay(unixSeconds: 1_768_392_000 + 16 * 3600), day + 1)
        XCTAssertEqual(gameDayLabel(day: 0), "1970-01-01")
    }

    func testFlagOutlineFunctions() {
        XCTAssertEqual(flagLayoutRegions(layout: "v3"), 3)
        XCTAssertEqual(flagLayoutRegions(layout: "nope"), 0)
        XCTAssertEqual(flagPalette().first, "red")
        XCTAssertTrue(flagColoursMatch(expected: "blue", painted: "lightblue"))
        XCTAssertFalse(flagColoursMatch(expected: "green", painted: "red"))
        let choices = flagLayoutChoices(correct: "v3", seed: 7)
        XCTAssertEqual(choices.count, 6)
        XCTAssertTrue(choices.contains("v3"))
        XCTAssertEqual(choices, flagLayoutChoices(correct: "v3", seed: 7))
        let grade = gradeFlagOutline(layout: "v3", colors: ["blue", "white", "red"],
                                     chosenLayout: "v3", painted: ["blue", "white", "blue"])
        XCTAssertTrue(grade.layoutRight)
        XCTAssertFalse(grade.correct)
        XCTAssertEqual(grade.regionsRight, [true, true, false])
    }

    func testFreehandFunctions() {
        let rgba = Data([255, 255, 255, 255, 0, 0, 0, 255, 9, 9, 9, 0])
        let classified = classifyPixels(rgba: rgba)
        XCTAssertEqual(classified.count, 3)
        XCTAssertEqual(classified.last, 255) // transparent: blank
        let flag = Data([6, 6, 7, 7, 0, 0, 6, 6, 7, 7, 0, 0])
        let good = gradeFreehand(reference: flag, drawing: flag, outline: Data(), width: 6, height: 2)
        XCTAssertTrue(good.correct)
        XCTAssertEqual(good.scorePercent, 100)
        XCTAssertEqual(good.wrongCells.count, 12)
        let blank = gradeFreehand(reference: flag, drawing: Data(repeating: 255, count: 12),
                                  outline: Data(), width: 6, height: 2)
        XCTAssertFalse(blank.correct)
    }

    func testMapFunctions() throws {
        let origin = project(lonDeg: 0, latDeg: 0)
        XCTAssertTrue(origin.x.isFinite && origin.y.isFinite)
        XCTAssertFalse(worldOutline().isEmpty)
        let features = try loadFeatures(bytes: try resource("Features", "bin"))
        XCTAssertFalse(features.isEmpty)
        XCTAssertThrowsError(try loadFeatures(bytes: Data([1, 2, 3])))
    }

    func testWorldObject() throws {
        let world = try World(bytes: try resource("World", "bin"))
        let countries = world.countries()
        XCTAssertGreaterThan(countries.count, 100)
        XCTAssertEqual(world.shapes(detail: .coarse).count, countries.count)
        XCTAssertNil(world.countryAt(x: -1e6, y: -1e6, tolerance: 0))
        XCTAssertThrowsError(try World(bytes: Data()))
    }

    func testQueueFunctions() {
        XCTAssertEqual(queueMax(), 20)
        var state = queueInitialState(today: 10)
        XCTAssertNil(state.current)
        state = queueToday(state: state, queue: ["a", "b", "c"], today: 10)
        XCTAssertEqual(state.current, "a")
        XCTAssertEqual(queueSetToday(state: state, queue: ["a", "b", "c"], id: "c").current, "c")
        XCTAssertEqual(queueFromToday(queue: ["a", "b", "c"], current: "b"), ["b", "c", "a"])
        state.attemptedByKid = true
        XCTAssertEqual(queueToday(state: state, queue: ["a", "b", "c"], today: 11).current, "b")
    }

    func testQuizAndScoring() {
        let choices = quizChoices(correct: "FRA", candidates: ["FRA", "ESP", "ITA", "DEU", "PRT"], seed: 3)
        XCTAssertTrue(choices.contains("FRA"))
        XCTAssertEqual(Set(choices).count, choices.count)
        XCTAssertEqual(quizStars(correct: 0, total: 10), 0)
        XCTAssertGreaterThan(quizStars(correct: 10, total: 10), 0)
        XCTAssertEqual(pointsForAttempt(basePoints: 100, attempt: 2, usedMultipleChoice: true), 25)
        XCTAssertEqual(pointsForAttempt(basePoints: UInt32.max, attempt: 1, usedMultipleChoice: false), UInt32.max)
    }
}
