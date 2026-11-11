import EgoKit
import Foundation
import UIKit

/// Chat alerts while Ego Wallet is closed, through rpc.egoblockchain.com and
/// Apple's push service (services/oracle/src/push.rs in ego-blockchain-).
///
/// This iPhone registers its push token for its wallet, signed by the wallet.
/// After each message you send, your app asks the server, signed the same way,
/// to alert the other person; the alert carries an encrypted preview only the
/// two of you can open (see ChatAlerts).
@MainActor
final class PushRelay {
    static let shared = PushRelay()

    static let server = URL(string: "https://rpc.egoblockchain.com")!
    static let registerDomain = "ego/push-register/v1"
    static let notifyDomain = "ego/push-notify/v1"
    /// Registered again at least this often, so the server keeps the phone.
    static let refreshEvery: TimeInterval = 3 * 86_400

    #if DEBUG
    static let env = "sandbox"
    #else
    static let env = "production"
    #endif

    private let defaults = UserDefaults.standard
    private var registering = false

    /// The token Apple gave this iPhone, in hex.
    var token: String? {
        get { defaults.string(forKey: "push.token") }
        set { defaults.set(newValue, forKey: "push.token") }
    }

    /// Asks Apple for a token; it arrives in PushDelegate.
    func start() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    static func registerBytes(owner: String, token: String, env: String, ts: Int64, muted: [String]) -> [UInt8] {
        Array("\(registerDomain)\n\(owner)\n\(token)\n\(env)\n\(ts)\n\(muted.joined(separator: ","))".utf8)
    }

    static func notifyBytes(from: String, to: String, id: String, kind: String, ts: Int64, preview: String) -> [UInt8] {
        Array("\(notifyDomain)\n\(from)\n\(to)\n\(id)\n\(kind)\n\(ts)\n\(preview)".utf8)
    }

    /// Registers this iPhone for its wallet's chat alerts, with blocked senders
    /// muted. Skipped when nothing changed and it was done lately.
    func register(_ app: AppModel) async {
        guard let key = app.key, let token, !registering else { return }
        let muted = MessengerStore.shared.blockedAddresses.sorted()
        let state = "\(key.address)|\(token)|\(Self.env)|\(muted.joined(separator: ","))"
        let last = defaults.double(forKey: "push.registeredAt")
        if defaults.string(forKey: "push.registered") == state, Date().timeIntervalSince1970 - last < Self.refreshEvery { return }
        registering = true
        defer { registering = false }
        let ts = Int64(Date().timeIntervalSince1970)
        guard let sig = try? key.sign(Self.registerBytes(owner: key.address, token: token, env: Self.env, ts: ts, muted: muted)) else { return }
        let body: [String: Any] = [
            "owner": key.address, "token": token, "env": Self.env, "muted": muted, "ts": ts,
            "pubkey": Hex.encode(key.publicKey), "sig": Hex.encode(sig),
        ]
        if await post("push/register", body) {
            defaults.set(state, forKey: "push.registered")
            defaults.set(Date().timeIntervalSince1970, forKey: "push.registeredAt")
        }
    }

    /// Stops alerts on this iPhone for `key`'s wallet, as when the wallet is removed.
    func unregister(_ key: EgoKey) async {
        defaults.removeObject(forKey: "push.registered")
        guard let token else { return }
        let ts = Int64(Date().timeIntervalSince1970)
        guard let sig = try? key.sign(Self.registerBytes(owner: key.address, token: token, env: "off", ts: ts, muted: [])) else { return }
        _ = await post("push/register", [
            "owner": key.address, "token": token, "env": "off", "muted": [String](), "ts": ts,
            "pubkey": Hex.encode(key.publicKey), "sig": Hex.encode(sig),
        ])
    }

    /// Asks the server to alert `to` about a message you just sent them.
    func notify(_ key: EgoKey, to: String, id: String, kind: String = "message", preview: String = "") async {
        let ts = Int64(Date().timeIntervalSince1970)
        guard let sig = try? key.sign(Self.notifyBytes(from: key.address, to: to, id: id, kind: kind, ts: ts, preview: preview)) else { return }
        let body: [String: Any] = [
            "from": key.address, "to": to, "id": id, "kind": kind, "preview": preview, "ts": ts,
            "pubkey": Hex.encode(key.publicKey), "sig": Hex.encode(sig),
        ]
        _ = await post("push/notify", body)
    }

    private func post(_ path: String, _ body: [String: Any]) async -> Bool {
        var request = URLRequest(url: Self.server.appendingPathComponent(path), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

/// Receives the push token from iOS.
final class PushDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in PushRelay.shared.token = hex }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
}
