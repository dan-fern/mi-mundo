import SwiftData
import SwiftUI

/// A child's home. Placeholder for the explore worldview (next feature);
/// shows the attendance gauge next to their name.
struct ChildHomeView: View {
    let child: Profile
    let onSwitchPlayer: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ProfileAvatar(emoji: child.emoji, size: 64)
                Text(child.name).font(.title.bold())
                WithAttendance(childID: child.id) { summary in
                    AttendanceGauge(summary: summary)
                    Spacer()
                    if summary.streak > 1 {
                        Label {
                            Text("\(summary.streak) days in a row!")
                        } icon: {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                        }
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.background.secondary, in: .capsule)
                    }
                }
                Button(action: onSwitchPlayer) {
                    Label("Switch player", systemImage: "person.2.fill")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
            }
            .padding(24)

            Spacer()
            VStack(spacing: 16) {
                Text("🌍").font(.system(size: 160))
                Text("Your world map is coming soon!")
                    .font(.title.bold())
            }
            Spacer()
        }
    }
}
