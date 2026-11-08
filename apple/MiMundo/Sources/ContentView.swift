import MiMundoCore
import SwiftUI

/// Placeholder home screen. Proves the Rust core is linked and callable.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 32) {
            Text("Mi Mundo")
                .font(.system(size: 64, weight: .bold, design: .rounded))

            VStack(spacing: 12) {
                Text("Retake points for a 100-point question")
                    .font(.title3)
                HStack(spacing: 24) {
                    ForEach(1...4, id: \.self) { attempt in
                        VStack {
                            Text("\(pointsForAttempt(basePoints: 100, attempt: UInt32(attempt), usedMultipleChoice: false))")
                                .font(.title.bold())
                            Text("try \(attempt)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

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
