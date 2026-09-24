import Foundation

/// A short, stable fingerprint of some text — the same on every launch, unlike
/// `hashValue` — for telling whether what a summary was written from changed.
enum Fingerprint {
    static func of(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325  // FNV-1a
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
