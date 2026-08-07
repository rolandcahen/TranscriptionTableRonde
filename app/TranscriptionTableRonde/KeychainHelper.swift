import Foundation
import Security

/// Enregistre le token Hugging Face dans le trousseau macOS plutôt qu'en
/// clair dans les préférences de l'app (UserDefaults / plist).
enum KeychainHelper {
    private static let service = "com.roland.transcription-table-ronde"
    private static let account = "hf-token"

    static func save(token: String) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // On repart toujours d'un état propre : supprime l'entrée existante
        // avant d'écrire la nouvelle valeur (ou de la laisser supprimée si
        // le token est vide).
        SecItemDelete(baseQuery as CFDictionary)

        guard !token.isEmpty else { return }

        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
