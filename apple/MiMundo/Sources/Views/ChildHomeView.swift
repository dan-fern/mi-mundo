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

    private var topBar: some View {
        HStack(spacing: 14) {
            ProfileAvatar(emoji: child.emoji, size: 52)
            Text(child.name).font(.title2.bold()).lineLimit(1)
            WithAttendance(childID: child.id) { summary in
                AttendanceGauge(summary: summary)
                if summary.streak > 1 {
                    // At big text sizes, just the star and the number.
                    Label {
                        Text(typeSize.isAccessibilitySize ? "\(summary.streak)" : "\(summary.streak) days in a row!")
                    } icon: {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }
                    .font(.headline)
                    .accessibilityLabel("\(summary.streak) days in a row")
                }
            }
            TodayQuizButton(profile: child)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
