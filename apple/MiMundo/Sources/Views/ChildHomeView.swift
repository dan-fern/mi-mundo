import SwiftData
import SwiftUI

/// A child's home. Placeholder for the explore worldview (next feature);
/// shows the attendance gauge next to their name.
struct ChildHomeView: View {
    let child: Profile
    let onSwitchPlayer: () -> Void

    @Query private var visits: [Visit]

    var body: some View {
        let attendance = Attendance.summary(for: child.id, visits: visits)
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ProfileAvatar(emoji: child.emoji, size: 64)
                Text(child.name).font(.title.bold())
                AttendanceGauge(level: attendance.level, maxLevel: attendance.maxLevel)
                Spacer()
                if attendance.streak > 1 {
                    Label("\(attendance.streak) days in a row!", systemImage: "flame.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
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
