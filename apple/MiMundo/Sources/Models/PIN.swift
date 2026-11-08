import CryptoKit
import Foundation
import LocalAuthentication
import SwiftData

/// Parent PINs: 4 digits, stored as a salted SHA-256 hash, with an escalating
/// lockout after wrong guesses. This keeps kids out of parent mode on a
/// family iPad; it isn't meant to resist someone with developer tools.
enum PIN {
    static let length = 4

    enum Outcome: Equatable {
        case accepted
        case wrong
        case locked(until: Date)
    }

    static func isValid(_ pin: String) -> Bool {
        pin.count == length && pin.allSatisfy(\.isASCII) && pin.allSatisfy(\.isNumber)
    }

    /// Sets a new PIN and clears any lockout.
    static func set(_ pin: String, on profile: Profile) {
        precondition(isValid(pin))
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        profile.pinSalt = salt
        profile.pinHash = hash(pin, salt: salt)
        profile.failedPINAttempts = 0
        profile.pinLockedUntil = nil
    }

    /// How long to lock after this many wrong guesses in a row.
    static func lockout(afterFailures failures: Int) -> TimeInterval? {
        switch failures {
        case ..<3: nil
        case 3...4: 30
        case 5...6: 2 * 60
        default: 10 * 60
        }
    }

    /// Checks a PIN, counting wrong guesses and locking out as needed. The
    /// count and lock are saved, so restarting the app doesn't reset them.
    @MainActor
    static func attempt(_ pin: String, for profile: Profile, in context: ModelContext, now: Date = .now) -> Outcome {
        if let until = profile.pinLockedUntil, until > now {
            return .locked(until: until)
        }
        if matches(pin, for: profile) {
            profile.failedPINAttempts = 0
            profile.pinLockedUntil = nil
            context.saveOrRollback("PIN accepted")
            return .accepted
        }
        profile.failedPINAttempts += 1
        profile.pinLockedUntil = lockout(afterFailures: profile.failedPINAttempts).map { now + $0 }
        context.saveOrRollback("PIN rejected")
        return profile.pinLockedUntil.map { .locked(until: $0) } ?? .wrong
    }

    /// "Forgot PIN?": asks for the iPad's own Touch ID / Face ID / passcode.
    /// Returns true if the owner authenticated.
    @MainActor
    static func authenticateDeviceOwner() async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Reset the parent PIN for Mi Mundo"
            )
        } catch {
            return false
        }
    }

    private static func matches(_ pin: String, for profile: Profile) -> Bool {
        guard let salt = profile.pinSalt, let stored = profile.pinHash else { return false }
        return hash(pin, salt: salt) == stored
    }

    private static func hash(_ pin: String, salt: Data) -> Data {
        Data(SHA256.hash(data: salt + Data(pin.utf8)))
    }
}
