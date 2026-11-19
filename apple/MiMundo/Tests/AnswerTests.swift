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
        try await freshFamily()
    }

    /// A new in-memory family with one France quiz (name and flag worth 100).
    private func freshFamily() async throws {
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
                        multipleChoice: Bool = false, isCorrect: Bool? = nil, creditPercent: Int? = nil,
                        drawing: (content: FlagDrawingContent, scorePercent: Int)? = nil) -> QuizAnswer? {
        QuizPlay.record(chosen, correctAnswer: "France", kind: kind, country: france, chosenCountry: nil,
                        choices: ["France", "Spain"], multipleChoice: multipleChoice, isCorrect: isCorrect,
                        creditPercent: creditPercent, drawing: drawing, quiz: quiz, attempt: attempt, askedAt: nil,
                        in: family.context, now: TestSupport.morning)
    }

    /// A fresh family and quiz, with `count - 1` finished sittings behind it,
    /// and the next sitting open (so its number is `count`).
    private func sitting(number count: Int) async throws -> QuizAttempt {
        try await freshFamily()
        var attempt = try sitting()
        for n in 1..<count {
            XCTAssertEqual(attempt.number, n)
            answer(attempt)
            QuizPlay.finish(attempt, in: family.context)
            attempt = try sitting()
        }
        return attempt
    }

    func testPointsPerSitting() async throws {
        // Sittings 1, 2, 3 earn full, three quarters and half; the 4th and
        // later are just for fun, but still recorded, as right, for the stats
        // (§3.4). Each case starts from a fresh family, so none shares queue state.
        for (number, expected) in [(1, 100), (2, 75), (3, 50), (4, 0), (5, 0)] {
            let attempt = try await sitting(number: number)
            XCTAssertEqual(attempt.number, number)
            let result = try XCTUnwrap(answer(attempt))
            XCTAssertTrue(result.correct)
            XCTAssertEqual(result.attemptNumber, number)
            XCTAssertEqual(result.pointsAwarded, expected, "sitting \(number)")
            let stored = family.fetchAll(QuizAnswer.self).filter { $0.attemptID == attempt.id }
            XCTAssertEqual(stored.count, 1, "sitting \(number) is recorded even at 0 points")
        }
    }

    func testMultipleChoiceHalvesOnTopOfTheSitting() async throws {
        for (number, expected) in [(1, 50), (2, 37), (3, 25), (4, 0)] {
            let attempt = try await sitting(number: number)
            let result = try XCTUnwrap(answer(attempt, "FRA", kind: .flag, multipleChoice: true, isCorrect: true))
            XCTAssertEqual(result.pointsAwarded, expected, "multiple choice, sitting \(number)")
        }
    }

    func testNameAndCapitalAnswersAreNeverMultipleChoice() throws {
        // The flag is only ever set for flag questions; the model trusts its
        // caller, so this documents what the UI relies on: a name answer
        // recorded without it earns full points.
        let result = try XCTUnwrap(answer(try sitting(), "France", kind: .name))
        XCTAssertFalse(result.usedMultipleChoice)
        XCTAssertEqual(result.pointsAwarded, 100)
    }

    func testWrongAnswerEarnsNothing() throws {
        let result = try XCTUnwrap(answer(try sitting(), "Spain"))
        XCTAssertFalse(result.correct)
        XCTAssertEqual(result.pointsAwarded, 0)
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
        let content = FlagDrawingContent.outline(layout: "v3", painted: ["blue", "white", "red"], strokes: [])
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

    func testSecondAnswerToTheSameQuestionIsRejectedNotAnOverwrite() throws {
        let attempt = try sitting()
        let first = try XCTUnwrap(answer(attempt, "Spain"))
        XCTAssertFalse(first.correct)
        // A second answer to the same question (same sitting, country, kind)
        // must not replace the first: otherwise a wrong answer could be
        // "fixed" for points.
        XCTAssertNil(answer(attempt, "France"), "the second answer is refused")
        let stored = family.fetchAll(QuizAnswer.self)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.chosen, "Spain")
        XCTAssertEqual(stored.first?.correct, false)
        XCTAssertEqual(stored.first?.pointsAwarded, 0)
        // The refused attempt leaves no stray drawing or lock-state change.
        XCTAssertTrue(family.fetchAll(FlagDrawing.self).isEmpty)
        // A different question about the same country is a different row.
        XCTAssertNotNil(answer(attempt, "Paris", kind: .capital))
        XCTAssertEqual(family.fetchAll(QuizAnswer.self).count, 2)
    }

    func testRefusedDuplicateDrawingIsNotSaved() throws {
        let attempt = try sitting()
        let content = FlagDrawingContent.freehand(FlagSketch())
        XCTAssertNotNil(answer(attempt, "drawn", kind: .flag, isCorrect: false, drawing: (content, 5)))
        XCTAssertNil(answer(attempt, "drawn", kind: .flag, isCorrect: true, drawing: (content, 99)))
        XCTAssertEqual(family.fetchAll(FlagDrawing.self).count, 1)
        XCTAssertEqual(family.fetchAll(FlagDrawing.self).first?.scorePercent, 5)
    }

    func testParentVerdictRescoresAndClearRestoresTheAppsVerdict() throws {
        let attempt = try sitting()
        let content = FlagDrawingContent.freehand(FlagSketch())
        // The app said right (100 points).
        let result = try XCTUnwrap(answer(attempt, "drawn", kind: .flag, isCorrect: true, drawing: (content, 95)))
        let drawing = try XCTUnwrap(family.fetchAll(FlagDrawing.self).first)
        XCTAssertEqual(result.pointsAwarded, 100)

        XCTAssertTrue(DrawingReview.setVerdict(false, on: drawing, in: family.context, now: TestSupport.nextMorning))
        XCTAssertFalse(result.correct)
        XCTAssertEqual(result.pointsAwarded, 0)
        XCTAssertEqual(drawing.parentVerdict, false)
        XCTAssertEqual(drawing.reviewedAt, TestSupport.nextMorning)
        XCTAssertFalse(drawing.isCorrect)

        XCTAssertTrue(DrawingReview.setVerdict(true, on: drawing, in: family.context))
        XCTAssertTrue(result.correct)
        XCTAssertEqual(result.pointsAwarded, 100)

        // Clearing puts back the app's verdict (right), and forgets the review.
        XCTAssertTrue(DrawingReview.setVerdict(false, on: drawing, in: family.context))
        XCTAssertTrue(DrawingReview.setVerdict(nil, on: drawing, in: family.context))
        XCTAssertTrue(result.correct)
        XCTAssertEqual(result.pointsAwarded, 100)
        XCTAssertNil(drawing.parentVerdict)
        XCTAssertNil(drawing.reviewedAt)
        XCTAssertTrue(drawing.isCorrect)
    }

    func testVerdictOnAWrongAnswerAwardsWhatThatSittingWasWorth() async throws {
        let attempt = try await sitting(number: 2)
        let content = FlagDrawingContent.freehand(FlagSketch())
        let result = try XCTUnwrap(answer(attempt, "drawn", kind: .flag, isCorrect: false, drawing: (content, 10)))
        let drawing = try XCTUnwrap(family.fetchAll(FlagDrawing.self).first)
        XCTAssertTrue(DrawingReview.setVerdict(true, on: drawing, in: family.context))
        XCTAssertEqual(result.pointsAwarded, 75, "second sitting: three quarters")
        XCTAssertTrue(DrawingReview.setVerdict(nil, on: drawing, in: family.context))
        XCTAssertEqual(result.pointsAwarded, 0)
        XCTAssertFalse(result.correct)
    }

    func testVerdictOnAMultipleChoiceAnswerKeepsTheHalf() throws {
        let attempt = try sitting()
        let content = FlagDrawingContent.outline(layout: "v3", painted: [], strokes: [])
        let result = try XCTUnwrap(answer(attempt, "FRA", kind: .flag, multipleChoice: true, isCorrect: false,
                                          drawing: (content, -1)))
        let drawing = try XCTUnwrap(family.fetchAll(FlagDrawing.self).first)
        XCTAssertTrue(DrawingReview.setVerdict(true, on: drawing, in: family.context))
        XCTAssertEqual(result.pointsAwarded, 50)
    }

    func testAMirrorImageEarnsThreeQuartersButIsNotRight() throws {
        let attempt = try sitting()
        let content = FlagDrawingContent.freehand(FlagSketch())
        let result = try XCTUnwrap(answer(attempt, "drawn", kind: .flag, isCorrect: false, creditPercent: 75,
                                          drawing: (content, 40)))
        XCTAssertFalse(result.correct)
        XCTAssertEqual(result.pointsAwarded, 75)
        let drawing = try XCTUnwrap(family.fetchAll(FlagDrawing.self).first)
        XCTAssertEqual(drawing.autoCreditPercent, 75)
        XCTAssertEqual(drawing.creditPercent, 75)
        XCTAssertFalse(drawing.isCorrect)
    }

    func testTheRightColoursEarnHalfOnTopOfTheSitting() async throws {
        let attempt = try await sitting(number: 2)
        let content = FlagDrawingContent.freehand(FlagSketch())
        let result = try XCTUnwrap(answer(attempt, "drawn", kind: .flag, isCorrect: false, creditPercent: 50,
                                          drawing: (content, 30)))
        XCTAssertEqual(result.pointsAwarded, 37, "half of the second sitting's three quarters")
    }

    func testParentVerdictOnAPartlyRightDrawingAndClearingRestoresThePart() throws {
        let attempt = try sitting()
        let content = FlagDrawingContent.freehand(FlagSketch())
        let result = try XCTUnwrap(answer(attempt, "drawn", kind: .flag, isCorrect: false, creditPercent: 75,
                                          drawing: (content, 40)))
        let drawing = try XCTUnwrap(family.fetchAll(FlagDrawing.self).first)
        XCTAssertTrue(DrawingReview.setVerdict(true, on: drawing, in: family.context))
        XCTAssertTrue(result.correct)
        XCTAssertEqual(result.pointsAwarded, 100)
        XCTAssertTrue(DrawingReview.setVerdict(false, on: drawing, in: family.context))
        XCTAssertEqual(result.pointsAwarded, 0)
        XCTAssertTrue(DrawingReview.setVerdict(nil, on: drawing, in: family.context))
        XCTAssertFalse(result.correct)
        XCTAssertEqual(result.pointsAwarded, 75, "back to the app's three quarters")
    }

    func testADrawingFromBeforePartCreditCountsAsAllOrNothing() {
        let old = FlagDrawing(answerID: UUID(), profileID: family.kid.id, countryID: "FRA",
                              content: .freehand(FlagSketch()), scorePercent: 90,
                              autoCorrect: true, drawnAt: TestSupport.morning)
        XCTAssertNil(old.autoCreditPercent)
        XCTAssertEqual(old.appCreditPercent, 100)
        old.autoCorrect = false
        XCTAssertEqual(old.appCreditPercent, 0)
    }

    /// Flags too alike to tell apart as buttons are never offered together,
    /// even for neighbours (Romania's nearest country is Moldova).
    func testLookAlikeFlagsAreNeverOfferedTogether() throws {
        let byISO = Dictionary(atlas.countries.map { ($0.meta.iso2, $0) }, uniquingKeysWith: { a, _ in a })
        for group in Atlas.flagLookAlikeGroups {
            for code in group {
                guard let country = byISO[code], country.hasFlag else { continue }
                let others = Set(group.subtracting([code]).compactMap { byISO[$0]?.meta.id })
                for seed: UInt64 in 0..<40 {
                    let made = atlas.choices(for: .flag, about: country, seed: seed)
                    XCTAssertTrue(others.isDisjoint(with: made.all), "\(code) offered with a look-alike: \(made.all)")
                }
            }
        }
        XCTAssertEqual(Atlas.flagLookAlikes["RO"], ["TD", "AD", "MD"])
        XCTAssertEqual(Atlas.flagLookAlikes["MD"], ["TD", "AD", "RO"])
    }

    func testVerdictForADrawingWhoseAnswerIsMissingDoesNotCrash() throws {
        let drawing = FlagDrawing(answerID: UUID(), profileID: family.kid.id, countryID: "FRA",
                                  content: .freehand(FlagSketch()), scorePercent: 50,
                                  autoCorrect: false, drawnAt: TestSupport.morning)
        family.context.insert(drawing)
        XCTAssertTrue(DrawingReview.setVerdict(true, on: drawing, in: family.context))
        XCTAssertEqual(drawing.parentVerdict, true)
        XCTAssertNotNil(drawing.reviewedAt)
    }
}
