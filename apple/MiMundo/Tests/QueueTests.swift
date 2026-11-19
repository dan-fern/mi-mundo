import MiMundoCore
import SwiftData
import XCTest
@testable import MiMundo

/// The family queue and the edit lock: a kid's first ANSWER locks today's
/// quiz (opening it doesn't), a parent's never does, and the queue moves on
/// at 11 pm ET only if a kid attempted.
@MainActor
final class QueueTests: XCTestCase {
    var family: Family!
    var atlas: Atlas!
    var a: QuizSet!, b: QuizSet!, c: QuizSet!

    override func setUp() async throws {
        family = try Family()
        atlas = try await TestSupport.atlas()
        a = family.addQuiz("A", ["FRA"])
        b = family.addQuiz("B", ["ESP"])
        c = family.addQuiz("C", ["ITA"])
    }

    private var ctx: ModelContext { family.context }
    private func today(_ now: Date = TestSupport.morning) -> QuizSet? { QuizQueue.refresh(in: ctx, now: now) }

    private func open(_ quiz: QuizSet, as profile: Profile, now: Date = TestSupport.morning) throws -> QuizAttempt {
        try XCTUnwrap(QuizPlay.begin(quiz, targets: QuizTarget.all(for: quiz, in: atlas), for: profile,
                                     in: ctx, now: now))
    }

    private func answerOne(_ quiz: QuizSet, _ attempt: QuizAttempt, now: Date = TestSupport.morning) {
        let country = atlas.countries.first { $0.meta.id == quiz.countryIDs[0] }!
        XCTAssertNotNil(QuizPlay.record(country.name, correctAnswer: country.name, kind: .name, country: country,
                                        chosenCountry: nil, choices: [], quiz: quiz, attempt: attempt,
                                        askedAt: nil, in: ctx, now: now))
    }

    func testFirstQuizInTheQueueIsToday() {
        XCTAssertEqual(today()?.id, a.id)
        XCTAssertEqual(QuizQueue.quizzes(in: ctx).map(\.title), ["A", "B", "C"])
    }

    func testOpeningAloneDoesNotLock() throws {
        _ = try open(a, as: family.kid)
        XCTAssertFalse(QuizQueue.isLocked(a, in: ctx, now: TestSupport.morning))
        XCTAssertTrue(QuizQueue.edit(a, to: draft("A2"), in: ctx, now: TestSupport.morning))
        XCTAssertEqual(a.title, "A2")
    }

    func testKidsFirstAnswerLocks() throws {
        let attempt = try open(a, as: family.kid)
        answerOne(a, attempt)
        XCTAssertTrue(QuizQueue.isLocked(a, in: ctx, now: TestSupport.morning))
        XCTAssertFalse(QuizQueue.edit(a, to: draft("nope"), in: ctx, now: TestSupport.morning))
        XCTAssertEqual(a.title, "A")
        XCTAssertTrue(family.record?.attemptedByKid == true)
    }

    func testParentsAnswerNeverLocks() throws {
        let attempt = try open(a, as: family.parent)
        answerOne(a, attempt)
        XCTAssertFalse(QuizQueue.isLocked(a, in: ctx, now: TestSupport.morning))
        XCTAssertTrue(QuizQueue.edit(a, to: draft("A2"), in: ctx, now: TestSupport.morning))
        XCTAssertTrue(QuizQueue.makeToday(b, in: ctx, now: TestSupport.morning))
        XCTAssertEqual(today()?.id, b.id)
    }

    func testMakeTodayWorksBeforeAnyAnswerAndStartsANewRun() throws {
        let run = try XCTUnwrap(family.record).run
        XCTAssertTrue(QuizQueue.makeToday(c, in: ctx, now: TestSupport.morning))
        XCTAssertEqual(today()?.id, c.id)
        XCTAssertEqual(family.record?.run, run + 1)
        XCTAssertEqual(family.record?.position, 2)
    }

