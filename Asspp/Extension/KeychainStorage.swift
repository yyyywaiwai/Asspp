import Foundation
import Security

final class KeychainStorage: PersistProvider {
    private let query: [String: Any]

    init(service: String, synchronizable: Bool = true) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        #if os(macOS)
            // Unsigned/ad-hoc releases have no access group for the Data Protection keychain.
            // Omit both accessibility and synchronization attributes to use the login keychain.
            if Self.hasKeychainAccessGroup {
                query[kSecUseDataProtectionKeychain as String] = true
                query[kSecAttrSynchronizable as String] = synchronizable
            }
        #else
            query[kSecAttrSynchronizable as String] = synchronizable
        #endif
        self.query = query
    }

    func data(forKey key: String) throws -> Data? {
        var query = query
        query[kSecAttrAccount as String] = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw error(errSecDecode) }
        return data
    }

    func set(_ data: Data?, forKey key: String) throws {
        var query = query
        query[kSecAttrAccount as String] = key
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
            return
        }
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            // The login keychain does not accept kSecAttrAccessible.
            #if os(iOS)
                query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            #elseif os(macOS)
                if query[kSecUseDataProtectionKeychain as String] as? Bool == true {
                    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                }
            #endif
            try check(SecItemAdd(query as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw error(status) }
    }

    private func error(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error (\(status))",
        ])
    }

    #if os(macOS)
        private static var hasKeychainAccessGroup: Bool {
            var code: SecCode?
            var staticCode: SecStaticCode?
            var information: CFDictionary?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
                  SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
                  SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                  let info = information as? [String: Any],
                  info[kSecCodeInfoTeamIdentifier as String] as? String != nil,
                  let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
            else { return false }
            return !(entitlements["keychain-access-groups"] as? [String] ?? []).isEmpty
                || entitlements["com.apple.application-identifier"] as? String != nil
        }
    #endif
}
