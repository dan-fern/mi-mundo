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

/// The current game day, kept up to date for views. Attendance and streaks
/// depend on what day it is, not only on the visits, so without this a
/// screen left open across 11 pm ET (or one the app returns to the next
/// morning) kept showing yesterday's streak.
@MainActor
@Observable
final class GameDayClock {
    private(set) var today: Int32 = Attendance.today()
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init() { schedule() }

    /// Re-reads the clock (call when the app comes back to the front: a
    /// sleeping Task can be late after the iPad was locked).
    func refresh(now: Date = .now) {
        let day = Attendance.today(now: now)
        if day != today { today = day }
        schedule()
    }

    private func schedule() {
        ticker?.cancel()
        let wait = Self.secondsUntilNextDay(from: .now)
        ticker = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait + 1))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Seconds until the game day changes: the first second after `now`
    /// whose game day differs, found by halving (DST makes the length of
    /// a day vary, so it isn't a fixed offset).
    static func secondsUntilNextDay(from now: Date) -> TimeInterval {
        let start = Int64(now.timeIntervalSince1970.rounded(.down))
        let today = gameDay(unixSeconds: start)
        var low: Int64 = 0, high: Int64 = 26 * 3600
        while high - low > 1 {
            let mid = (low + high) / 2
            if gameDay(unixSeconds: start + mid) == today { low = mid } else { high = mid }
        }
        return TimeInterval(high)
    }
}

/// Fetches only one child's visits and hands their attendance summary to
/// `content`, recomputed whenever the visits or the game day change.
struct WithAttendance<Content: View>: View {
    @Query private var visits: [Visit]
    @Environment(GameDayClock.self) private var clock
    private let content: (AttendanceSummary) -> Content

    init(childID: UUID, @ViewBuilder content: @escaping (AttendanceSummary) -> Content) {
        _visits = Query(filter: #Predicate<Visit> { $0.childID == childID })
        self.content = content
    }

    var body: some View {
        content(attendanceSummary(visitDays: visits.map(\.day), today: clock.today))
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
