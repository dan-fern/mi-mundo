import MiMundoCore
import SwiftUI

/// Attendance gauge shown next to a child's name: segments fill up and get
/// "hotter" as attendance approaches the max (5 of the last 7 days).
/// Heat is shown three ways so it doesn't rely on color alone: segment color
/// (blue → red), segment height, and a pulsing flame when full. Empty
/// segments show as outlines in the color they'll become.
struct AttendanceGauge: View {
    let level: Int
    let maxLevel: Int

    init(level: Int, maxLevel: Int) {
        self.level = level
        self.maxLevel = maxLevel
    }

    init(summary: AttendanceSummary) {
        self.init(level: Int(summary.level), maxLevel: Int(summary.maxLevel))
    }

    /// Cool to hot, one color per segment.
    private static let heat: [Color] = [.blue, .teal, .yellow, .orange, .red]

    private var isFull: Bool { level >= maxLevel }

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(0..<maxLevel, id: \.self) { index in
                let color = color(for: index)
                Capsule()
                    .fill(index < level ? color : color.opacity(0.12))
                    .strokeBorder(color.opacity(index < level ? 0 : 0.6), lineWidth: 1.5)
                    .frame(width: 14, height: 10 + CGFloat(index) * 7)
            }
            Image(systemName: isFull ? "flame.fill" : "flame")
                .font(.title2)
                .foregroundStyle(isFull ? Color.red : Color.secondary.opacity(0.5))
                .symbolEffect(.pulse, isActive: isFull)
        }
        .frame(height: 40, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel("Days played")
        .accessibilityValue(isFull ? "\(level) of \(maxLevel), full!" : "\(level) of \(maxLevel)")
    }

    private func color(for index: Int) -> Color {
        let scaled = maxLevel > 1 ? index * (Self.heat.count - 1) / (maxLevel - 1) : Self.heat.count - 1
        return Self.heat[min(max(scaled, 0), Self.heat.count - 1)]
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        ForEach(0...5, id: \.self) { AttendanceGauge(level: $0, maxLevel: 5) }
    }
    .padding()
}
