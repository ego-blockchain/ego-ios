import EgoKit
import Foundation
import UIKit

struct ThreadMessage: Codable, Identifiable, Equatable {
    let id: String
    let from: String
    let to: String
    let ts: Int64
    var type: String
    var text: String
    var replyTo: String?
    var reactions: [String: String] = [:]
    var editedAt: Int64?
    var delivered = false
    var read = false

    func mine(_ me: String) -> Bool { from == me }

    var link: EgoShareLink? {
        type == "file_bundle" ? try? EgoShareLink(parsing: text) : nil
    }

    var preview: String {
        switch type {
        case "file_bundle": return "📎 " + (link?.name ?? "File")
        case "decrypt_key": return "🔑 File key"
        default: return text
        }
    }
}

struct PhoneContact: Codable, Identifiable, Equatable {
    var address: String
    var name: String
    var ed25519: String
    var sharedKeyHex: String
    var status: String
    var token: String
    var addedAt: Int64
    var lastRequestAt: Int64

    var id: String { address }

    var contact: AccountRecord.Contact {
        AccountRecord.Contact(address: address, name: name, ed25519: ed25519, sharedKeyHex: sharedKeyHex)
    }
}

struct AIMessage: Codable, Identifiable, Equatable {
    let id: String
    let fromMe: Bool
    let text: String
    let ts: Int64
}

private struct SavedMessenger: Codable {
    var owner: String
    var threads: [String: [ThreadMessage]] = [:]
    var ai: [AIMessage] = []
    var lastRead: [String: Int64] = [:]
    var cursors: [String: Int64] = [:]
    var seen: [String] = []
    var phoneContacts: [PhoneContact] = []
    var avatars: [String: String] = [:]
    var myAvatar = ""
    var myToken = ""
    var myName = ""
    var historyAskedAt: Int64 = 0

    init(owner: String) { self.owner = owner }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decode(String.self, forKey: .owner)
        threads = try c.decodeIfPresent([String: [ThreadMessage]].self, forKey: .threads) ?? [:]
        ai = try c.decodeIfPresent([AIMessage].self, forKey: .ai) ?? []
        lastRead = try c.decodeIfPresent([String: Int64].self, forKey: .lastRead) ?? [:]
        cursors = try c.decodeIfPresent([String: Int64].self, forKey: .cursors) ?? [:]
        seen = try c.decodeIfPresent([String].self, forKey: .seen) ?? []
        phoneContacts = try c.decodeIfPresent([PhoneContact].self, forKey: .phoneContacts) ?? []
        avatars = try c.decodeIfPresent([String: String].self, forKey: .avatars) ?? [:]
        myAvatar = try c.decodeIfPresent(String.self, forKey: .myAvatar) ?? ""
        myToken = try c.decodeIfPresent(String.self, forKey: .myToken) ?? ""
        myName = try c.decodeIfPresent(String.self, forKey: .myName) ?? ""
        historyAskedAt = try c.decodeIfPresent(Int64.self, forKey: .historyAskedAt) ?? 0
    }
}

@MainActor
final class MessengerStore: ObservableObject {
    static let shared = MessengerStore()

    @Published private(set) var threads: [String: [ThreadMessage]] = [:]
    @Published private(set) var ai: [AIMessage] = []
    @Published private(set) var lastRead: [String: Int64] = [:]
    @Published private(set) var phoneContacts: [PhoneContact] = []
    @Published private(set) var avatars: [String: String] = [:]
    @Published private(set) var myAvatar = ""
    @Published private(set) var myName = ""
    @Published private(set) var thinking = false
    @Published private(set) var sending = false
    @Published private(set) var refreshing = false
    @Published private(set) var historyAskedAt: Int64 = 0
    @Published var problem: String?
    @Published var notice: String?

    private var cursors: [String: Int64] = [:]
    private var seen: [String] = []
    private var seenSet: Set<String> = []
    private var myToken = ""
    private var owner = ""
    private let url: URL
    private let ratchet = RatchetCache()

