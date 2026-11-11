import UserNotifications

/// Turns "Ego Chat: New message" into the sender's name and the message,
/// opened with the preview key Ego Wallet keeps for that contact.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var best: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        best = content
        if let ego = content.userInfo["ego"] as? [String: Any], let from = ego["from"] as? String {
            let kind = ego["kind"] as? String ?? "message"
            if let entry = ChatAlerts.load()[from] {
                content.title = entry.name
                if kind == "message", let preview = ego["preview"] as? String, !preview.isEmpty,
                   let text = ChatAlerts.open(preview, keyHex: entry.key) {
                    content.body = text
                }
            } else if kind == "request" {
                content.title = "Contact request"
                content.body = "Someone wants to add you in Ego Chat."
            }
            content.threadIdentifier = "chat/\(from)"
        }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let best { handler(best) }
    }
}
