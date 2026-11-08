import Foundation
import SwiftData

extension SchemaV1 {
    /// One day a child played: logged when they pick their profile. At most
    /// one per child per game day (10 pm ET to 10 pm ET; see core/src/days.rs).
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

    /// One stretch of someone using the app, from picking their profile to
    /// switching player or leaving the app. Recorded for parents and kids;
    /// the parent stats (requirements §5.2) are built from these.
    @Model
    final class Session {
        @Attribute(.unique) var id: UUID
        var profileID: UUID
        var roleRaw: String
        /// Game day the session started on.
        var day: Int32
        var startedAt: Date
        /// Nil while the session is still going (or if the app was killed).
        var endedAt: Date?

        init(profile: Profile, day: Int32, startedAt: Date) {
            self.id = UUID()
            self.profileID = profile.id
            self.roleRaw = profile.roleRaw
            self.day = day
            self.startedAt = startedAt
        }
    }
}
