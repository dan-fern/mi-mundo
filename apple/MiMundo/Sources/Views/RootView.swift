import SwiftData
import SwiftUI

/// Decides which screen to show: first-run setup, "who's playing?", or the
/// chosen player's home.
struct RootView: View {
    /// After the app has been in the background this long, ask who's playing
    /// again, so a sibling (or a kid, after a parent) doesn't inherit a session.
    static let askAgainAfter: TimeInterval = 10 * 60

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]
    @State private var activeID: UUID?
    @State private var backgroundedAt: Date?

    private var active: Profile? {
        profiles.first { $0.id == activeID }
    }

    var body: some View {
        Group {
            if !profiles.contains(where: \.isParent) {
                FirstRunView { parent in activeID = parent.id }
            } else if let active, active.isParent {
                ParentHomeView(parent: active, onSwitchPlayer: switchPlayer)
            } else if let active {
                ChildHomeView(child: active, onSwitchPlayer: switchPlayer)
            } else {
                WhoIsPlayingView(profiles: profiles, onChoose: choose)
            }
        }
        .animation(.easeInOut, value: activeID)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = .now
            case .active:
                if let since = backgroundedAt, Date.now.timeIntervalSince(since) >= Self.askAgainAfter {
                    activeID = nil
                } else if let active, !active.isParent {
                    // Still the same child's session: count today too, in case
                    // the iPad stayed on their screen past 10 pm ET.
                    Attendance.logVisit(for: active, in: context)
                }
                backgroundedAt = nil
            default:
                break
            }
        }
    }

    private func choose(_ profile: Profile) {
        if !profile.isParent {
            Attendance.logVisit(for: profile, in: context)
        }
        activeID = profile.id
    }

    private func switchPlayer() {
        activeID = nil
    }
}
