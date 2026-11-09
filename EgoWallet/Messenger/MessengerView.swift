import EgoKit
import PhotosUI
import QuickLook
import SwiftUI

enum MessengerPage: Hashable {
    case ai
    case contact(String)
}

struct MessengerView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = MessengerStore.shared
    @ObservedObject private var account = AccountStore.shared
    @State private var showCard = false
    @State private var showAdd = false

    private var contacts: [AccountRecord.Contact] {
        store.contacts.sorted { a, b in
            let ta = store.last(with: a.address)?.ts ?? 0
            let tb = store.last(with: b.address)?.ts ?? 0
            return ta != tb ? ta > tb : displayName(a).localizedCaseInsensitiveCompare(displayName(b)) == .orderedAscending
        }
    }

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 0.5, colors: Brand.chatAurora)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageTitle(title: "Messenger", subtitle: "End-to-end encrypted") {
                        HStack(spacing: 10) {
                            headerButton("person.badge.plus", label: "Add a contact") { showAdd = true }
                            Button { showCard = true } label: {
                                AvatarImage(dataURL: store.myAvatar, name: store.displayedName, address: app.address, size: 42)
                                    .overlay(alignment: .bottomTrailing) {
                                        Image(systemName: "qrcode")
                                            .font(.system(size: 10, weight: .heavy))
                                            .foregroundStyle(.white)
                                            .padding(4)
                                            .background(Brand.chatGlow, in: Circle())
                                    }
                            }
                            .accessibilityLabel("Your contact card and picture")
                        }
                    }
                    if let notice = store.notice {
                        HStack(spacing: 8) {
                            Image(systemName: "bell.fill").foregroundStyle(Brand.lime)
                            Text(notice).font(.footnote).foregroundStyle(Brand.text)
                            Spacer(minLength: 0)
                            Button { store.notice = nil } label: { Image(systemName: "xmark").foregroundStyle(Brand.muted) }
                        }
                        .padding(12)
                        .background(Brand.lime.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    if let problem = store.problem ?? account.problem {
                        ProblemBanner(text: problem)
                    }
                    NavigationLink(value: MessengerPage.ai) { aiRow }
                        .buttonStyle(.plain)
                    if !store.requests.isEmpty {
                        SectionLabel(text: "Contact requests").padding(.leading, 4)
                        VStack(spacing: 8) {
                            ForEach(store.requests) { RequestRow(request: $0) }
                        }
                    }
                    if contacts.isEmpty && store.waiting.isEmpty {
                        GlassCard {
                            SectionLabel(text: "Contacts")
                            Text("Add people with their contact card, or share yours from the picture at the top. Your Ego Desktop's contacts show here too.")
                                .font(.subheadline)
                                .foregroundStyle(Brand.muted)
                            Button { showAdd = true } label: { Label("Add a contact", systemImage: "person.badge.plus") }
                                .buttonStyle(OutlineButtonStyle())
                        }
                    }
                    if !contacts.isEmpty {
                        SectionLabel(text: "Contacts").padding(.leading, 4)
                        VStack(spacing: 8) {
                            ForEach(contacts) { contact in
                                NavigationLink(value: MessengerPage.contact(contact.address)) { row(contact) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    if !store.waiting.isEmpty {
                        SectionLabel(text: "Waiting for approval").padding(.leading, 4)
                        VStack(spacing: 8) {
                            ForEach(store.waiting) { entry in
                                HStack(spacing: 12) {
                                    ProfilePicture(link: "", fallback: entry.name, address: entry.address, size: 42)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name.isEmpty ? shortAddress(entry.address) : entry.name)
                                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                                            .foregroundStyle(Brand.text)
                                        Text("Request sent, asked again every few minutes").font(.caption).foregroundStyle(Brand.muted)
                                    }
                                    Spacer(minLength: 0)
                                    Button("Cancel") { store.cancelRequest(entry) }
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Brand.muted)
                                }
                                .padding(12)
                                .background(.ultraThinMaterial.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, EgoTabBar.height)
            }
            .refreshable { await store.refresh(app) }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showCard) {
            MyCardSheet()
                .presentationDetents([.large])
                .presentationBackground(Brand.ink)
        }
        .sheet(isPresented: $showAdd) {
            AddContactSheet()
                .presentationDetents([.medium, .large])
                .presentationBackground(Brand.ink)
        }
        .task {
            while !Task.isCancelled {
                await store.refresh(app)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func headerButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Brand.chatGlow, in: Circle())
        }
        .accessibilityLabel(label)
    }

    private var aiRow: some View {
        HStack(spacing: 12) {
            EgoAIBadge(size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Ego AI")
                    .font(.system(.headline, design: .rounded, weight: .heavy))
                    .foregroundStyle(Brand.amber)
                Text(store.ai.last?.text ?? "Ask anything about Ego")
                    .font(.subheadline)
                    .foregroundStyle(Brand.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(Brand.muted)
        }
        .padding(14)
        .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Brand.amber.opacity(0.4)))
    }

    private func row(_ contact: AccountRecord.Contact) -> some View {
        let last = store.last(with: contact.address)
        let unread = store.unread(with: contact.address)
        return HStack(spacing: 12) {
            AvatarImage(dataURL: store.avatar(for: contact.address), name: contact.name, address: contact.address, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(displayName(contact))
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(Brand.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let last {
                        Text(relativeTime(last.ts)).font(.caption2).foregroundStyle(Brand.muted)
                    }
                }
                HStack {
                    Text(last.map { ($0.mine(app.address) ? "You: " : "") + $0.preview } ?? shortAddress(contact.address))
                        .font(.subheadline)
                        .foregroundStyle(unread > 0 ? Brand.text : Brand.muted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if unread > 0 {
                        Text("\(unread)")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .foregroundStyle(Brand.ink)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Brand.pink, in: Capsule())
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08)))
    }
}

func displayName(_ contact: AccountRecord.Contact) -> String {
    contact.name.isEmpty ? shortAddress(contact.address) : contact.name
}

struct EgoAIBadge: View {
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(Brand.ink)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Brand.amber, Brand.lime], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            .accessibilityHidden(true)
    }
}

struct MessengerPageView: View {
    let page: MessengerPage

    var body: some View {
        switch page {
        case .ai: EgoAIView()
        case .contact(let address): ConversationView(address: address)
        }
    }
}

struct ConversationView: View {
    let address: String
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storage: StorageStore
    @ObservedObject private var store = MessengerStore.shared
    @ObservedObject private var account = AccountStore.shared
    @State private var draft = ""
    @FocusState private var composing: Bool
    @State private var replying: ThreadMessage?
    @State private var editing: ThreadMessage?
    @State private var picking = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var attachment: ChatAttachment?
    @State private var uploading = false
    @State private var viewing: URL?

    private let bottomID = "conversation-bottom"

    private var contact: AccountRecord.Contact? {
        store.contact(address)
    }

    private var messages: [ThreadMessage] { store.messages(with: address) }

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 0.45, colors: Brand.chatAurora)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if messages.isEmpty {
                            Text("No messages yet. Say hello 👋")
                                .font(.subheadline)
                                .foregroundStyle(Brand.muted)
                                .padding(.top, 40)
                        }
                        ForEach(Array(messages.enumerated()), id: \.element.id) { i, message in
                            let previous = i > 0 ? messages[i - 1] : nil
                            let following = i + 1 < messages.count ? messages[i + 1] : nil
                            if previous.map({ !Calendar.current.isDate(day($0.ts), inSameDayAs: day(message.ts)) }) ?? true {
                                DayDivider(date: day(message.ts))
                            }
                            MessageBubble(message: message,
                                          mine: message.mine(app.address),
                                          first: !sameRun(previous, message),
                                          last: !sameRun(message, following),
                                          quoted: message.replyTo.flatMap { id in messages.first { $0.id == id } },
                                          me: app.address,
                                          status: message.mine(app.address) ? (message.read ? "Read" : message.delivered ? "Delivered" : "Sent") : nil,
                                          onReact: { code in react(code, message) },
                                          onOpen: { viewing = $0 })
                                .id(message.id)
                                .contextMenu { menu(for: message) }
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.last?.id) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                    store.markRead(address, app: app)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(contact.map(displayName) ?? shortAddress(address))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AvatarImage(dataURL: store.avatar(for: address), name: contact?.name ?? "", address: address, size: 32)
            }
        }
        .photosPicker(isPresented: $picking, selection: $picked, maxSelectionCount: 1, matching: .any(of: [.images, .videos]))
        .onChange(of: picked) { _, items in
            guard let item = items.first else { return }
            picked = []
            Task { await attach(item) }
        }
        .quickLookPreview($viewing)
        .task {
            storage.attach(app)
            store.markRead(address, app: app)
            while !Task.isCancelled {
                await store.refresh(app)
                store.markRead(address, app: app)
                try? await Task.sleep(for: .seconds(6))
            }
        }
    }

    private func day(_ ts: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

    private func sameRun(_ a: ThreadMessage?, _ b: ThreadMessage?) -> Bool {
        guard let a, let b else { return false }
        return a.from == b.from && abs(b.ts - a.ts) < 300 && Calendar.current.isDate(day(a.ts), inSameDayAs: day(b.ts))
    }

    private func canEdit(_ message: ThreadMessage) -> Bool {
        message.mine(app.address) && message.type == "text"
            && Int64(Date().timeIntervalSince1970) - message.ts < Messenger.editWindow
    }

    private func react(_ code: String, _ message: ThreadMessage) {
        guard let contact else { return }
        Task { await store.toggle(code, on: message, with: contact, app: app) }
    }

    @ViewBuilder
    private func menu(for message: ThreadMessage) -> some View {
        ControlGroup {
            ForEach(Messenger.reactions, id: \.code) { r in
                Button(r.emoji) { react(r.code, message) }
            }
        }
        Button {
            replying = message
            editing = nil
            composing = true
        } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        if message.type != "file_bundle" {
            Button {
                UIPasteboard.general.string = message.text
            } label: { Label("Copy text", systemImage: "doc.on.doc") }
        }
        if canEdit(message) {
            Button {
                editing = message
                replying = nil
                draft = message.text
                composing = true
            } label: { Label("Edit", systemImage: "pencil") }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let problem = store.problem {
                ProblemBanner(text: problem)
            }
            if let replying {
                chip(icon: "arrowshape.turn.up.left", title: "Replying", detail: replying.preview) { self.replying = nil }
            }
            if let editing {
                chip(icon: "pencil", title: "Editing your message", detail: editing.preview) {
                    self.editing = nil
                    draft = ""
                }
            }
            if let attachment {
                chip(icon: attachment.isVideo ? "video.fill" : "photo.fill", title: attachment.name,
                     detail: uploading ? "Encrypting and uploading…" : "Ready to send") { if !uploading { self.attachment = nil } }
            }
            let ready = contact != nil && !store.sending && !uploading
                && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (attachment != nil && editing == nil))
            HStack(alignment: .bottom, spacing: 6) {
                if editing == nil {
                    Button {
                        composing = false
                        picking = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Brand.sky)
                            .frame(width: 36, height: 36)
                            .background(Brand.sky.opacity(0.15), in: Circle())
                    }
                    .disabled(attachment != nil || uploading || contact == nil)
                    .accessibilityLabel("Send a photo or video")
                }
                HStack(alignment: .bottom, spacing: 4) {
                    TextField(editing == nil ? "Message" : "Edit your message", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($composing)
                        .foregroundStyle(Brand.text)
                        .padding(.leading, 14)
                        .padding(.vertical, 10)
                    Button {
                        Task { await send() }
                    } label: {
                        Group {
                            if store.sending || uploading {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: editing == nil ? "arrow.up" : "checkmark").font(.system(size: 16, weight: .heavy))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(ready ? AnyShapeStyle(Brand.chatGlow) : AnyShapeStyle(Color.white.opacity(0.1)), in: Circle())
                    }
                    .disabled(!ready)
                    .padding(4)
                    .accessibilityLabel(editing == nil ? "Send" : "Save edit")
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Brand.violet.opacity(0.5)))
            }
            if contact == nil {
                Text("This person isn't in your contacts any more.")
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func chip(icon: String, title: String, detail: String, onClose: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Brand.sky)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(.caption, design: .rounded, weight: .heavy)).foregroundStyle(Brand.sky).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(Brand.muted).lineLimit(1)
            }
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.muted) }
                .accessibilityLabel("Cancel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Brand.sky.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func attach(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            store.problem = "That photo or video couldn't be read."
            return
        }
        guard data.count <= StorageStore.maxShareBytes else {
            store.problem = StorageStore.ShareError.tooBig.errorDescription
            return
        }
        let type = item.supportedContentTypes.first
        let isGIF = type?.conforms(to: .gif) ?? false
        let isVideo = type?.conforms(to: .movie) ?? false
        let ext = isGIF ? "gif" : (type?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg"))
        let stamp = Date().formatted(.dateTime.hour().minute().second()).replacingOccurrences(of: ":", with: ".")
        let name = "\(isGIF ? "GIF" : isVideo ? "Video" : "Photo") \(stamp).\(ext)"
        let preview = await Thumbnail.make(for: isVideo ? .video : .photo, data: data).flatMap(UIImage.init(data:))
        attachment = ChatAttachment(name: name, data: data, preview: preview)
        composing = true
    }

    private func send() async {
        guard let contact else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editing {
            guard !text.isEmpty else { return }
            if await store.send(.edit(target: editing.id, text: text), to: contact, app: app) {
                self.editing = nil
                draft = ""
            }
            return
        }
        if let a = attachment {
            uploading = true
            defer { uploading = false }
            do {
                let link = try await storage.uploadForSharing(name: a.name, data: a.data)
                guard await store.send(.file(link.text), to: contact, app: app) else { return }
                attachment = nil
            } catch {
                store.problem = app.message(for: error)
                return
            }
        }
        guard !text.isEmpty else { return }
        let body: Messenger.Body = replying.map { .reply(text: text, to: $0.id) } ?? .text(text)
        if await store.send(body, to: contact, app: app) {
            draft = ""
            replying = nil
        }
    }
}

