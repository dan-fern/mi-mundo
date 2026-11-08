import Foundation
import SwiftData

enum Role: String, Codable, Sendable {
    case parent
    case child
}

extension SchemaV1 {
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
        /// Wrong PIN guesses since the last correct one, and the lockout
        /// they triggered (see `PIN.lockout(afterFailures:)`).
        var failedPINAttempts: Int = 0
        var pinLockedUntil: Date?
        /// Set when a parent archives a kid: hidden from "Who's playing?" but
        /// all their data is kept and they can be restored.
        var archivedAt: Date?
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
        var isArchived: Bool { archivedAt != nil }
    }
}

extension Profile {
    /// Avatar choices offered when creating a profile.
    static let emojiChoices = ["🦊", "🐼", "🦁", "🐸", "🐙", "🦄", "🐢", "🐧", "🦖", "🐬", "🦉", "🐝"]
}
