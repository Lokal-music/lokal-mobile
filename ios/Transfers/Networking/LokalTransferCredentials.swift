import Foundation
#if canImport(Security)
import Security
#endif

enum LokalTransferCredentialError: Error { case unavailable, invalidRecord }

/// Decode one atomic Keychain record. Preferences cannot supply a new origin
/// while the record still contains an older desktop's bearer credential.
enum LokalTransferCredentials {
  static func decode(_ data: Data) throws -> LokalTransferAuthorization? {
    guard !data.isEmpty, data.count <= 16 * 1024,
          let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          document["version"] as? Int == 2,
          Set(document.keys).isSubset(of: ["version", "origin", "pairingID", "remoteToken", "apiKey", "desktopId", "desktopUserId"]),
          let origin = document["origin"] as? String,
          let pairingID = document["pairingID"] as? String,
          let token = document["remoteToken"] as? String,
          let apiKey = document["apiKey"] as? String,
          document["desktopUserId"] == nil || document["desktopUserId"] is NSNull || document["desktopUserId"] is String else {
      throw LokalTransferCredentialError.invalidRecord
    }
    // Manually configured remote-control endpoints need not be paired for
    // original-file transfer. They do not create background authorization.
    guard let desktop = document["desktopId"] as? String, !desktop.isEmpty, !token.isEmpty else { return nil }
    return try LokalTransferAuthorization(desktopID: desktop, origin: origin, token: token,
      pairingID: pairingID, apiKey: apiKey, desktopUserID: document["desktopUserId"] as? String)
  }

  #if canImport(Security)
  static func read() throws -> LokalTransferAuthorization? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "flutter_secure_storage_service",
      kSecAttrAccount as String: "konnekted.lokal_remote.secrets.v1",
      kSecAttrSynchronizable as String: false,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw LokalTransferCredentialError.unavailable
    }
    return try decode(data)
  }
  #endif
}
