import Foundation
import Security

enum KeychainError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "Keychain: \(message)"
        }
    }
}

/// Stores the upload token in the login keychain rather than in preferences.
/// It is read once and kept in memory, so macOS asks for access at most once per launch.
@MainActor
enum Keychain {
    private static let service = "io.github.aleksandargosevski.skljoc.upload"
    private static var cache: [String: String?] = [:]

    static func token(for account: String) -> String? {
        if let cached = cache[account] { return cached }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(baseQuery(account).merging([
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]) { $1 } as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let token = (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
            cache[account] = .some(token)
            return token
        case errSecItemNotFound:
            cache[account] = .some(nil)
            return nil
        default:
            // Denied or cancelled: not cached, so the next upload can ask again.
            NSLog("Skljoc: could not read the upload token: \(KeychainError.status(status).localizedDescription)")
            return nil
        }
    }

    /// Updates the existing item, which keeps the access the user already allowed.
    static func setToken(_ token: String?, for account: String) throws {
        let query = baseQuery(account)
        guard let token, !token.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
            cache[account] = .some(nil)
            return
        }
        guard token != cache[account] ?? nil else { return }
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrLabel] = "Škljoc upload token"
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.status(updateStatus)
        }
        cache[account] = .some(token)
    }

    private static func baseQuery(_ account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }
}
