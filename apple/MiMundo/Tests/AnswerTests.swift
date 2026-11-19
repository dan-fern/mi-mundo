import MiMundoCore
import SwiftData
import XCTest
@testable import MiMundo

/// Recording answers: points per sitting, multiple choice, grader verdicts,
/// saved drawings and the one-answer-per-question constraint.
@MainActor
final class AnswerTests: XCTestCase {
    var family: Family!
    var atlas: Atlas!
    var france: AtlasCountry!
    var quiz: QuizSet!

    override func setUp() async throws {
        family = try Family()
        atlas = try await TestSupport.atlas()
        france = try XCTUnwrap(atlas.countries.first { $0.meta.id == "FRA" })
        quiz = family.addQuiz("France", flag: true)
        quiz.namePoints = 100
        quiz.flagPoints = 100
    }

    private func sitting(_ profile: Profile? = nil, now: Date = TestSupport.morning) throws -> QuizAttempt {
        let targets = QuizTarget.all(for: quiz, in: atlas)
        return try XCTUnwrap(QuizPlay.begin(quiz, targets: targets, for: profile ?? family.kid,
                                            in: family.context, now: now))
    }

    @discardableResult
    private func answer(_ attempt: QuizAttempt, _ chosen: String = "France", kind: QuestionKind = .name,
                        multipleChoice: Bool = false, isCorrect: Bool? = nil,
                        drawing: (content: FlagDrawingContent, scorePercent: Int)? = nil) -> QuizAnswer? {
        QuizPlay.record(chosen, correctAnswer: "France", kind: kind, country: france, chosenCountry: nil,
                        choices: ["France", "Spain"], multipleChoice: multipleChoice, isCorrect: isCorrect,
                        drawing: drawing, quiz: quiz, attempt: attempt, askedAt: nil,
                        in: family.context, now: TestSupport.morning)
    }

    /// Plays a whole sitting (name only) and finishes it, for the nth time.
    private func finishedSittings(_ count: Int) throws -> QuizAttempt {
        var attempt = try sitting()
        for n in 1..<count {
            XCTAssertEqual(attempt.number, n)
            answer(attempt)
            QuizPlay.finish(attempt, in: family.context)
            attempt = try sitting()
        }
        return attempt
    }

    func testPointsPerSitting() throws {
        // Sittings 1, 2, 3 earn full, half and a quarter; the 4th earns nothing.
        for (number, expected) in [(1, 100), (2, 50), (3, 25), (4, 0), (5, 0)] {
            let attempt = try finishedSittings(number)
            XCTAssertEqual(attempt.number, number)
            let result = try XCTUnwrap(answer(attempt))
            XCTAssertTrue(result.correct)
            XCTAssertEqual(result.attemptNumber, number)
            XCTAssertEqual(result.pointsAwarded, expected, "sitting \(number)")
            // Clean up so the next loop builds its own history from scratch.
            family.fetchAll(QuizAnswer.self).forEach(family.context.delete)
            family.fetchAll(QuizAttempt.self).forEach(family.context.delete)
            try family.context.save()
        }
    }

    func testWrongAnswerEarnsNothing() throws {
        let result = try XCTUnwrap(answer(try sitting(), "Spain"))
        XCTAssertFalse(result.correct)
        XCTAssertEqual(result.pointsAwarded, 0)
    }

    func testMultipleChoiceEarnsHalf() throws {
        let attempt = try sitting()
        let result = try XCTUnwrap(answer(attempt, "FRA", kind: .flag, multipleChoice: true, isCorrect: true))
        XCTAssertTrue(result.usedMultipleChoice)
        XCTAssertEqual(result.pointsAwarded, 50)
    }

    func testDrawnFlagEarnsFullPoints() throws {
        let attempt = try sitting()
        let sketch = FlagDrawingContent.freehand(FlagSketch(background: nil, strokes: [], widths: []))
        let result = try XCTUnwrap(answer(attempt, "drawn", kind: .flag, isCorrect: true,
                                          drawing: (sketch, 97)))
        XCTAssertEqual(result.pointsAwarded, 100)
    }

    func testGraderVerdictOverridesExactMatch() throws {
        let attempt = try sitting()
        // Close shades count: the text differs but the grader says right.
        let right = try XCTUnwrap(answer(attempt, "close enough", kind: .flag, isCorrect: true))
        XCTAssertTrue(right.correct)
        XCTAssertEqual(right.pointsAwarded, 100)
        // And an exact text match is still wrong if the grader says so.
        let wrong = try XCTUnwrap(answer(attempt, "France", kind: .name, isCorrect: false))
        XCTAssertFalse(wrong.correct)
        XCTAssertEqual(wrong.pointsAwarded, 0)
    }

    func testDrawingIsSavedWithTheAnswer() throws {
        let attempt = try sitting()
        let content = FlagDrawingContent.outline(layout: "bands3", painted: ["blue", "white", "red"], strokes: [])
        let result = try XCTUnwrap(answer(attempt, "drawn", kind: .flag, isCorrect: false,
                                          drawing: (content, -1)))
        let drawings = family.fetchAll(FlagDrawing.self)
        XCTAssertEqual(drawings.count, 1)
        let drawing = try XCTUnwrap(drawings.first)
        XCTAssertEqual(drawing.answerID, result.id)
        XCTAssertEqual(drawing.profileID, family.kid.id)
        XCTAssertEqual(drawing.countryID, "FRA")
        XCTAssertEqual(drawing.methodRaw, "outline")
        XCTAssertEqual(drawing.scorePercent, -1)
        XCTAssertFalse(drawing.autoCorrect)
        XCTAssertEqual(drawing.decoded, content)
        XCTAssertNil(drawing.parentVerdict)
    }

    func testNoDrawingMeansNoFlagDrawingRow() throws {
        XCTAssertNotNil(answer(try sitting()))
        XCTAssertTrue(family.fetchAll(FlagDrawing.self).isEmpty)
    }

    func testSecondAnswerToTheSameQuestionDoesNotDuplicate() throws {
        let attempt = try sitting()
        XCTAssertNotNil(answer(attempt, "Spain"))
        _ = answer(attempt, "France")
        // One row per sitting, country and question, whatever happened to
        // the second save.
        XCTAssertEqual(family.fetchAll(QuizAnswer.self).count, 1)
        // A different question about the same country is a different row.
        XCTAssertNotNil(answer(attempt, "Paris", kind: .capital))
        XCTAssertEqual(family.fetchAll(QuizAnswer.self).count, 2)
    }

    func testReviewVerdictRescoresAnswer() throws {
        let attempt = try sitting()
        let content = FlagDrawingContent.freehand(FlagSketch())
        let result = try XCTUnwrap(answer(attempt, "drawn", kind: .flag, isCorrect: false, drawing: (content, 10)))
        let drawing = try XCTUnwrap(family.fetchAll(FlagDrawing.self).first)
        XCTAssertTrue(DrawingReview.setVerdict(true, on: drawing, in: family.context))
        XCTAssertEqual(result.pointsAwarded, 100)
        XCTAssertTrue(DrawingReview.setVerdict(false, on: drawing, in: family.context))
        XCTAssertEqual(result.pointsAwarded, 0)
        XCTAssertTrue(DrawingReview.setVerdict(nil, on: drawing, in: family.context))
        XCTAssertFalse(result.correct)
        XCTAssertNil(drawing.reviewedAt)
    }
}
