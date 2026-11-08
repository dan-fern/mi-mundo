import SwiftData
import SwiftUI

/// Launch screen: big tiles, one per player. Kids go straight in; parents
/// enter their PIN first.
struct WhoIsPlayingView: View {
    /// Active (non-archived) profiles.
    let profiles: [Profile]
    let onChoose: (Profile) -> Void

    @State private var parentAwaitingPIN: Profile?

    private var kids: [Profile] { profiles.filter { !$0.isParent } }
    private var ordered: [Profile] { kids + profiles.filter(\.isParent) }

    /// Up to 4 equal columns, centered, so a few tiles don't sit lopsided.
    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 200, maximum: 300), spacing: 24),
            count: max(1, min(ordered.count, 4))
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                Text("Who's playing?")
                    .font(.largeTitle.bold())
                    .padding(.top, 48)

                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(ordered) { profile in
                        Button {
                            if profile.isParent {
                                parentAwaitingPIN = profile
                            } else {
                                onChoose(profile)
                            }
                        } label: {
                            ProfileTile(profile: profile)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: 1300)

                if kids.isEmpty {
                    Text("Ask a grown-up to add you!")
                        .font(.title2.bold())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 32)
        }
        .sheet(item: $parentAwaitingPIN) { parent in
            ParentUnlockView(
                parent: parent,
                onCancel: { parentAwaitingPIN = nil },
                onUnlocked: {
                    parentAwaitingPIN = nil
                    onChoose(parent)
                }
            )
        }
    }
}

private struct ProfileTile: View {
    let profile: Profile

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
                        .accessibilityHidden(true)
                }
            }
            if profile.isParent {
                Text("Grown-up")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                WithAttendance(childID: profile.id) { summary in
                    AttendanceGauge(summary: summary)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 280)
        .background(.background.secondary, in: .rect(cornerRadius: 32))
        .contentShape(.rect(cornerRadius: 32))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(profile.isParent ? "\(profile.name), grown-up, needs PIN" : profile.name)
        .accessibilityAddTraits(.isButton)
    }
}

/// The parent's PIN sheet, with lockout after wrong guesses and a
/// "Forgot PIN?" path that uses the iPad's own Touch ID / passcode to set a
/// new PIN.
private struct ParentUnlockView: View {
    let parent: Profile
    let onCancel: () -> Void
    let onUnlocked: () -> Void

    private enum Step: Equatable {
        case enterPIN
        case chooseNewPIN
        case confirmNewPIN(String)
    }

    @Environment(\.modelContext) private var context
    @State private var step = Step.enterPIN

    var body: some View {
        switch step {
        case .enterPIN:
            PinPadView(
                title: "Hi, \(parent.name)!",
                subtitle: "Enter your PIN",
                lockedUntil: parent.pinLockedUntil,
                onCancel: onCancel,
                onForgot: forgotPIN,
                onComplete: { pin in
                    switch PIN.attempt(pin, for: parent, in: context) {
                    case .accepted:
                        onUnlocked()
                        return true
                    case .wrong, .locked:
                        return false
                    }
                }
            )
            .id("enter")
        case .chooseNewPIN:
            PinPadView(
                title: "Choose a new PIN",
                subtitle: "4 digits",
                onCancel: { step = .enterPIN },
                onComplete: { pin in
                    step = .confirmNewPIN(pin)
                    return true
                }
            )
            .id("choose")
        case .confirmNewPIN(let first):
            PinPadView(
                title: "Enter it again",
                subtitle: "Just to be sure",
                onCancel: { step = .chooseNewPIN },
                onComplete: { pin in
                    guard pin == first else { return false }
                    PIN.set(pin, on: parent)
                    guard context.saveOrRollback("reset PIN") else { return false }
                    onUnlocked()
                    return true
                }
            )
            .id("confirm")
        }
    }

    private func forgotPIN() {
        Task {
            if await PIN.authenticateDeviceOwner() {
                step = .chooseNewPIN
            }
        }
    }
}