    func testMakeTodayRefusedOnceAKidAnswered() throws {
        answerOne(a, try open(a, as: family.kid))
        XCTAssertFalse(QuizQueue.makeToday(b, in: ctx, now: TestSupport.morning))
        XCTAssertEqual(today()?.id, a.id)
    }

    func testQueueMovesOnAtElevenPMOnlyIfAKidAttempted() throws {
        // Nobody played: stays on A tomorrow.
        XCTAssertEqual(today(TestSupport.nextMorning)?.id, a.id)
        // Opening alone doesn't count.
        _ = try open(a, as: family.kid, now: TestSupport.nextMorning)
        XCTAssertEqual(today(TestSupport.morning(plusDays: 2))?.id, a.id)
        // A kid answers: next game day, the queue moves to B.
        let attempt = try open(a, as: family.kid, now: TestSupport.morning(plusDays: 2))
        answerOne(a, attempt, now: TestSupport.morning(plusDays: 2))
        XCTAssertEqual(today(TestSupport.morning(plusDays: 2))?.id, a.id, "same day")
        XCTAssertEqual(today(TestSupport.morning(plusDays: 3))?.id, b.id)
    }

    func testParentsAnswerDoesNotMoveTheQueueOn() throws {
        answerOne(a, try open(a, as: family.parent))
        XCTAssertEqual(today(TestSupport.nextMorning)?.id, a.id)
    }

    func testElevenPMBoundary() throws {
        let attempt = try open(a, as: family.kid)
        answerOne(a, attempt)
        XCTAssertEqual(today(TestSupport.lastMinute)?.id, a.id, "10:59 pm is still today")
        XCTAssertEqual(today(TestSupport.nextDayStart)?.id, b.id, "11:00 pm starts the next day")
    }

    func testLockLiftsWhenTheQueueMovesOn() throws {
        answerOne(a, try open(a, as: family.kid))
        XCTAssertTrue(QuizQueue.isLocked(a, in: ctx, now: TestSupport.morning))
        XCTAssertEqual(today(TestSupport.nextMorning)?.id, b.id)
        XCTAssertFalse(QuizQueue.isLocked(b, in: ctx, now: TestSupport.nextMorning))
        XCTAssertTrue(QuizQueue.edit(b, to: draft("B2"), in: ctx, now: TestSupport.nextMorning))
    }

    func testRemovingTodaysQuizBringsUpTheNext() {
        QuizQueue.remove(a, in: ctx, now: TestSupport.morning)
        XCTAssertEqual(today()?.id, b.id)
        XCTAssertEqual(QuizQueue.quizzes(in: ctx).map(\.title), ["B", "C"])
        // Removed, not deleted: old attempts can still name it.
        XCTAssertNotNil(a.removedAt)
    }

    func testRemovingAnotherQuizKeepsToday() {
        QuizQueue.remove(c, in: ctx, now: TestSupport.morning)
        XCTAssertEqual(today()?.id, a.id)
    }

    func testRemovingTheLastQuizWhileItIsTodayWrapsToTheFirst() {
        XCTAssertTrue(QuizQueue.makeToday(c, in: ctx, now: TestSupport.morning))
        QuizQueue.remove(c, in: ctx, now: TestSupport.morning)
        XCTAssertEqual(today()?.id, a.id)
        XCTAssertEqual(family.record?.position, 0)
    }

    func testRemovingTodaysQuizIsRefusedOnceAKidAnswered() throws {
        answerOne(a, try open(a, as: family.kid))
        XCTAssertFalse(QuizQueue.remove(a, in: ctx, now: TestSupport.morning))
        XCTAssertNil(a.removedAt)
        XCTAssertEqual(today()?.id, a.id)
        XCTAssertTrue(QuizQueue.isLocked(a, in: ctx, now: TestSupport.morning))
        // Other quizzes can still be removed.
        XCTAssertTrue(QuizQueue.remove(c, in: ctx, now: TestSupport.morning))
        // Once the queue moves on, the old quiz can go; the kid's answer is
        // kept and still names it.
        XCTAssertEqual(today(TestSupport.nextMorning)?.id, b.id)
        XCTAssertTrue(QuizQueue.remove(a, in: ctx, now: TestSupport.nextMorning))
        XCTAssertEqual(family.fetchAll(QuizAnswer.self).count, 1)
        XCTAssertEqual(family.fetchAll(QuizAttempt.self).first?.quizSetID, a.id)
    }

