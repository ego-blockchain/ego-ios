import Foundation

/// People this iPhone hides in the chat. The chat runs peer to peer with no company server,
/// so blocking happens here: their messages stop showing on this phone, and nobody is told.
@MainActor
final class ChatBlocklist: ObservableObject {
    static let shared = ChatBlocklist()
    private static let key = "chat.blocked"

    @Published private(set) var blocked: [String] = UserDefaults.standard.stringArray(forKey: ChatBlocklist.key) ?? []

    func contains(_ address: String) -> Bool { blocked.contains(address) }

    func block(_ address: String) {
        guard !contains(address) else { return }
        blocked.append(address)
        UserDefaults.standard.set(blocked, forKey: Self.key)
    }

    func unblock(_ address: String) {
        blocked.removeAll { $0 == address }
        UserDefaults.standard.set(blocked, forKey: Self.key)
    }
}
