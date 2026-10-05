import Foundation
import Security

/// Keys we store. Values live only in the macOS Keychain.
enum SecretKey: String, CaseIterable {
    case sarvamAPIKey = "sarvam_api_key"
    case jevAPIKey = "jev_api_key"

    var displayName: String {
        switch self {
        case .sarvamAPIKey: return "Sarvam API Key"
        case .jevAPIKey: return "Jev API Key"
        }
    }

    /// Env var consulted as a development fallback.
    var environmentVariable: String {
        switch self {
        case .sarvamAPIKey: return "SARVAM_API_KEY"
        case .jevAPIKey: return "JEV_API_KEY"
        }
    }
}

/// Keychain-backed secret storage.
///
/// This type deliberately has no logging of any kind — not even redacted — so
/// there is no code path that can put a key into the log buffer.
enum KeychainManager {
    /// Keychain service name. Matches the app's bundle identifier so the keys
    /// are filed under an obvious, self-describing namespace.
    private static let service = "ai.macsurfer.voicemac"

    /// In-memory cache of resolved secrets.
    ///
    /// Every `SecItemCopyMatching` against an item this binary is not yet in
    /// the ACL for raises a "VoiceMac wants to use your confidential
    /// information" password prompt. Without caching, that fired on every
    /// listening session *and* on every SwiftUI redraw of Settings, because
    /// `maskedPreview` reads the key too. The cache makes it at most one
    /// prompt per key per launch.
    ///
    /// Values are held only for the process lifetime and never written
    /// anywhere; `set` and `delete` keep the cache honest.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    private static func cached(_ key: SecretKey) -> String?? {
        cacheLock.withLock { cache[key.rawValue] }
    }

    private static func store(_ value: String?, for key: SecretKey) {
        cacheLock.withLock { cache[key.rawValue] = value }
    }

    static func invalidateCache() {
        cacheLock.withLock { cache.removeAll() }
    }

    /// Resolves every secret once, at a predictable moment.
    ///
    /// Called at launch so any Keychain authorisation prompt appears then,
    /// rather than interrupting the user the instant they press the listen key.
    static func warmUp() {
        for key in SecretKey.allCases { _ = get(key) }
    }

    static func set(_ value: String, for key: SecretKey) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete(key)
            return
        }
        // Cache the value we are about to write, so the read-back that follows
        // never has to touch the Keychain.
        defer { store(trimmed, for: key) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8)
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = Data(trimmed.utf8)
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpected(addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unexpected(status)
        }
    }

    /// Cache first, then Keychain, then environment variable as a development
    /// fallback. Safe to call on every frame.
    static func get(_ key: SecretKey) -> String? {
        if let hit = cached(key) { return hit }

        let resolved = read(key)
        store(resolved, for: key)
        return resolved
    }

    private static func read(_ key: SecretKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let string = String(data: data, encoding: .utf8),
           !string.isEmpty {
            return string
        }

        if let env = ProcessInfo.processInfo.environment[key.environmentVariable],
           !env.isEmpty {
            return env
        }
        return nil
    }

    static func has(_ key: SecretKey) -> Bool { get(key) != nil }

    @discardableResult
    static func delete(_ key: SecretKey) -> Bool {
        store(nil, for: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// Safe to show in the UI: proves a key is present without revealing it.
    static func maskedPreview(_ key: SecretKey) -> String {
        guard let value = get(key) else { return "Not set" }
        let tail = value.suffix(4)
        return "•••••••• \(tail) (\(value.count) chars)"
    }

    enum KeychainError: LocalizedError {
        case unexpected(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpected(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain error \(status): \(message)"
            }
        }
    }
}
