import BackgroundTasks
import CryptoKit
import EgoKit
import Foundation
import Security
import UserNotifications

enum AlertTarget: Equatable {
    case chat(String)
    case chats
    case wallet
}

/// Alerts while the app is closed. iOS wakes the app now and then; it reads the
/// DAO state, the wallet's transactions and the mailbox through a gateway and
/// tells you when something needs you.
/// It never signs anything with the wallet in the background: that key stays
/// behind Face ID. The mailbox is read with a separate alert key the wallet
/// signed for, which can only see that mail is waiting, never open it.
extension AppModel {
    static let refreshTask = "com.egoblockchain.wallet.refresh"
    private static let seenKey = "alerts.seen"
    private static let grantKey = "alerts.grant"
    private static let readerService = "com.egoblockchain.wallet.alerts"
    private static let readerAccount = "reader"
    private static let txSeenMax = 1_000
    private static let txLookBack: Int64 = 3_600
    private static let mailLookBackMs: Int64 = 10 * 60_000

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Asks once for permission to alert. Called where alerts start to matter.
    func askForAlerts() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private var alertsSeen: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(500)), forKey: Self.seenKey) }
    }

    /// Everything that deserves an alert right now, each with a stable id so it alerts once.
    func pendingAlerts(now: Int64 = Int64(Date().timeIntervalSince1970)) async -> [(id: String, title: String, body: String)] {
        let owner = address.isEmpty ? (vault.storedAddress ?? "") : address
        guard !owner.isEmpty else { return [] }
        var out: [(String, String, String)] = []
        for secret in daoSecrets {
            guard let p = try? await perform({ try await $0.daoProposal(secret.id, voter: owner) }).proposal,
                  Dao.revealDue(secret, proposal: p, now: now) else { continue }
            out.append(("reveal/\(secret.id)/\(secret.isCreator)", "Time to reveal your answers",
                        "Voting on \"\(p.title)\" ended. Open Governance in Ego Wallet so your answers count."))
        }
        out += await storageAlerts(owner: owner, now: now)
        return out
    }

    /// Storage alerts while auto-renew is on. Each id names the plan period, so each alerts once:
    /// - in the last 10 days, when the wallet's EGUSD won't cover the renewal;
    /// - once the plan has ended, because only an open, unlocked Ego Wallet can pay the renewal.
    private func storageAlerts(owner: String, now: Int64) async -> [(id: String, title: String, body: String)] {
        guard StorageStore.autoRenewOn(owner),
              let history = try? await perform({ try await $0.history(of: owner, limit: AppModel.historyMax) }) else { return [] }
        let price = try? await egocPriceMicroUsd()
        guard let s = EgoStorage.subscription(in: history, of: owner, egocPriceMicroUsd: price), !s.plan.isFree,
              s.renewsSoon(now: now) || (s.confirmed && s.inGrace(now: now)),
              let have = try? await perform({ try await $0.credits(of: owner).credits }) else { return [] }
        let held = heldCredits(from: owner)
        let spendable = have > held ? have - held : 0
        let short = s.renewalShortfall(credits: spendable) != nil
        let cost = EGUSD.format(s.plan.credits(s.billing))
        let date = Date(timeIntervalSince1970: TimeInterval(s.expiresAt)).formatted(date: .abbreviated, time: .omitted)
        if s.renewsSoon(now: now) {
            guard short else { return [] }
            return [("storage-renew/\(s.expiresAt)", "Not enough EGUSD to renew Storage",
                     "Your \(s.plan.name) plan renews on \(date) for \(cost) EGUSD, and you have \(EGUSD.format(spendable)). Convert some EGOC to EGUSD in Ego Wallet before then.")]
        }
        let keeps = Date(timeIntervalSince1970: TimeInterval(s.expiresAt + EgoStorage.graceSeconds)).formatted(date: .abbreviated, time: .omitted)
        return [("storage-ended/\(s.expiresAt)", "Open Ego Wallet to renew Storage",
                 short
                 ? "Your \(s.plan.name) plan ended. Renewing takes \(cost) EGUSD and you have \(EGUSD.format(spendable)): convert some EGOC to EGUSD, and it renews when you open Ego Wallet. Your files keep their space until \(keeps)."
                 : "Your \(s.plan.name) plan ended. Open Ego Wallet to renew it for \(cost) EGUSD. Your files keep their space until \(keeps).")]
    }

    /// Runs in the background: posts each new alert once.
    func backgroundCheck() async {
        let owner = address.isEmpty ? (vault.storedAddress ?? "") : address
        guard !owner.isEmpty else { return }
        MessengerStore.shared.load(for: owner)
        if let items = try? await perform({ try await $0.history(of: owner, limit: AppModel.historyStep) }) {
            noteTransactions(items, owner: owner)
        }
        await checkMailbox(owner: owner)
        let alerts = await pendingAlerts()
        var seen = alertsSeen
        for alert in alerts where !seen.contains(alert.id) {
            Self.post(id: alert.id, title: alert.title, body: alert.body)
            seen.insert(alert.id)
        }
        alertsSeen = seen
    }

    static func post(id: String, title: String, body: String, target: AlertTarget? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        switch target {
        case .chat(let peer):
            content.userInfo = ["open": "chat", "peer": peer]
            content.threadIdentifier = "chat/\(peer)"
        case .chats:
            content.userInfo = ["open": "chats"]
            content.threadIdentifier = "chats"
        case .wallet:
            content.userInfo = ["open": "wallet"]
            content.threadIdentifier = "wallet"
        case nil:
            break
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: - Transactions

    private static func txSeenKey(_ owner: String) -> String { "alerts.tx.seen.\(owner)" }
    private static func txSinceKey(_ owner: String) -> String { "alerts.tx.since.\(owner)" }

    /// Every payment sent or received, once. The first look only remembers what is
    /// already there, so a new install doesn't alert the whole history.
    func noteTransactions(_ items: [HistoryItem], owner: String) {
        let defaults = UserDefaults.standard
        var seenList = defaults.stringArray(forKey: Self.txSeenKey(owner)) ?? []
        var seen = Set(seenList)
        let newest = items.map(\.timestamp).max() ?? 0
        guard defaults.object(forKey: Self.txSinceKey(owner)) != nil else {
            defaults.set(Array((seenList + items.map(\.hash)).suffix(Self.txSeenMax)), forKey: Self.txSeenKey(owner))
            defaults.set(newest, forKey: Self.txSinceKey(owner))
            return
        }
        let since = Int64(defaults.integer(forKey: Self.txSinceKey(owner)))
        let names = MessengerStore.shared
        for item in items.sorted(by: { $0.timestamp < $1.timestamp })
        where item.timestamp > since - Self.txLookBack && !seen.contains(item.hash) {
            seen.insert(item.hash)
            seenList.append(item.hash)
            guard let direction = item.direction(for: owner), direction != .reward else { continue }
            let amount = Self.amountText(item)
            if direction == .received {
                Self.post(id: "tx/\(item.hash)", title: "Received \(amount)", body: "From \(names.name(for: item.from))", target: .wallet)
            } else {
                Self.post(id: "tx/\(item.hash)", title: "Sent \(amount)", body: "To \(names.name(for: item.to)). Confirmed on the network.", target: .wallet)
            }
        }
        defaults.set(Array(seenList.suffix(Self.txSeenMax)), forKey: Self.txSeenKey(owner))
        defaults.set(max(since, newest), forKey: Self.txSinceKey(owner))
    }

    private static func amountText(_ item: HistoryItem) -> String {
        if item.txType == "credits_pay" {
            let digits = item.memo?.dropFirst("credits_pay:".count).prefix { $0.isNumber } ?? ""
            return "\(EGUSD.format(UInt64(digits) ?? 0)) EGUSD"
        }
        return "\(Amount.format(item.amount)) EGOC"
    }

    // MARK: - Mailbox

    /// Called while unlocked: makes sure the alert key exists and the wallet's
    /// permission for it has more than two months left.
    func renewAlertKey() {
        guard let key else { return }
        let now = Int64(Date().timeIntervalSince1970)
        guard let reader = Self.readerKey(create: true) else { return }
        let readerHex = Hex.encode(Array(reader.publicKey.rawRepresentation))
        if let grant = Self.savedGrant(), grant.owner == key.address, grant.reader == readerHex, !grant.needsRenewal(now: now) { return }
        guard let grant = try? Messenger.ReaderGrant.make(reader: Array(reader.publicKey.rawRepresentation), with: key, now: now),
              let data = try? JSONEncoder().encode(grant) else { return }
        UserDefaults.standard.set(data, forKey: Self.grantKey)
    }

    func forgetAlerts() {
        UserDefaults.standard.removeObject(forKey: Self.grantKey)
        SecItemDelete(Self.readerQuery as CFDictionary)
    }

    private static var readerQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: readerService,
            kSecAttrAccount as String: readerAccount,
        ]
    }

    private static func savedGrant() -> Messenger.ReaderGrant? {
        guard let data = UserDefaults.standard.data(forKey: grantKey) else { return nil }
        return try? JSONDecoder().decode(Messenger.ReaderGrant.self, from: data)
    }

    /// Kept in the keychain without Face ID, so a locked phone can use it after the first unlock.
    private static func readerKey(create: Bool) -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: readerService,
            kSecAttrAccount as String: readerAccount,
            kSecReturnData as String: true,
        ]
        var found: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data,
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        guard create else { return nil }
        let key = Curve25519.Signing.PrivateKey()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: readerService,
            kSecAttrAccount as String: readerAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key.rawRepresentation,
        ]
        SecItemDelete(readerQuery as CFDictionary)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? key : nil
    }

    private static func peekCursorKey(_ owner: String) -> String { "alerts.peek.\(owner)" }

    /// While locked: asks the wallet's mail places whether new messages or contact
    /// requests are waiting. One alert says so; opening the app reads them.
    func checkMailbox(owner: String) async {
        guard let grant = Self.savedGrant(), grant.owner == owner,
              grant.until > Int64(Date().timeIntervalSince1970),
              let reader = Self.readerKey(create: false) else { return }
        let defaults = UserDefaults.standard
        var cursors = (defaults.dictionary(forKey: Self.peekCursorKey(owner)) ?? [:]).compactMapValues { ($0 as? NSNumber)?.int64Value }
        let floor = Int64(Date().timeIntervalSince1970 * 1000) - Self.mailLookBackMs
        let clients = await AccountStore.shared.places(self, for: owner)
        var found: [Messenger.Peeked] = []
        await withTaskGroup(of: (String, [Messenger.Peeked], Int64?).self) { group in
            for client in clients {
                let name = client.gateway.endpoint.absoluteString
                let since = max(cursors[name] ?? floor, floor)
                group.addTask {
                    guard let answer = try? await client.peekMail(grant, reader: reader, since: since) else { return (name, [], nil) }
                    return (name, answer.alerts, answer.latest)
                }
            }
            for await (name, alerts, latest) in group {
                found += alerts
                if let latest { cursors[name] = latest }
            }
        }
        defaults.set(cursors, forKey: Self.peekCursorKey(owner))
        noteMail(found)
    }

    private func noteMail(_ found: [Messenger.Peeked]) {
        var seen = alertsSeen
        let store = MessengerStore.shared
        var chats = 0
        var requests = 0
        for item in found where seen.insert("mail/\(item.id)").inserted && !store.hasOpened(item.id) {
            if item.alert == Messenger.alertRequest { requests += 1 } else { chats += 1 }
        }
        alertsSeen = seen
        if chats > 0 {
            Self.post(id: "chats", title: "New message", body: "Open Ego Wallet to read it.", target: .chats)
        }
        if requests > 0 {
            Self.post(id: "requests", title: "New contact request", body: "Someone wants to connect with you in Chat.", target: .chats)
        }
    }

    func mailAlerted(_ id: String) -> Bool {
        alertsSeen.contains("mail/\(id)")
    }
}

