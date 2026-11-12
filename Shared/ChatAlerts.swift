import CryptoKit
import Foundation

/// Chat alerts, shared by Ego Wallet and its notification extension.
///
/// A sender's app puts a short preview of the message in the alert, encrypted
/// with a key made from the two contacts' shared chat key, so the push server
/// and Apple carry it without being able to read it. The extension opens it
/// with the preview keys Ego Wallet leaves in the app group: names and preview
/// keys only, never the wallet key or the chat keys themselves.
enum ChatAlerts {
    static let appGroup = "group.com.egoblockchain.wallet"
    static let previewDomain = "ego/push-preview/v1"
    static let previewChars = 100

    struct Entry: Codable, Equatable {
        var name: String
        /// Hex of the preview key for this contact.
        var key: String
    }

    private static var bookURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("chat-alerts.json")
    }

    static func hexBytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of the domain and the shared chat key: what both contacts' apps compute.
    static func previewKeyHex(sharedKeyHex: String) -> String? {
        guard let shared = hexBytes(sharedKeyHex), shared.count == 32 else { return nil }
        return hex(SHA256.hash(data: Data(previewDomain.utf8) + Data(shared)))
    }

    /// AES-GCM, nonce + ciphertext + tag, in base64.
    static func seal(_ text: String, sharedKeyHex: String) -> String? {
        guard let keyHex = previewKeyHex(sharedKeyHex: sharedKeyHex), let key = hexBytes(keyHex) else { return nil }
        let short = text.count > previewChars ? String(text.prefix(previewChars)) + "…" : text
        return (try? AES.GCM.seal(Data(short.utf8), using: SymmetricKey(data: key)))?.combined?.base64EncodedString()
    }

    static func open(_ preview: String, keyHex: String) -> String? {
        guard let key = hexBytes(keyHex), key.count == 32, let data = Data(base64Encoded: preview),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    static func load() -> [String: Entry] {
        guard let url = bookURL, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    /// Readable after the first unlock since the iPhone started, so alerts work while it's locked.
    static func save(_ book: [String: Entry]) {
        guard let url = bookURL, let data = try? JSONEncoder().encode(book) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func clear() {
        guard let url = bookURL else { return }
        try? FileManager.default.removeItem(at: url)
        UserDefaults(suiteName: appGroup)?.removeObject(forKey: pushedKey)
    }

    // MARK: Payments

    private static let pushedKey = "pushed.tx"

    /// A payment the server already alerted, so the app doesn't alert it again.
    static func notePushed(_ hash: String) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        let list = (defaults.stringArray(forKey: pushedKey) ?? []) + [hash.lowercased()]
        defaults.set(Array(list.suffix(300)), forKey: pushedKey)
    }

    static func wasPushed(_ hash: String) -> Bool {
        UserDefaults(suiteName: appGroup)?.stringArray(forKey: pushedKey)?.contains(hash.lowercased()) ?? false
    }
}
