import Foundation
import Security

/// Stores and retrieves the Mi Band AuthKey (16 bytes) from the Keychain.
/// The AuthKey must never touch SwiftData, UserDefaults, or any log output.
struct AuthKeyStore {

    private static let account = "mi-band-auth-key"

    /// Fixed, bundle-id-independent service name. The pairing key has to survive app updates, a
    /// target/bundle-id rename and a reinstall, so it is deliberately NOT derived from
    /// `Bundle.main` at runtime: a renamed bundle would silently stop finding the item and the app
    /// would present itself as unpaired while the real key sat in the keychain under the old name.
    private static let service = "com.myband.authkey"

    /// Where the key used to live (the runtime bundle id). Read once and migrated on first load.
    private static var legacyService: String? {
        let id = Bundle.main.bundleIdentifier ?? "com.myband"
        return id == service ? nil : id
    }

    /// Attributes that identify the item. `synchronizable: false` pins it to this device's local
    /// keychain so an iCloud-synced entry can never shadow or overwrite the pairing key.
    private static func baseQuery(service: String = AuthKeyStore.service) -> [String: Any] {
        [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    // MARK: - Public API

    static func save(_ key: Data) throws {
        guard key.count == 16 else { throw AuthKeyError.invalidLength(key.count) }

        let attributes: [String: Any] = [
            kSecValueData as String:      key,
            // Accessible in background — required for BLE reconnect while app is suspended
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        // Update in place when the item exists. The previous delete-then-add lost the key outright
        // if the add failed, turning a transient keychain error into a re-pairing.
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw AuthKeyError.keychainError(updateStatus) }

        var addQuery = baseQuery()
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw AuthKeyError.keychainError(addStatus) }
    }

    static func load() throws -> Data {
        if let key = try read(service: service) { return key }

        // One-time migration from the old bundle-id-keyed item.
        if let legacyService, let legacy = try read(service: legacyService) {
            try? save(legacy)
            SecItemDelete(baseQuery(service: legacyService) as CFDictionary)
            return legacy
        }
        throw AuthKeyError.notFound
    }

    private static func read(service: String) throws -> Data? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String]  = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:               return result as? Data
        case errSecItemNotFound:          return nil
        case errSecInteractionNotAllowed: throw AuthKeyError.locked
        default:                          throw AuthKeyError.keychainError(status)
        }
    }

    static func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
        if let legacyService {
            SecItemDelete(baseQuery(service: legacyService) as CFDictionary)
        }
    }

    /// Whether a pairing key exists. A *locked* keychain reports `true`: on a background relaunch
    /// before the first unlock after boot the item is present but unreadable, and answering "no
    /// key" there would send an already-paired user back through setup.
    static var isStored: Bool {
        do { _ = try load(); return true }
        catch AuthKeyError.locked { return true }
        catch { return false }
    }

    // MARK: - Hex convenience

    /// Parses a 32-character hex string (e.g. "a1b2c3...") into 16 bytes and saves it.
    static func saveHex(_ hex: String) throws {
        let cleaned = hex.replacingOccurrences(of: " ", with: "").lowercased()
        guard cleaned.count == 32 else { throw AuthKeyError.invalidHex }
        guard let data = Data(hexString: cleaned) else { throw AuthKeyError.invalidHex }
        try save(data)
    }
}

// MARK: - Errors

enum AuthKeyError: LocalizedError {
    case notFound
    case locked
    case invalidLength(Int)
    case invalidHex
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound:               return "AuthKey not found. Set up the band key."
        case .locked:                 return "Keychain is locked. Unlock your iPhone and try again."
        case .invalidLength(let n):   return "AuthKey must be 16 bytes; received \(n)."
        case .invalidHex:             return "Invalid format. Enter 32 hexadecimal characters."
        case .keychainError(let s):   return "Keychain error (OSStatus \(s))."
        }
    }
}

// MARK: - Data+hexString

extension Data {
    init?(hexString: String) {
        let hex = hexString
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
