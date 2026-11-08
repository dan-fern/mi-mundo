import SwiftUI

/// Big-button 4-digit PIN entry. `onComplete` returns whether the PIN was
/// accepted; a rejected PIN shakes and clears.
struct PinPadView: View {
    let title: String
    let subtitle: String
    var onCancel: (() -> Void)?
    let onComplete: (String) -> Bool

    @State private var digits = ""
    @State private var shakes = 0

    var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 8) {
                Text(title).font(.largeTitle.bold())
                Text(subtitle).font(.title3).foregroundStyle(.secondary)
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
                        Button("Cancel", action: onCancel)
                            .font(.headline)
                            .frame(width: 84, height: 84)
                    } else {
                        Color.clear.frame(width: 84, height: 84)
                    }
                    digitButton("0")
                    Button {
                        if !digits.isEmpty { digits.removeLast() }
                    } label: {
                        Image(systemName: "delete.left").font(.title)
                    }
                    .frame(width: 84, height: 84)
                    .accessibilityLabel("Delete")
                }
            }
        }
        .padding(40)
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
                .frame(width: 84, height: 84)
                .background(.background.secondary, in: .circle)
        }
        .buttonStyle(.plain)
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
