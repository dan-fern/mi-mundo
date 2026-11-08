import SwiftData
import SwiftUI

/// Launch screen: big tiles, one per player. Kids go straight in; parents
/// enter their PIN first.
struct WhoIsPlayingView: View {
    let profiles: [Profile]
    let onChoose: (Profile) -> Void

    @Query private var visits: [Visit]
    @State private var parentAwaitingPIN: Profile?

    private var ordered: [Profile] {
        profiles.filter { !$0.isParent } + profiles.filter(\.isParent)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                Text("Who's playing?")
                    .font(.largeTitle.bold())
                    .padding(.top, 48)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 24)], spacing: 24) {
                    ForEach(ordered) { profile in
                        Button {
                            if profile.isParent {
                                parentAwaitingPIN = profile
                            } else {
                                onChoose(profile)
                            }
                        } label: {
                            ProfileTile(
                                profile: profile,
                                attendance: profile.isParent
                                    ? nil
                                    : Attendance.summary(for: profile.id, visits: visits)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 32)
            }
            .padding(.bottom, 32)
        }
        .sheet(item: $parentAwaitingPIN) { parent in
            PinPadView(
                title: "Hi, \(parent.name)!",
                subtitle: "Enter your PIN",
                onCancel: { parentAwaitingPIN = nil },
                onComplete: { pin in
                    guard PIN.matches(pin, for: parent) else { return false }
                    parentAwaitingPIN = nil
                    onChoose(parent)
                    return true
                }
            )
        }
    }
}

private struct ProfileTile: View {
    let profile: Profile
    let attendance: AttendanceSummary?

    var body: some View {
        VStack(spacing: 16) {
            ProfileAvatar(emoji: profile.emoji, size: 120)
            HStack(spacing: 8) {
                Text(profile.name)
                    .font(.title.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if profile.isParent {
                    Image(systemName: "lock.fill")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Parent, needs PIN")
                }
            }
            if let attendance {
                AttendanceGauge(level: attendance.level, maxLevel: attendance.maxLevel)
            } else {
                Text("Parent")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 280)
        .background(.background.secondary, in: .rect(cornerRadius: 32))
        .contentShape(.rect(cornerRadius: 32))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
