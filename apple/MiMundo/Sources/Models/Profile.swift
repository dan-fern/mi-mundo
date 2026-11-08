import Foundation
import SwiftData

enum Role: String, Codable, Sendable {
    case parent
    case child
}

/// A player on this iPad. Parents have a PIN; children don't.
@Model
final class Profile {
    @Attribute(.unique) var id: UUID
    var name: String
    var emoji: String
    var roleRaw: String
    /// Salted SHA-256 of the parent's PIN (see `PIN`). Nil for children.
    var pinSalt: Data?
    var pinHash: Data?
    var createdAt: Date

    init(name: String, emoji: String, role: Role, createdAt: Date = .now) {
        self.id = UUID()
        self.name = name
        self.emoji = emoji
        self.roleRaw = role.rawValue
        self.createdAt = createdAt
    }

    var role: Role {
        Role(rawValue: roleRaw) ?? .child
    }

    var isParent: Bool { role == .parent }
}

extension Profile {
    /// Avatar choices offered when creating a profile.
    static let emojiChoices = ["🦊", "🐼", "🦁", "🐸", "🐙", "🦄", "🐢", "🐧", "🦖", "🐬", "🦉", "🐝"]
}
