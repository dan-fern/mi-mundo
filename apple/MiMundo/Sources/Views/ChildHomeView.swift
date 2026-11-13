import SwiftData
import SwiftUI

/// A child's home: the explore worldview (requirements §3.1), with their
/// name, attendance gauge and streak floating on top.
struct ChildHomeView: View {
    let child: Profile
    let onSwitchPlayer: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var confirmingSwitch = false

    var body: some View {
        ExploreMapView(profileID: child.id) { topBar }
            // A kid opening the app on a new day moves the queue on, even if
            // no parent looks at it.
            .onAppear { QuizQueue.refresh(in: context) }
    }

    /// Everything fits in landscape; on a narrow screen (portrait, big text)
    /// the name and streak words go, keeping the star and number.
    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            barContent(compact: false)
            barContent(compact: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func barContent(compact: Bool) -> some View {
        HStack(spacing: compact ? 10 : 14) {
            ProfileAvatar(emoji: child.emoji, size: compact ? 44 : 52)
            if !compact {
                Text(child.name).font(.title2.bold()).lineLimit(1)
            }
            WithAttendance(childID: child.id) { summary in
                AttendanceGauge(summary: summary)
                if summary.streak > 1 {
                    // When space is short, just the star and the number.
                    Label {
                        Text(compact || typeSize.isAccessibilitySize ? "\(summary.streak)" : "\(summary.streak) days in a row!")
                    } icon: {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }
                    .font(.headline)
                    .accessibilityLabel("\(summary.streak) days in a row")
                }
            }
            TodayQuizButton(profile: child, compact: compact)
            Button {
                confirmingSwitch = true
            } label: {
                Image(systemName: "person.2.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Switch player")
            // Attached to the button so on iPad the popover points at it.
            .confirmationDialog("Switch player?", isPresented: $confirmingSwitch, titleVisibility: .visible) {
                Button("Switch player", action: onSwitchPlayer)
            } message: {
                Text("\(child.name)'s map will stay right where it is.")
            }
        }
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
        // Full size or not at all, so ViewThatFits can tell when it fits.
        .fixedSize(horizontal: !compact, vertical: false)
    }
}
