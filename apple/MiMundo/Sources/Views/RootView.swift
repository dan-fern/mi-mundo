import SwiftData
import SwiftUI

/// Decides which screen to show: first-run setup, "who's playing?", or the
/// chosen player's home. Also records sessions and attendance.
struct RootView: View {
    /// A kid's session survives this long in the background, then the app
    /// asks who's playing again so a sibling doesn't inherit it. Parent
    /// sessions end as soon as the app leaves the screen.
    static let kidSessionGrace: TimeInterval = 10 * 60

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]
    @State private var activeID: UUID?
    @State private var sessionID: UUID?
    @State private var backgroundedAt: Date?

    private var active: Profile? {
        profiles.first { $0.id == activeID }
    }

    var body: some View {
        Group {
            if !profiles.contains(where: \.isParent) {
                FirstRunView { parent in begin(parent) }
            } else if let active, active.isParent {
                ParentHomeView(parent: active, onSwitchPlayer: switchPlayer)
            } else if let active {
                ChildHomeView(child: active, onSwitchPlayer: switchPlayer)
            } else {
                WhoIsPlayingView(
                    profiles: profiles.filter { !$0.isArchived },
                    onChoose: begin
                )
            }
        }
        .animation(.easeInOut, value: activeID)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Each trip away from the app ends the session record.
                Sessions.end(sessionID, in: context)
                sessionID = nil
                if active?.isParent == true {
                    activeID = nil // parent mode locks immediately
                } else {
                    backgroundedAt = .now
                }
            case .active:
                if let since = backgroundedAt, Date.now.timeIntervalSince(since) >= Self.kidSessionGrace {
                    activeID = nil
                } else if let active, sessionID == nil {
                    // Same player coming back: new session, and count today
                    // too in case a new game day started (10 pm ET).
                    resume(active)
                }
                backgroundedAt = nil
            default:
                break
            }
        }
    }

    private func begin(_ profile: Profile) {
        Sessions.end(sessionID, in: context)
        activeID = profile.id
        resume(profile)
    }

    private func resume(_ profile: Profile) {
        if !profile.isParent {
            Attendance.logVisit(for: profile, in: context)
        }
        sessionID = Sessions.start(for: profile, in: context)
    }

    private func switchPlayer() {
        Sessions.end(sessionID, in: context)
        sessionID = nil
        activeID = nil
    }
}
