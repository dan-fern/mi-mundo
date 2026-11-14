import Foundation
import SwiftData

/// Version 3's quiz models exactly as they shipped (to the family iPad in
/// PR #15's first build). Frozen: never change these. Changes go into the
/// current version's models (SchemaV4, Models/QuizPlay.swift) with a
/// migration stage, so a store written by version 3 still opens.
extension SchemaV3 {
    @Model
    final class QuizAttempt {
        @Attribute(.unique) var id: UUID
        var profileID: UUID
        var roleRaw: String
        var quizSetID: UUID
        var run: Int
        var day: Int32
        var number: Int
        var startedAt: Date
        var finishedAt: Date?

        init(id: UUID, profileID: UUID, roleRaw: String, quizSetID: UUID, run: Int, day: Int32,
             number: Int, startedAt: Date) {
            self.id = id
            self.profileID = profileID
            self.roleRaw = roleRaw
            self.quizSetID = quizSetID
            self.run = run
            self.day = day
            self.number = number
            self.startedAt = startedAt
        }
    }

    @Model
    final class QuizAnswer {
        @Attribute(.unique) var id: UUID
        var attemptID: UUID
        var profileID: UUID
        var countryID: String
        var kindRaw: String
        var chosen: String
        var correctAnswer: String
        var correct: Bool
        var basePoints: Int
        var attemptNumber: Int
        var usedMultipleChoice: Bool
        var pointsAwarded: Int
        var answeredAt: Date

        init(id: UUID, attemptID: UUID, profileID: UUID, countryID: String, kindRaw: String,
             chosen: String, correctAnswer: String, correct: Bool, basePoints: Int,
             attemptNumber: Int, usedMultipleChoice: Bool, pointsAwarded: Int, answeredAt: Date) {
            self.id = id
            self.attemptID = attemptID
            self.profileID = profileID
            self.countryID = countryID
            self.kindRaw = kindRaw
            self.chosen = chosen
            self.correctAnswer = correctAnswer
            self.correct = correct
            self.basePoints = basePoints
            self.attemptNumber = attemptNumber
            self.usedMultipleChoice = usedMultipleChoice
            self.pointsAwarded = pointsAwarded
            self.answeredAt = answeredAt
        }
    }
}
