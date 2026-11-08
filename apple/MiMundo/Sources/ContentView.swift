import MiMundoCore
import SwiftUI

/// Placeholder home screen. Proves the Rust core is linked and callable.
///
/// Type rule for child-facing screens: text styles only (no fixed sizes),
/// nothing smaller than `.headline`. Caption/footnote are for parent or
/// debug text.
struct ContentView: View {
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 64

    var body: some View {
        VStack(spacing: 32) {
            Text("Mi Mundo")
                .font(.system(size: titleSize, weight: .bold))

            VStack(spacing: 12) {
                Text("Retake points for a 100-point question")
                    .font(.title3)
                HStack(spacing: 24) {
                    ForEach(1...4, id: \.self) { attempt in
                        VStack {
                            Text("\(pointsForAttempt(basePoints: 100, attempt: UInt32(attempt), usedMultipleChoice: false))")
                                .font(.title.bold())
                            Text("try \(attempt)")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Debug info, not child-facing.
            Text("Rust core v\(coreVersion())")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