struct MessageBubble: View {
    let message: ThreadMessage
    let mine: Bool
    let first: Bool
    let last: Bool
    var quoted: ThreadMessage?
    var me: String = ""
    var status: String?
    var onReact: (String) -> Void = { _ in }
    var onOpen: (URL) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if let quoted {
                    Text(quoted.preview)
                        .font(.caption)
                        .foregroundStyle(Brand.muted)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .leading) { Rectangle().fill(Brand.violet).frame(width: 3) }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                content
                    .onTapGesture(count: 2) { onReact("heart") }
                    .overlay(alignment: mine ? .topLeading : .topTrailing) {
                        if !message.reactions.isEmpty {
                            reactions.offset(x: mine ? -12 : 12, y: -16)
                        }
                    }
                    .padding(.top, message.reactions.isEmpty ? 0 : 14)
                if last || message.editedAt != nil {
                    Text(relativeTime(message.ts) + (message.editedAt != nil ? " · edited" : "") + (status.map { " · \($0)" } ?? ""))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Brand.muted)
                        .padding(.horizontal, 6)
                }
            }
            if !mine { Spacer(minLength: 48) }
        }
        .padding(.top, first ? 8 : 0)
    }

    @ViewBuilder private var content: some View {
        if let link = message.link {
            ChatMedia(link: link, onOpen: onOpen)
        } else if message.type == "decrypt_key" {
            bubble(Text("🔑 A file key. Open it in Ego Desktop's EgoSafe."))
        } else if ChatContent.isOnlyEmoji(message.text) {
            Text(message.text).font(.system(size: 46)).padding(.horizontal, 4)
        } else {
            VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                ForEach(Array(ChatContent.parse(message.text).enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .text(let text): bubble(Text(LocalizedStringKey(text)))
                    case .code(let language, let code): CodeBlock(language: language, code: code)
                    case .media(let link): ChatMedia(link: link, onOpen: onOpen)
                    }
                }
            }
        }
    }

    private func bubble(_ text: Text) -> some View {
        text
            .font(.body)
            .tint(mine ? .white : Brand.sky)
            .foregroundStyle(mine ? .white : Brand.text)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(mine ? AnyShapeStyle(Brand.chatGlow) : AnyShapeStyle(.ultraThinMaterial), in: shape)
            .overlay(shape.stroke(mine ? Color.clear : Color.white.opacity(0.08)))
    }

    private var reactions: some View {
        let counts = Dictionary(grouping: message.reactions.values, by: { $0 }).mapValues(\.count)
        return HStack(spacing: 2) {
            ForEach(Messenger.reactions.filter { counts[$0.code] != nil }, id: \.code) { r in
                Button { onReact(r.code) } label: {
                    HStack(spacing: 3) {
                        Text(r.emoji).font(.system(size: 14))
                        if let n = counts[r.code], n > 1 {
                            Text("\(n)").font(.system(size: 11, weight: .heavy, design: .rounded))
                        }
                    }
                    .foregroundStyle(message.reactions[me] == r.code ? Brand.ink : Brand.text)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(message.reactions[me] == r.code ? AnyShapeStyle(Brand.chatGlow) : AnyShapeStyle(Brand.raised), in: Capsule())
                    .overlay(Capsule().stroke(Brand.ink, lineWidth: 2))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var shape: UnevenRoundedRectangle {
        let tucked: CGFloat = last ? 6 : 18
        return mine
            ? UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: tucked, topTrailingRadius: 18, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: tucked, bottomTrailingRadius: 18, topTrailingRadius: 18, style: .continuous)
    }
}

struct EgoAIView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = MessengerStore.shared
    @State private var draft = ""
    @State private var confirmClear = false
    @FocusState private var composing: Bool

    private let bottomID = "ai-bottom"
    private let starters = [
        "How do I earn EGOC with my computer?",
        "How does storage on Ego work?",
        "What is staking and how much does it pay?",
        "How do I send EGOC to someone?",
        "Is Ego quantum-safe?",
    ]

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 0.45, colors: [Brand.amber, Brand.lime, Brand.violet])
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if store.ai.isEmpty {
                            VStack(spacing: 10) {
                                EgoAIBadge(size: 64)
                                Text("Ego AI Assistant").font(.system(.title3, design: .rounded, weight: .heavy)).foregroundStyle(Brand.text)
                                Text("Ask about wallets, storage, staking, nodes and everything else on Ego.")
                                    .font(.subheadline)
                                    .foregroundStyle(Brand.muted)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                            ForEach(starters, id: \.self) { q in
                                Button { Task { await store.ask(q, app: app) } } label: {
                                    Text(q)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Brand.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                        .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Brand.amber.opacity(0.35)))
                                }
                                .buttonStyle(.plain)
                                .disabled(store.thinking)
                            }
                        }
                        ForEach(store.ai) { message in
                            HStack(alignment: .bottom, spacing: 8) {
                                if message.fromMe { Spacer(minLength: 48) } else { EgoAIBadge(size: 28) }
                                Text(LocalizedStringKey(message.text))
                                    .font(.body)
                                    .foregroundStyle(message.fromMe ? .white : Brand.text)
                                    .tint(message.fromMe ? .white : Brand.sky)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(message.fromMe ? AnyShapeStyle(Brand.chatGlow) : AnyShapeStyle(.ultraThinMaterial), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                if !message.fromMe { Spacer(minLength: 24) }
                            }
                        }
                        if store.thinking {
                            HStack(spacing: 8) {
                                EgoAIBadge(size: 28)
                                ProgressView().tint(Brand.amber)
                            }
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: store.ai.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle("Ego AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.ai.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { confirmClear = true }
                }
            }
        }
        .confirmationDialog("Clear this conversation?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { store.clearAI() }
        } message: {
            Text("Your chat with Ego AI is removed from this iPhone.")
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let problem = store.problem {
                ProblemBanner(text: problem)
            }
            HStack(alignment: .bottom, spacing: 4) {
                TextField("Ask Ego AI anything…", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composing)
                    .foregroundStyle(Brand.text)
                    .padding(.leading, 14)
                    .padding(.vertical, 10)
                Button {
                    let q = draft
                    draft = ""
                    Task { await store.ask(q, app: app) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(Brand.ink)
                        .frame(width: 36, height: 36)
                        .background(LinearGradient(colors: [Brand.amber, Brand.lime], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                }
                .disabled(store.thinking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(4)
                .accessibilityLabel("Ask")
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Brand.amber.opacity(0.5)))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}