    private static let maxSeen = 4_000
    private static let maxPerThread = 1_000
    private static let maxAI = 200
    private static let pagesPerGateway = 5
    private static let requestRetry: Int64 = 120
    private static let requestGiveUp: Int64 = 7 * 86_400
    private static let receiptWindow: Int64 = 2 * 86_400
    private static let maxAvatarBytes = 96 * 1024

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = support.appendingPathComponent("messenger.json")
    }

    func load(for address: String) {
        guard owner != address else { return }
        owner = address
        var saved = SavedMessenger(owner: address)
        if let data = try? Data(contentsOf: url),
           let found = try? JSONDecoder().decode(SavedMessenger.self, from: data),
           found.owner == address {
            saved = found
        }
        threads = saved.threads
        ai = saved.ai
        lastRead = saved.lastRead
        cursors = saved.cursors
        seen = saved.seen
        seenSet = Set(saved.seen)
        phoneContacts = saved.phoneContacts
        avatars = saved.avatars
        myAvatar = saved.myAvatar
        myToken = saved.myToken
        myName = saved.myName
        historyAskedAt = saved.historyAskedAt
    }

    func forget() {
        try? FileManager.default.removeItem(at: url)
        owner = ""
        threads = [:]
        ai = []
        lastRead = [:]
        cursors = [:]
        seen = []
        seenSet = []
        phoneContacts = []
        avatars = [:]
        myAvatar = ""
        myToken = ""
        myName = ""
        historyAskedAt = 0
    }

    private func save() {
        guard !owner.isEmpty else { return }
        var saved = SavedMessenger(owner: owner)
        saved.threads = threads
        saved.ai = ai
        saved.lastRead = lastRead
        saved.cursors = cursors
        saved.seen = seen
        saved.phoneContacts = phoneContacts
        saved.avatars = avatars
        saved.myAvatar = myAvatar
        saved.myToken = myToken
        saved.myName = myName
        saved.historyAskedAt = historyAskedAt
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    var contacts: [AccountRecord.Contact] {
        var out = AccountStore.shared.contacts
        let known = Set(out.map(\.address))
        out += phoneContacts.filter { $0.status == "approved" && !known.contains($0.address) }.map(\.contact)
        return out
    }

    var requests: [PhoneContact] {
        let known = Set(AccountStore.shared.contacts.map(\.address))
        return phoneContacts.filter { $0.status == "pending_in" && !known.contains($0.address) }
    }

    var waiting: [PhoneContact] {
        phoneContacts.filter { $0.status == "pending_out" }
    }

    func contact(_ address: String) -> AccountRecord.Contact? {
        contacts.first { $0.address == address }
    }

    func avatar(for address: String) -> String {
        address == owner && !myAvatar.isEmpty ? myAvatar : (avatars[address] ?? "")
    }

    var displayedName: String {
        myName.isEmpty ? AccountStore.shared.desktopName : myName
    }

    private var tokens: Set<String> {
        var out: Set<String> = []
        if !myToken.isEmpty { out.insert(myToken) }
        if let desk = Messenger.ContactCard(parsing: AccountStore.shared.desktopCard), !desk.token.isEmpty { out.insert(desk.token) }
        return out
    }

    func myCard(_ app: AppModel) -> String {
        let desk = AccountStore.shared.desktopCard
        if Messenger.ContactCard(parsing: desk) != nil { return desk }
        guard let key = app.key else { return "" }
        return Messenger.ContactCard(address: key.address, ed25519: key.publicKey, name: displayedName, endpoint: "", token: myToken).text
    }

    var cardFromDesktop: Bool {
        Messenger.ContactCard(parsing: AccountStore.shared.desktopCard) != nil
    }

    func messages(with contact: String) -> [ThreadMessage] {
        threads[contact] ?? []
    }

    func last(with contact: String) -> ThreadMessage? {
        threads[contact]?.last
    }

    func unread(with contact: String) -> Int {
        let read = lastRead[contact] ?? 0
        return (threads[contact] ?? []).filter { $0.from == contact && $0.ts > read }.count
    }

    var totalUnread: Int {
        threads.keys.reduce(0) { $0 + unread(with: $1) } + requests.count
    }

    func markRead(_ contact: String, app: AppModel) {
        let read = lastRead[contact] ?? 0
        let fresh = (threads[contact] ?? []).filter { $0.from == contact && $0.ts > read }
        guard let newest = fresh.map(\.ts).max() else { return }
        lastRead[contact] = newest
        save()
        guard let key = app.key, let peer = self.contact(contact) else { return }
        let ids = fresh.map(\.id)
        Task { try? await post(Messenger.Outgoing.receipt(read: true, from: key.address, to: contact, ids: ids), to: contact, ed25519: peer.ed25519, app: app) }
    }

    private func post(_ fields: [String: Any], to address: String, ed25519: String, app: AppModel) async throws {
        guard let key = app.key else { throw WalletError.locked }
        guard let ed = Messenger.publicKey(ed25519: ed25519) else { throw MessengerError.badKey }
        let sealed = try Messenger.seal(try Messenger.Outgoing.data(fields), to: address, ed25519: ed)
        try await app.perform { try await $0.sendMail(sealed, with: key) }
    }

    private func ensureToken(_ app: AppModel) async {
        guard myToken.isEmpty else { return }
        let saved = AccountStore.shared.phoneContent.token
        myToken = saved.isEmpty ? Hex.encode(SecureRandom.bytes(16)) : saved
        save()
        if saved.isEmpty {
            let token = myToken
            await AccountStore.shared.updatePhone(app) { $0.token = token }
        }
    }

    private func publishContacts(_ app: AppModel) async {
        let approved = phoneContacts.filter { $0.status == "approved" }.map(\.contact)
        let token = myToken
        await AccountStore.shared.updatePhone(app) { content in
            content.contacts = approved
            content.token = token
        }
    }

    func refresh(_ app: AppModel) async {
        guard let key = app.key, !refreshing else { return }
        load(for: key.address)
        refreshing = true
        defer { refreshing = false }
        let account = AccountStore.shared
        await account.refresh(app)
        await account.announcePhone(app)
        await ensureToken(app)
        let me = key.address
        let savedContacts = account.phoneContent.contacts
        if phoneContacts.isEmpty && !savedContacts.isEmpty {
            phoneContacts = savedContacts.map { PhoneContact(address: $0.address, name: $0.name, ed25519: $0.ed25519, sharedKeyHex: $0.sharedKeyHex, status: "approved", token: "", addedAt: 0, lastRequestAt: 0) }
        }
        if myAvatar.isEmpty, !account.phoneContent.avatar.isEmpty { myAvatar = account.phoneContent.avatar }
        mergeSent(account.allSent, me: me)
        await askForHistoryOnce(app)

        let clients = await account.places(app, for: me)
        let pages = Self.pagesPerGateway
        var fetched: [Messenger.Kept] = []
        await withTaskGroup(of: (String, [Messenger.Kept], Int64?).self) { group in
            for client in clients {
                let name = client.gateway.endpoint.absoluteString
                let start = cursors[name] ?? 0
                group.addTask {
                    var since = start
                    var all: [Messenger.Kept] = []
                    for _ in 0..<pages {
                        guard let page = try? await client.mail(for: key, since: since) else { return (name, all, all.isEmpty ? nil : since) }
                        all += page.mail
                        since = page.mail.map(\.at).max() ?? since
                        if !page.more || page.mail.isEmpty { break }
                    }
                    return (name, all, since)
                }
            }
            for await (name, mail, cursor) in group {
                fetched += mail
                if let cursor { cursors[name] = cursor }
            }
        }

        let seed = key.seed
        var inners: [Messenger.Inner] = []
        for kept in fetched.sorted(by: { $0.at < $1.at }) where !seenSet.contains(kept.sealed.id) {
            remember(kept.sealed.id)
            if let inner = Messenger.open(kept.sealed, seed: seed) { inners.append(inner) }
        }

        var contactsChanged = false
        var chats: [(Messenger.Bundle, UInt64)] = []
        for inner in inners {
            switch inner.type {
            case "chat_message":
                if let text = inner.bundle, let bundle = Messenger.Bundle(parsing: text), bundle.from == me || bundle.to == me {
                    chats.append((bundle, inner.seq ?? 0))
                }
            case "contact_request":
                contactsChanged = await handleRequest(inner, me: me, app: app) || contactsChanged
            case "contact_response":
                contactsChanged = handleResponse(inner) || contactsChanged
            case "profile_update":
                if let from = inner.fromAddr, let avatar = inner.avatar, Self.validAvatar(avatar) { avatars[from] = avatar }
            case "delivery_receipt", "read_receipt":
                if inner.to == me, let from = inner.from, let ids = inner.messageIds { mark(ids, in: from, read: inner.type == "read_receipt") }
            case "history":
                mergeHistory(inner, me: me)
            default:
                break
            }
        }

        let book = Dictionary(contacts.map { ($0.address, $0) }, uniquingKeysWith: { a, _ in a })
        var arrived: [String: [String]] = [:]
        let now = Int64(Date().timeIntervalSince1970)
        for (bundle, seq) in chats.sorted(by: { $0.0.ts < $1.0.ts }) {
            let peer = bundle.from == me ? bundle.to : bundle.from
            guard let contact = book[peer],
                  let plain = Messenger.decrypt(bundle, seq: seq, me: me, sharedKeyHex: contact.sharedKeyHex, ratchet: ratchet) else { continue }
            if apply(bundle, content: plain, me: me), bundle.from != me, now - bundle.ts < Self.receiptWindow {
                arrived[peer, default: []].append(bundle.id)
            }
        }
        save()
        if contactsChanged { await publishContacts(app) }
        for (peer, ids) in arrived {
            guard let contact = book[peer] else { continue }
            try? await post(Messenger.Outgoing.receipt(read: false, from: me, to: peer, ids: ids), to: peer, ed25519: contact.ed25519, app: app)
        }
        await resendRequests(app)
    }

    private func askForHistoryOnce(_ app: AppModel) async {
        guard historyAskedAt == 0, cardFromDesktop else { return }
        await askForHistory(app)
    }

    func askForHistory(_ app: AppModel) async {
        let now = Int64(Date().timeIntervalSince1970)
        historyAskedAt = now
        save()
        await AccountStore.shared.updatePhone(app) { $0.wantHistory = now }
    }

    private func remember(_ id: String) {
        seen.append(id)
        seenSet.insert(id)
        if seen.count > Self.maxSeen {
            let drop = seen.prefix(seen.count - Self.maxSeen)
            drop.forEach { seenSet.remove($0) }
            seen.removeFirst(drop.count)
        }
    }

    private static func validAvatar(_ avatar: String) -> Bool {
        avatar.isEmpty || (avatar.utf8.count <= maxAvatarBytes && avatar.hasPrefix("data:image/") && avatar.contains(";base64,"))
    }

    private func handleRequest(_ inner: Messenger.Inner, me: String, app: AppModel) async -> Bool {
        guard let from = inner.fromAddr, from != me, from.hasPrefix("ego"),
              let ed = inner.fromEd25519, Messenger.publicKey(ed25519: ed) != nil,
              let shared = inner.fromSharedKey, Hex.decode(shared)?.count == 32,
              tokens.contains(inner.bundleToken ?? "") else { return false }
        if AccountStore.shared.contacts.contains(where: { $0.address == from }) { return false }
        if let existing = phoneContacts.first(where: { $0.address == from }) {
            if existing.status == "approved", let key = app.key {
                try? await post(Messenger.Outgoing.contactResponse(from: key.address, name: displayedName, ed25519Hex: Hex.encode(key.publicKey), approved: true, sharedKeyHex: existing.sharedKeyHex),
                                to: from, ed25519: existing.ed25519, app: app)
            }
            return false
        }
        let now = Int64(Date().timeIntervalSince1970)
        phoneContacts.append(PhoneContact(address: from, name: inner.fromName ?? "", ed25519: ed, sharedKeyHex: shared, status: "pending_in", token: "", addedAt: now, lastRequestAt: 0))
        notice = "\(inner.fromName.flatMap { $0.isEmpty ? nil : $0 } ?? shortAddress(from)) wants to connect with you"
        return false
    }

    private func handleResponse(_ inner: Messenger.Inner) -> Bool {
        guard let shared = inner.sharedKey, let from = inner.fromAddr,
              let i = phoneContacts.firstIndex(where: { $0.sharedKeyHex == shared && ($0.status == "pending_out" || $0.status == "approved") }) else { return false }
        if inner.approved == true {
            let first = phoneContacts[i].status != "approved"
            phoneContacts[i].address = from
            if first, let name = inner.fromName, !name.isEmpty { phoneContacts[i].name = name }
            if let ed = inner.fromEd25519, Messenger.publicKey(ed25519: ed) != nil { phoneContacts[i].ed25519 = ed }
            phoneContacts[i].status = "approved"
            if first { notice = "\(phoneContacts[i].name.isEmpty ? shortAddress(from) : phoneContacts[i].name) accepted your request" }
            return true
        }
        if phoneContacts[i].status == "pending_out" {
            phoneContacts.remove(at: i)
            notice = "Your contact request was declined."
        }
        return false
    }

    private func mark(_ ids: [String], in peer: String, read: Bool) {
        guard var list = threads[peer] else { return }
        let wanted = Set(ids)
        var changed = false
        for i in list.indices where wanted.contains(list[i].id) && list[i].from != peer {
            if !list[i].delivered { list[i].delivered = true; changed = true }
            if read && !list[i].read { list[i].read = true; changed = true }
        }
        if changed { threads[peer] = list }
    }

    private func mergeHistory(_ inner: Messenger.Inner, me: String) {
        for m in inner.messages ?? [] {
            let peer = m.from == me ? m.to : m.from
            var message = ThreadMessage(id: m.id, from: m.from, to: m.to, ts: m.ts, type: m.type == "reply" ? "text" : m.type,
                                        text: m.content, replyTo: m.replyTo, editedAt: m.editedAt, delivered: m.delivered, read: m.read)
            message.reactions = Dictionary(m.reactions.map { ($0.from, $0.emoji) }, uniquingKeysWith: { a, _ in a })
            insert(message, peer: peer)
            if m.from != me, (lastRead[peer] ?? 0) < m.ts { lastRead[peer] = m.ts }
        }
        for p in inner.profiles ?? [] {
            guard let avatar = p.avatar, Self.validAvatar(avatar) else { continue }
            if p.address == me {
                if myAvatar.isEmpty { myAvatar = avatar }
            } else {
                avatars[p.address] = avatar
            }
        }
    }

    private func mergeSent(_ sent: [AccountRecord.Sent], me: String) {
        for s in sent where !(threads[s.to] ?? []).contains(where: { $0.id == s.id }) {
            insert(ThreadMessage(id: s.id, from: me, to: s.to, ts: s.ts, type: s.messageType, text: s.content), peer: s.to)
        }
    }

    @discardableResult
    private func insert(_ message: ThreadMessage, peer: String) -> Bool {
        var list = threads[peer] ?? []
        guard !list.contains(where: { $0.id == message.id }) else { return false }
        let at = list.lastIndex { $0.ts <= message.ts }.map { $0 + 1 } ?? 0
        list.insert(message, at: at)
        if list.count > Self.maxPerThread { list.removeFirst(list.count - Self.maxPerThread) }
        threads[peer] = list
        return true
    }

    @discardableResult
    private func apply(_ bundle: Messenger.Bundle, content: String, me: String) -> Bool {
        let peer = bundle.from == me ? bundle.to : bundle.from
        func message(_ type: String, _ text: String, replyTo: String? = nil) -> ThreadMessage {
            ThreadMessage(id: bundle.id, from: bundle.from, to: bundle.to, ts: bundle.ts, type: type, text: text, replyTo: replyTo)
        }
        switch Messenger.body(type: bundle.type, content: content) {
        case .reaction(let target, let code, let remove):
            guard var list = threads[peer], let i = list.firstIndex(where: { $0.id == target }) else { return false }
            if remove { list[i].reactions.removeValue(forKey: bundle.from) } else { list[i].reactions[bundle.from] = code }
            threads[peer] = list
            return false
        case .edit(let target, let text):
            guard var list = threads[peer], let i = list.firstIndex(where: { $0.id == target }),
                  list[i].from == bundle.from, bundle.ts - list[i].ts <= Messenger.editWindow + 300 else { return false }
            list[i].text = text
            list[i].editedAt = bundle.ts
            threads[peer] = list
            return false
        case .text(let text):
            return insert(message("text", text), peer: peer)
        case .reply(let text, let to):
            return insert(message("text", text, replyTo: to), peer: peer)
        case .file(let link):
            return insert(message("file_bundle", link), peer: peer)
        case .other(let type, let text):
            return insert(message(type, text), peer: peer)
        }
    }

    @discardableResult
    func send(_ body: Messenger.Body, to contact: AccountRecord.Contact, app: AppModel) async -> Bool {
        guard let key = app.key else {
            problem = WalletError.locked.errorDescription
            return false
        }
        sending = true
        defer { sending = false }
        do {
            let (type, content) = Messenger.encode(body)
            let ts = Int64(Date().timeIntervalSince1970)
            let message = try AccountRecord.chatMessage(from: key.address, to: contact.address, ts: ts, type: type, text: content, sharedKeyHex: contact.sharedKeyHex)
            let delivery = try AccountRecord.delivery(of: message.bundle, to: contact, ts: ts, with: key)
            try await app.perform { try await $0.deliver(delivery) }
            if let bundle = Messenger.Bundle(parsing: message.bundle) {
                apply(bundle, content: content, me: key.address)
            }
            switch body {
            case .text(let text), .reply(let text, _):
                await AccountStore.shared.recordSent(AccountRecord.Sent(id: message.id, to: contact.address, content: text, messageType: "text", ts: ts), app: app)
            case .file(let link):
                await AccountStore.shared.recordSent(AccountRecord.Sent(id: message.id, to: contact.address, content: link, messageType: "file_bundle", ts: ts), app: app)
            default:
                break
            }
            problem = nil
            save()
            return true
        } catch {
            problem = app.message(for: error)
            return false
        }
    }

    func toggle(_ code: String, on message: ThreadMessage, with contact: AccountRecord.Contact, app: AppModel) async {
        let mine = message.reactions[app.address]
        Haptics.tap()
        await send(.reaction(target: message.id, code: code, remove: mine == code), to: contact, app: app)
    }

    func addContact(_ text: String, app: AppModel) async -> String? {
        guard let key = app.key else { return WalletError.locked.errorDescription }
        load(for: key.address)
        guard let card = Messenger.ContactCard(parsing: text) else {
            return "That isn't an Ego contact card. A card starts with egocontact1:"
        }
        if card.address == key.address { return "That's your own contact card." }
        if contacts.contains(where: { $0.address == card.address }) { return "They're already in your contacts." }
        if waiting.contains(where: { $0.address == card.address }) { return "A request to them is already waiting for an answer." }
        if let i = phoneContacts.firstIndex(where: { $0.address == card.address && $0.status == "pending_in" }) {
            await approve(phoneContacts[i], app: app)
            return nil
        }
        await ensureToken(app)
        let now = Int64(Date().timeIntervalSince1970)
        let entry = PhoneContact(address: card.address, name: card.name, ed25519: Hex.encode(card.ed25519),
                                 sharedKeyHex: Hex.encode(SecureRandom.bytes(32)), status: "pending_out",
                                 token: card.token, addedAt: now, lastRequestAt: now)
        phoneContacts.append(entry)
        save()
        do {
            try await sendRequest(entry, app: app)
            return nil
        } catch {
            return app.message(for: error)
        }
    }

    private func sendRequest(_ entry: PhoneContact, app: AppModel) async throws {
        guard let key = app.key else { throw WalletError.locked }
        try await post(Messenger.Outgoing.contactRequest(from: key.address, name: displayedName, ed25519Hex: Hex.encode(key.publicKey),
                                                          sharedKeyHex: entry.sharedKeyHex, token: entry.token),
                       to: entry.address, ed25519: entry.ed25519, app: app)
    }

    private func resendRequests(_ app: AppModel) async {
        let now = Int64(Date().timeIntervalSince1970)
        for i in phoneContacts.indices where phoneContacts[i].status == "pending_out"
            && now - phoneContacts[i].addedAt < Self.requestGiveUp
            && now - phoneContacts[i].lastRequestAt >= Self.requestRetry {
            phoneContacts[i].lastRequestAt = now
            try? await sendRequest(phoneContacts[i], app: app)
        }
        save()
    }

    func cancelRequest(_ entry: PhoneContact) {
        phoneContacts.removeAll { $0.address == entry.address && $0.status == "pending_out" }
        save()
    }

    func approve(_ request: PhoneContact, app: AppModel) async {
        guard let key = app.key, let i = phoneContacts.firstIndex(where: { $0.address == request.address && $0.status == "pending_in" }) else { return }
        phoneContacts[i].status = "approved"
        save()
        do {
            try await post(Messenger.Outgoing.contactResponse(from: key.address, name: displayedName, ed25519Hex: Hex.encode(key.publicKey),
                                                              approved: true, sharedKeyHex: request.sharedKeyHex),
                           to: request.address, ed25519: request.ed25519, app: app)
            if !myAvatar.isEmpty {
                try? await post(Messenger.Outgoing.profile(from: key.address, avatar: myAvatar), to: request.address, ed25519: request.ed25519, app: app)
            }
            problem = nil
        } catch {
            problem = app.message(for: error)
        }
        await publishContacts(app)
    }

    func decline(_ request: PhoneContact, app: AppModel) async {
        guard let key = app.key else { return }
        phoneContacts.removeAll { $0.address == request.address && $0.status == "pending_in" }
        save()
        try? await post(Messenger.Outgoing.contactResponse(from: key.address, name: displayedName, ed25519Hex: Hex.encode(key.publicKey),
                                                           approved: false, sharedKeyHex: request.sharedKeyHex),
                        to: request.address, ed25519: request.ed25519, app: app)
    }

    func setName(_ name: String) {
        myName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        save()
    }

    func setAvatar(_ image: UIImage, app: AppModel) async {
        guard let key = app.key, let dataURL = Self.avatarURL(image) else {
            problem = "That picture couldn't be used."
            return
        }
        myAvatar = dataURL
        save()
        let now = Int64(Date().timeIntervalSince1970)
        await AccountStore.shared.updatePhone(app) { content in
            content.avatar = dataURL
            content.avatarAt = now
        }
        for contact in contacts {
            try? await post(Messenger.Outgoing.profile(from: key.address, avatar: dataURL), to: contact.address, ed25519: contact.ed25519, app: app)
        }
    }

    static func avatarURL(_ image: UIImage) -> String? {
        let side: CGFloat = 192
        let scale = side / max(image.size.width, image.size.height, 1)
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        for quality in [0.8, 0.6, 0.45, 0.3, 0.2] {
            if let jpeg = resized.jpegData(compressionQuality: quality), jpeg.count <= 40_000 {
                return "data:image/jpeg;base64," + jpeg.base64EncodedString()
            }
        }
        return nil
    }

    static func image(fromDataURL text: String) -> UIImage? {
        guard let comma = text.firstIndex(of: ","), text.hasPrefix("data:image/") else { return nil }
        return Data(base64Encoded: String(text[text.index(after: comma)...])).flatMap(UIImage.init(data:))
    }

    func ask(_ question: String, app: AppModel) async {
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !thinking else { return }
        if let key = app.key { load(for: key.address) }
        let history = ai.suffix(10).map { Messenger.AITurn(role: $0.fromMe ? "user" : "assistant", content: $0.text) }
        let now = Int64(Date().timeIntervalSince1970)
        ai.append(AIMessage(id: UUID().uuidString, fromMe: true, text: clean, ts: now))
        thinking = true
        defer { thinking = false }
        do {
            let answer = try await app.perform { try await $0.askEgoAI(clean, history: history) }
            ai.append(AIMessage(id: UUID().uuidString, fromMe: false, text: answer, ts: Int64(Date().timeIntervalSince1970)))
            problem = nil
        } catch {
            problem = app.message(for: error)
        }
        if ai.count > Self.maxAI { ai.removeFirst(ai.count - Self.maxAI) }
        save()
    }

    func clearAI() {
        ai = []
        save()
    }
}
