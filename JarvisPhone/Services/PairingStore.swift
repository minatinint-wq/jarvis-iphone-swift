import Foundation
import Security
enum PairingStore {
    private static var query: [String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.jarvisxlv.iphone.remote",kSecAttrAccount as String:"session"] }
    static func read() -> String? { var q=query; q[kSecReturnData as String]=true; var item: CFTypeRef?; guard SecItemCopyMatching(q as CFDictionary,&item)==errSecSuccess, let d=item as? Data else { return nil }; return String(data:d,encoding:.utf8) }
    static func remove() { SecItemDelete(query as CFDictionary) }
    static func save(_ value:String) throws { remove(); var q=query; q[kSecValueData as String]=Data(value.utf8); q[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly; guard SecItemAdd(q as CFDictionary,nil)==errSecSuccess else { throw URLError(.cannotCreateFile) } }
}
