import Foundation
import Security

struct PairingStore {
    var service = "local.ecobee.mac.homekit.v1"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "homekit-pairing"]
    }
    func load() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data else { throw KeychainFailure(code) }
        return data
    }
    func save(_ data: Data) throws {
        let code = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if code == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            attributes[kSecAttrLabel as String] = "Ecobee Local — HomeKit pairing"
            let result = SecItemAdd(attributes as CFDictionary, nil)
            guard result == errSecSuccess else { throw KeychainFailure(result) }
        } else if code != errSecSuccess { throw KeychainFailure(code) }
    }
    func delete() throws {
        let code = SecItemDelete(query as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw KeychainFailure(code) }
    }
}
struct KeychainFailure: LocalizedError {
    let code: OSStatus
    init(_ code: OSStatus) { self.code = code }
    var errorDescription: String? { "macOS Keychain could not read or save the pairing (\(code)). Unlock the login keychain and retry. Keep this app open if you just paired." }
}
