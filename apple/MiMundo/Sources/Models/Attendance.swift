import Foundation
import MiMundoCore
import SwiftData

/// Attendance for one child. The rules (what a day is, the 7-day window, the
/// cap at 5, streaks) live in the Rust core; this just feeds it visit days.
struct AttendanceSummary: Equatable {
    var level: Int
    var maxLevel: Int
    var daysPlayedLast7: Int
    var streak: Int
}

enum Attendance {
    static func today(now: Date = .now) -> Int32 {
        gameDay(unixSeconds: Int64(now.timeIntervalSince1970.rounded(.down)))
    }

    /// Records that `child` played today. Safe to call repeatedly.
    @MainActor
    static func logVisit(for child: Profile, in context: ModelContext, now: Date = .now) {
        guard child.role == .child else { return }
        let childID = child.id
        let day = today(now: now)
        let existing = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.childID == childID && $0.day == day }
        )
        if (try? context.fetchCount(existing)) ?? 0 > 0 { return }
        context.insert(Visit(childID: childID, day: day, firstOpenedAt: now))
        try? context.save()
    }

    static func summary(for childID: UUID, visits: [Visit], now: Date = .now) -> AttendanceSummary {
        let days = visits.filter { $0.childID == childID }.map(\.day)
        let today = today(now: now)
        return AttendanceSummary(
            level: Int(attendanceLevelFor(visitDays: days, today: today)),
            maxLevel: Int(attendanceMax()),
            daysPlayedLast7: Int(daysPlayedLast7(visitDays: days, today: today)),
            streak: Int(dayStreak(visitDays: days, today: today))
        )
    }
}
