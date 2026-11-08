import SwiftData
import SwiftUI

/// Shown until a parent profile exists: name + avatar, then a PIN twice.
struct FirstRunView: View {
    let onCreated: (Profile) -> Void

    private enum Step: Equatable {
        case details
        case choosePIN
        case confirmPIN(String)
    }

    @Environment(\.modelContext) private var context
    @State private var step = Step.details
    @State private var name = ""
    @State private var emoji = "🦉"

    var body: some View {
        switch step {
        case .details:
            ScrollView {
                VStack(spacing: 32) {
                    VStack(spacing: 8) {
                        Text("Welcome to Mi Mundo")
                            .font(.largeTitle.bold())
                        Text("First, set up a parent account. You'll add the kids next.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    ProfileDetailsForm(name: $name, emoji: $emoji, namePrompt: "Your name")
                    Button {
                        step = .choosePIN
                    } label: {
                        Text("Next").font(.title3.bold()).frame(maxWidth: 320)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(48)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        case .choosePIN:
            PinPadView(
                title: "Choose a PIN",
                subtitle: "4 digits, to keep kids out of parent mode",
                onCancel: { step = .details },
                onComplete: { pin in
                    step = .confirmPIN(pin)
                    return true
                }
            )
            .id("choose")
        case .confirmPIN(let first):
            PinPadView(
                title: "Enter it again",
                subtitle: "Just to be sure",
                onCancel: { step = .choosePIN },
                onComplete: { pin in
                    guard pin == first else { return false }
                    createParent(pin: pin)
                    return true
                }
            )
            .id("confirm")
        }
    }

    private func createParent(pin: String) {
        let parent = Profile(
            name: name.trimmingCharacters(in: .whitespaces),
            emoji: emoji,
            role: .parent
        )
        PIN.set(pin, on: parent)
        context.insert(parent)
        try? context.save()
        onCreated(parent)
    }
}

/// Name field plus an emoji avatar picker, shared by parent and kid setup.
struct ProfileDetailsForm: View {
    @Binding var name: String
    @Binding var emoji: String
    let namePrompt: String

    var body: some View {
        VStack(spacing: 24) {
            ProfileAvatar(emoji: emoji, size: 120)
            TextField(namePrompt, text: $name)
                .font(.title2)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding()
                .background(.background.secondary, in: .rect(cornerRadius: 16))
                .frame(maxWidth: 420)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(72)), count: 6), spacing: 12) {
                ForEach(Profile.emojiChoices, id: \.self) { choice in
                    Button {
                        emoji = choice
                    } label: {
                        Text(choice)
                            .font(.system(size: 40))
                            .frame(width: 68, height: 68)
                            .background(
                                choice == emoji ? Color.accentColor.opacity(0.25) : Color.clear,
                                in: .circle
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Avatar \(choice)")
                    .accessibilityAddTraits(choice == emoji ? .isSelected : [])
                }
            }
        }
    }
}