/// Shows alerts while Ego Wallet is open, except for the conversation already on
/// screen, and opens the right page when one is tapped.
final class NotificationRelay: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRelay()
    private var pending: AlertTarget?
    weak var model: AppModel? {
        didSet {
            guard let model, let target = pending else { return }
            pending = nil
            Task { @MainActor in model.alertTarget = target }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        // A push from the server while open: the app reads the message itself and
        // alerts in its own words, so the push stays quiet.
        if info["ego"] != nil {
            await MainActor.run {
                if let model = self.model, model.phase == .ready { Task { await MessengerStore.shared.refresh(model) } }
            }
            return []
        }
        let peer = info["peer"] as? String
        let viewing = await MainActor.run { MessengerStore.shared.viewing }
        if let peer, peer == viewing { return [] }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let target: AlertTarget?
        let pushedFrom = (info["ego"] as? [String: Any])?["from"] as? String
        switch info["open"] as? String ?? pushedFrom.map({ _ in "chat" }) {
        case "chat": target = ((info["peer"] as? String) ?? pushedFrom).map { .chat($0) }
        case "chats": target = .chats
        case "wallet": target = .wallet
        default: target = nil
        }
        guard let target else { return }
        await MainActor.run {
            if let model { model.alertTarget = target } else { pending = target }
        }
    }
}