    func testRemovingEveryQuizEmptiesTheQueue() {
        for quiz in [a!, b!, c!] { QuizQueue.remove(quiz, in: ctx, now: TestSupport.morning) }
        XCTAssertNil(today())
    }

    func testReorderKeepsTodayAndFollowsTheNewOrder() throws {
        QuizQueue.reorder([c, b, a], in: ctx, now: TestSupport.morning)
        XCTAssertEqual(QuizQueue.quizzes(in: ctx).map(\.title), ["C", "B", "A"])
        XCTAssertEqual(today()?.id, a.id, "reordering doesn't change today's quiz")
        XCTAssertEqual(family.record?.position, 2)
        // After a kid plays A (last), the cycle wraps to C.
        answerOne(a, try open(a, as: family.kid))
        XCTAssertEqual(today(TestSupport.nextMorning)?.id, c.id)
    }

    func testReorderAfterAKidAnsweredKeepsTodayAndTheLock() throws {
        answerOne(a, try open(a, as: family.kid))
        QuizQueue.reorder([b, c, a], in: ctx, now: TestSupport.morning)
        XCTAssertEqual(today()?.id, a.id)
        XCTAssertTrue(QuizQueue.isLocked(a, in: ctx, now: TestSupport.morning))
        XCTAssertEqual(family.record?.position, 2, "position follows today's quiz")
        // Tomorrow the cycle continues after A in the new order (wraps to B).
        XCTAssertEqual(today(TestSupport.nextMorning)?.id, b.id)
    }

    func testMovingTodaysQuizToTheFrontMovesItsPosition() {
        QuizQueue.reorder([b, c, a], in: ctx, now: TestSupport.morning)
        XCTAssertEqual(family.record?.position, 2)
        QuizQueue.reorder([a, b, c], in: ctx, now: TestSupport.morning)
        XCTAssertEqual(today()?.id, a.id)
        XCTAssertEqual(family.record?.position, 0)
    }

    func testRecountAfterAKidIsDeleted() throws {
        answerOne(a, try open(a, as: family.kid))
        XCTAssertTrue(family.record?.started == true)
        ctx.delete(family.fetchAll(QuizAnswer.self)[0])
        try ctx.save()
        QuizQueue.recountKidAttempts(in: ctx)
        XCTAssertEqual(family.record?.attemptedByKid, false)
        XCTAssertEqual(family.record?.started, false)
    }

    func testShuffleKeepsEveryQuizAndTodaysQuiz() {
        for seed: UInt64 in 0..<20 {
            QuizQueue.shuffle(in: ctx, seed: seed, now: TestSupport.morning)
            XCTAssertEqual(Set(QuizQueue.quizzes(in: ctx).map(\.title)), ["A", "B", "C"])
            XCTAssertEqual(today()?.id, a.id, "shuffling doesn't change today's quiz")
            let position = QuizQueue.quizzes(in: ctx).firstIndex { $0.id == a.id }
            XCTAssertEqual(family.record.map { Int($0.position) }, position, "position follows today's quiz")
        }
        let orders = Set((0..<20).map { (seed: UInt64) -> [String] in
            QuizQueue.shuffle(in: ctx, seed: seed, now: TestSupport.morning)
            return QuizQueue.quizzes(in: ctx).map(\.title)
        })
        XCTAssertGreaterThan(orders.count, 2)
    }

    func testANewQuizAsksForTheFlagByDefaultAt15Points() {
        let draft = QuizDraft()
        XCTAssertTrue(draft.asksName)
        XCTAssertTrue(draft.asksCapital)
        XCTAssertTrue(draft.asksFlag)
        XCTAssertEqual(draft.flagPoints, 15)
    }

    private func draft(_ title: String) -> QuizDraft {
        var d = QuizDraft(a)
        d.title = title
        return d
    }
}
