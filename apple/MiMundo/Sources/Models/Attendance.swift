import Foundation
import MiMundoCore
import SwiftData
import SwiftUI

/// Attendance for one child. The rules (what a day is, the 7-day window, the
/// cap at 5, streaks) live in the Rust core; this just feeds it visit days.
enum Attendance {
    static func today(now: Date = .now) -> Int32 {
        gameDay(unixSeconds: Int64(now.timeIntervalSince1970.rounded(.down)))
    }

    /// Records that `child` played today. Safe to call repeatedly: an
    /// existing visit is left alone (so its first-opened time is kept).
    @MainActor
    static func logVisit(for child: Profile, in context: ModelContext, now: Date = .now) {
        guard child.role == .child else { return }
        let childID = child.id
        let day = today(now: now)
        let existing = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.childID == childID && $0.day == day }
        )
        do {
            if try context.fetchCount(existing) > 0 { return }
        } catch {
            // Don't guess: inserting could overwrite today's visit.
            dataLog.error("Couldn't check today's visit: \(error, privacy: .public)")
            return
        }
        context.insert(Visit(childID: childID, day: day, firstOpenedAt: now))
        context.saveOrRollback("log visit")
    }

    static func summary(days: [Int32], now: Date = .now) -> AttendanceSummary {
        attendanceSummary(visitDays: days, today: today(now: now))
    }
}

/// Fetches only one child's visits and hands their attendance summary to
/// `content`.
struct WithAttendance<Content: View>: View {
    @Query private var visits: [Visit]
    private let content: (AttendanceSummary) -> Content

    init(childID: UUID, @ViewBuilder content: @escaping (AttendanceSummary) -> Content) {
        _visits = Query(filter: #Predicate<Visit> { $0.childID == childID })
        self.content = content
    }

    var body: some View {
        content(Attendance.summary(days: visits.map(\.day)))
    }
}

/// Session bookkeeping for the parent stats.
enum Sessions {
    @MainActor
    static func start(for profile: Profile, in context: ModelContext, now: Date = .now) -> UUID {
        let session = Session(profile: profile, day: Attendance.today(now: now), startedAt: now)
        context.insert(session)
        context.saveOrRollback("start session")
        return session.id
    }

    @MainActor
    static func end(_ id: UUID?, in context: ModelContext, now: Date = .now) {
        guard let id else { return }
        let descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.id == id })
        guard let session = try? context.fetch(descriptor).first, session.endedAt == nil else { return }
        session.endedAt = now
        context.saveOrRollback("end session")
    }
}
