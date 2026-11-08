import SwiftUI

struct ProfileAvatar: View {
    let emoji: String
    let size: CGFloat

    var body: some View {
        Text(emoji)
            .font(.system(size: size * 0.6))
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.15), in: .circle)
            .accessibilityHidden(true)
    }
}
