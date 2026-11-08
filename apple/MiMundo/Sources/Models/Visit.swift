import Foundation
import SwiftData

/// One day a child played: logged when they pick their profile. At most one
/// per child per game day (10 pm ET to 10 pm ET; see core/src/days.rs).
@Model
final class Visit {
    #Unique<Visit>([\.childID, \.day])

    var childID: UUID
    /// Game day number from the Rust core's `gameDay(unixSeconds:)`.
    var day: Int32
    var firstOpenedAt: Date

    init(childID: UUID, day: Int32, firstOpenedAt: Date = .now) {
        self.childID = childID
        self.day = day
        self.firstOpenedAt = firstOpenedAt
    }
}
