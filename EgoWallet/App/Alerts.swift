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
        return out
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
