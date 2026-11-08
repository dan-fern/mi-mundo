import SwiftUI

/// Big-button 4-digit PIN entry. `onComplete` returns whether the PIN was
/// accepted; a rejected PIN shakes, buzzes and clears. While `lockedUntil` is
/// in the future the keys are disabled and a countdown is shown.
struct PinPadView: View {
    let title: String
    let subtitle: String
    var lockedUntil: Date?
    var onCancel: (() -> Void)?
    var onForgot: (() -> Void)?
    let onComplete: (String) -> Bool

    private static let keySize: CGFloat = 84

    @State private var digits = ""
    @State private var shakes = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let remaining = lockedUntil.map { $0.timeIntervalSince(timeline.date) } ?? 0
            let locked = remaining > 0
            VStack(spacing: 32) {
                VStack(spacing: 8) {
                    Text(title).font(.largeTitle.bold())
                    Text(locked ? "Too many tries. Try again in \(Self.format(remaining))." : subtitle)
                        .font(.title3)
                        .foregroundStyle(locked ? Color.orange : Color.secondary)
                        .monospacedDigit()
                }

                HStack(spacing: 20) {
                    ForEach(0..<PIN.length, id: \.self) { index in
                        Circle()
                            .fill(index < digits.count ? Color.primary : Color.clear)
                            .stroke(Color.primary, lineWidth: 2)
                            .frame(width: 22, height: 22)
                    }
                }
                .modifier(Shake(amount: CGFloat(shakes)))
                .animation(.default, value: shakes)
                .sensoryFeedback(.error, trigger: shakes)
                .accessibilityElement()
                .accessibilityLabel("\(digits.count) of \(PIN.length) digits entered")

                Grid(horizontalSpacing: 20, verticalSpacing: 20) {
                    ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]], id: \.self) { row in
                        GridRow {
                            ForEach(row, id: \.self) { key in digitButton(key) }
                        }
                    }
                    GridRow {
                        if let onCancel {
                            Button(action: onCancel) {
                                Text("Cancel")
                                    .font(.headline)
                                    .frame(width: Self.keySize, height: Self.keySize)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                        } else {
                            Color.clear.frame(width: Self.keySize, height: Self.keySize)
                        }
                        digitButton("0")
                        Button {
                            if !digits.isEmpty { digits.removeLast() }
                        } label: {
                            Image(systemName: "delete.left")
                                .font(.title)
                                .frame(width: Self.keySize, height: Self.keySize)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Delete")
                    }
                }
                .disabled(locked)
                .opacity(locked ? 0.4 : 1)

                if let onForgot {
                    Button("Forgot PIN?", action: onForgot)
                        .font(.headline)
                        .frame(minHeight: 44)
                }
            }
            .padding(40)
        }
        // A lockout starting (or a new one) discards any half-entered PIN.
        .onChange(of: lockedUntil) { digits = "" }
    }

    private func digitButton(_ key: String) -> some View {
        Button {
            guard digits.count < PIN.length else { return }
            digits.append(key)
            if digits.count == PIN.length {
                let entered = digits
                if !onComplete(entered) {
                    shakes += 1
                    digits = ""
                }
            }
        } label: {
            Text(key)
                .font(.largeTitle.weight(.semibold))
                .frame(width: Self.keySize, height: Self.keySize)
                .background(.background.secondary, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return total >= 60 ? String(format: "%d:%02d", total / 60, total % 60) : "\(total) s"
    }
}

/// Horizontal shake for a wrong PIN.
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 12 * sin(amount * .pi * 4), y: 0))
    }
}
