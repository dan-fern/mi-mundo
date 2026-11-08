import SwiftUI

/// Attendance gauge shown next to a child's name: segments fill up and get
/// "hotter" (blue → red) as attendance approaches the max (5 of the last 7
/// days). A full gauge adds a flame.
struct AttendanceGauge: View {
    let level: Int
    let maxLevel: Int

    /// Cool to hot, one color per segment.
    private static let heat: [Color] = [.blue, .teal, .yellow, .orange, .red]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<maxLevel, id: \.self) { index in
                Capsule()
                    .fill(index < level ? color(for: index) : Color.secondary.opacity(0.2))
                    .frame(width: 14, height: 10 + CGFloat(index) * 5)
            }
            Image(systemName: "flame.fill")
                .font(.title2)
                .foregroundStyle(level >= maxLevel ? Color.red : Color.secondary.opacity(0.25))
                .symbolEffect(.bounce, value: level >= maxLevel)
        }
        .frame(height: 34, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel("Attendance")
        .accessibilityValue("\(level) of \(maxLevel)")
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
