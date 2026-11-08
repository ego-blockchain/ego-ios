import EgoKit
import Foundation

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var desktop: AccountRecord.Content?
    @Published private(set) var desktopVersion: Int64 = 0
    @Published private(set) var loading = false
    @Published var problem: String?

    private var phone = AccountRecord.Content()
    private var phoneVersion: Int64 = 0
    private var phoneDirty = false
    private var owner = ""
    private let desktopURL: URL
    private let phoneURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        desktopURL = support.appendingPathComponent("account-desktop.json")
        phoneURL = support.appendingPathComponent("account-phone.json")
    }

    var contacts: [AccountRecord.Contact] { desktop?.contacts ?? [] }
    var files: [AccountRecord.File] { desktop?.files ?? [] }
    var payments: [HistoryItem] { desktop?.payments ?? [] }

    func load(for key: EgoKey) {
        owner = key.address
        desktop = nil
        desktopVersion = 0
        phone = AccountRecord.Content()
        phoneVersion = 0
        if let saved = read(desktopURL), saved.owner == key.address, let content = try? AccountRecord.open(saved, with: key) {
            desktop = content
            desktopVersion = saved.ver
        }
        if let saved = read(phoneURL), saved.owner == key.address, let content = try? AccountRecord.open(saved, with: key) {
            phone = content
            phoneVersion = saved.ver
        }
    }

    func forget() {
        try? FileManager.default.removeItem(at: desktopURL)
        try? FileManager.default.removeItem(at: phoneURL)
        desktop = nil
        desktopVersion = 0
        phone = AccountRecord.Content()
        phoneVersion = 0
        owner = ""
        problem = nil
    }

    private func read(_ url: URL) -> AccountRecord.Envelope? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AccountRecord.Envelope.self, from: data)
    }

    private func write(_ envelope: AccountRecord.Envelope, to url: URL) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func places(_ app: AppModel, for owner: String) async -> [GatewayClient] {
        var clients = await app.gatewayCandidates()
        let known = await app.directory.known
        let chosen = AccountRecord.places(owner: owner, nodes: known.map(\.announcement.node))
        for entry in known where chosen.contains(entry.announcement.node) {
            guard let gateway = entry.announcement.gateway,
                  !clients.contains(where: { $0.gateway.endpoint == gateway.endpoint }) else { continue }
            clients.append(GatewayClient(gateway: gateway, timeout: 10))
        }
        return clients
    }

    func refresh(_ app: AppModel) async {
        guard let key = app.key, !loading else { return }
        if owner != key.address { load(for: key) }
        loading = true
        defer { loading = false }
        let address = key.address
        let clients = await places(app, for: address)
        var desktops: [AccountRecord.Envelope] = []
        var phones: [AccountRecord.Envelope] = []
        await withTaskGroup(of: (AccountRecord.Envelope?, AccountRecord.Envelope?).self) { group in
            for client in clients {
                group.addTask {
                    let d = try? await client.accountRecord(owner: address, slot: AccountRecord.desktop)
                    let p = try? await client.accountRecord(owner: address, slot: AccountRecord.phone)
                    return (d ?? nil, p ?? nil)
                }
            }
            for await (d, p) in group {
                if let d { desktops.append(d) }
                if let p { phones.append(p) }
            }
        }
        guard app.key?.address == address else { return }
        if let newest = AccountRecord.newest(desktops, owner: address, slot: AccountRecord.desktop), newest.ver > desktopVersion {
            do {
                desktop = try AccountRecord.open(newest, with: key)
                desktopVersion = newest.ver
                write(newest, to: desktopURL)
                problem = nil
            } catch {
                problem = "Your Ego Desktop's record couldn't be opened with this wallet."
            }
        }
        if let newest = AccountRecord.newest(phones, owner: address, slot: AccountRecord.phone), newest.ver > phoneVersion,
           let content = try? AccountRecord.open(newest, with: key) {
            let known = Set(phone.sent.map(\.id))
            phone.sent = (phone.sent + content.sent.filter { !known.contains($0.id) }).sorted { $0.ts > $1.ts }
            phone.sent = Array(phone.sent.prefix(AccountRecord.maxSent))
            phoneVersion = newest.ver
            phoneDirty = phoneDirty || phone.sent.count != content.sent.count
        }
        if desktop == nil && desktops.isEmpty && clients.isEmpty {
            problem = "No Ego Desktop can be reached right now."
        }
        if phoneDirty { await publishPhone(app, key: key) }
    }

    private func publishPhone(_ app: AppModel, key: EgoKey) async {
        let ver = max(Int64(Date().timeIntervalSince1970 * 1000), phoneVersion + 1)
        guard let envelope = try? AccountRecord.seal(phone, with: key, slot: AccountRecord.phone, ver: ver) else { return }
        phoneVersion = ver
        write(envelope, to: phoneURL)
        let clients = await places(app, for: key.address)
        var stored = 0
        await withTaskGroup(of: Bool.self) { group in
            for client in clients {
                group.addTask { (try? await client.putAccountRecord(envelope)) != nil }
            }
            for await ok in group where ok { stored += 1 }
        }
        phoneDirty = stored == 0
    }

    func send(_ file: AccountRecord.File, to contact: AccountRecord.Contact, app: AppModel) async throws {
        guard let key = app.key else { throw WalletError.locked }
        let ts = Int64(Date().timeIntervalSince1970)
        let link = file.shareLink(from: key.address)
        let message = try AccountRecord.chatMessage(from: key.address, to: contact.address, ts: ts, type: "file_bundle",
                                                    text: link, sharedKeyHex: contact.sharedKeyHex)
        let delivery = try AccountRecord.delivery(of: message.bundle, to: contact, ts: ts, with: key)
        try await app.perform { try await $0.deliver(delivery) }
        phone.sent.insert(AccountRecord.Sent(id: message.id, to: contact.address, content: link, messageType: "file_bundle", ts: ts), at: 0)
        phone.sent = Array(phone.sent.prefix(AccountRecord.maxSent))
        phoneDirty = true
        await publishPhone(app, key: key)
    }

    func sent(to contact: String) -> [AccountRecord.Sent] {
        phone.sent.filter { $0.to == contact }
    }
}
