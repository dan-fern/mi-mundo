import CryptoKit
import Foundation

/// Parent PINs: 4 digits, stored as a salted SHA-256 hash. This keeps kids
/// out of parent mode on a family iPad; it is not meant to resist someone
/// with the device and developer tools.
enum PIN {
    static let length = 4

    static func isValid(_ pin: String) -> Bool {
        pin.count == length && pin.allSatisfy(\.isASCII) && pin.allSatisfy(\.isNumber)
    }

    static func set(_ pin: String, on profile: Profile) {
        precondition(isValid(pin))
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        profile.pinSalt = salt
        profile.pinHash = hash(pin, salt: salt)
    }

    static func matches(_ pin: String, for profile: Profile) -> Bool {
        guard let salt = profile.pinSalt, let stored = profile.pinHash else { return false }
        return hash(pin, salt: salt) == stored
    }

    private static func hash(_ pin: String, salt: Data) -> Data {
        Data(SHA256.hash(data: salt + Data(pin.utf8)))
    }
}
