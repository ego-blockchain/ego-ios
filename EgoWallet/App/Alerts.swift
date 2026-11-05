import BackgroundTasks
import EgoKit
import Foundation
import UserNotifications

/// Alerts while the app is closed. iOS wakes the app now and then; it reads the
/// DAO state through a gateway and tells you when something needs you.
/// It never signs anything in the background: the key stays behind Face ID, so a
/// reveal goes out when you open the app.
extension AppModel {
    static let refreshTask = "com.egoblockchain.wallet.refresh"
    private static let seenKey = "alerts.seen"

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
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
        let alerts = await pendingAlerts()
        var seen = alertsSeen
        for alert in alerts where !seen.contains(alert.id) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
            seen.insert(alert.id)
        }
        alertsSeen = seen
    }
}
