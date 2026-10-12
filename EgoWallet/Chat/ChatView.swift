import AVKit
import EgoKit
import ImageIO
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ChatModel: ObservableObject {
    @Published var feed: ChatFeed?
    @Published var problem: String?
    @Published var sending = false

    /// The gateway this chat reads from and writes to. Keeping both on one gateway means a delete,
    /// edit or reaction shows up straight away, and an up-to-date one understands reactions and pictures.
    private var chatGateway: GatewayClient?

    func load(_ app: AppModel) async {
        let viewer = app.address
        if let chatGateway, let fresh = try? await chatGateway.chatFeed(viewer: viewer) {
            feed = fresh
            problem = nil
            return
        }
        chatGateway = nil
        var fallback: (GatewayClient, ChatFeed)?
        var lastError: Error?
        for client in await app.gatewayCandidates() {
            do {
                let fresh = try await client.chatFeed(viewer: viewer)
                // Nodes from before reactions and pictures leave these out.
                if fresh.myAvatarLink != nil {
                    chatGateway = client
                    feed = fresh
                    problem = nil
                    return
                }
                if fallback == nil { fallback = (client, fresh) }
            } catch {
                lastError = error
            }
        }
        if let (client, fresh) = fallback {
            chatGateway = client
            feed = fresh
            problem = nil
        } else if let lastError {
            problem = app.message(for: lastError)
        }
    }

    func submit(_ app: AppModel, _ make: (EgoKey, Int64) throws -> ChatWire) async -> Bool {
        guard let key = app.key else {
            problem = WalletError.locked.errorDescription
            return false
        }
        sending = true
        defer { sending = false }
        do {
            let wire = try make(key, Int64(Date().timeIntervalSince1970))
            if let chatGateway {
                do {
                    try await chatGateway.chatSubmit(wire)
                } catch GatewayError.rpc(let code, let message) where !AppModel.tooOld(code, message) {
                    throw GatewayError.rpc(code, message)
                } catch {
                    self.chatGateway = nil
                    try await app.perform { try await $0.chatSubmit(wire) }
                }
            } else {
                try await app.perform { try await $0.chatSubmit(wire) }
            }
            await load(app)
            return true
        } catch {
            problem = app.message(for: error)
            return false
        }
    }

    /// Reacts with `emoji`, or takes the reaction back when it's already yours.
    func toggle(_ emoji: String, on post: ChatPostView, _ app: AppModel) async {
        let mine = post.reactions.first { $0.mine }?.emoji
        let next = mine == emoji ? "" : emoji
        Haptics.tap()
        _ = await submit(app) { key, now in
            .react(try ChatSigner.react(key: key, postId: post.id, postTs: post.ts, emoji: next, ts: max(now, post.ts)))
        }
    }
}

/// Reactions offered first; any other emoji works from the keyboard's emoji picker too.
let quickReactions = ["👍", "❤️", "😂", "🔥", "🎉", "😮", "🙏", "👀"]

/// A photo, video or GIF picked for the next message.
struct ChatAttachment: Equatable {
    let name: String
    let data: Data
    let preview: UIImage?
    var isVideo: Bool { LibraryFile.Kind.of(name: name) == .video }
}

struct ChatView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storage: StorageStore
    @StateObject private var chat = ChatModel()
    @State private var draft = ""
    @FocusState private var composing: Bool
    @State private var editing: ChatPostView?
    @State private var voteTarget: ChatPostView?
    @State private var deleteTarget: ChatPostView?
    @State private var atBottom = true
    @State private var unseen = 0
    @State private var showEmoji = false
    @State private var picking = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var attachment: ChatAttachment?
    @State private var uploading = false
    @State private var viewing: URL?

    private let bottomID = "chat-bottom"

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground(intensity: 0.55, colors: Brand.chatAurora)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if let feed = chat.feed {
                                ChatIntro(feed: feed).padding(.bottom, 12)
                                if feed.posts.isEmpty {
                                    Text("No messages yet. Say hello 👋")
                                        .font(.subheadline)
                                        .foregroundStyle(Brand.muted)
                                        .padding(.top, 30)
                                }
                                ForEach(Array(feed.posts.enumerated()), id: \.element.id) { i, post in
                                    let previous = i > 0 ? feed.posts[i - 1] : nil
                                    let following = i + 1 < feed.posts.count ? feed.posts[i + 1] : nil
                                    if previous.map({ !Calendar.current.isDate(day($0.ts), inSameDayAs: day(post.ts)) }) ?? true {
                                        DayDivider(date: day(post.ts))
                                    }
                                    ChatBubble(post: post, threshold: feed.threshold,
                                               first: !sameRun(previous, post), last: !sameRun(post, following),
                                               onReact: { emoji in Task { await chat.toggle(emoji, on: post, app) } },
                                               onEdit: { startEditing(post) },
                                               onOpen: { viewing = $0 })
                                        .id(post.id)
                                        .contextMenu { menu(for: post) }
                                }
                            } else {
                                ProgressView().tint(Brand.sky).frame(maxWidth: .infinity).padding(.top, 60)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomID)
                                .onAppear { atBottom = true; unseen = 0 }
                                .onDisappear { atBottom = false }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                        .padding(.bottom, 8)
                    }
                    .contentMargins(.top, 0, for: .scrollContent)
                    .defaultScrollAnchor(.bottom)
                    .scrollDismissesKeyboard(.interactively)
                    // Tapping anywhere in the conversation puts the keyboard away; buttons and links still work.
                    .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
                    .onChange(of: chat.feed?.posts.last?.id) { old, last in
                        guard last != nil, old != last else { return }
                        // Follow new messages when already at the bottom or when they're yours.
                        if atBottom || chat.feed?.posts.last?.mine == true || old == nil {
                            scrollToBottom(proxy)
                        } else {
                            unseen += 1
                        }
                    }
                    .onChange(of: composing) { _, focused in
                        // The keyboard takes the lower half: keep the latest message in view above it,
                        // moving with the keyboard rather than after it.
                        if focused && atBottom {
                            withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                        } else if focused {
                            scrollToBottom(proxy, after: 0.3)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !atBottom {
                            Button {
                                scrollToBottom(proxy)
                                Haptics.tap()
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: 16, weight: .heavy))
                                        .foregroundStyle(.white)
                                        .frame(width: 44, height: 44)
                                        .background(Brand.chatGlow, in: Circle())
                                        .shadow(color: Brand.violet.opacity(0.5), radius: 10)
                                    if unseen > 0 {
                                        Text("\(unseen)")
                                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                                            .foregroundStyle(Brand.ink)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Brand.pink, in: Capsule())
                                            .offset(x: 6, y: -6)
                                    }
                                }
                            }
                            .padding(16)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityLabel(unseen > 0 ? "\(unseen) new messages, scroll to the latest" : "Scroll to the latest message")
                        }
                    }
                    .animation(.spring(response: 0.3), value: atBottom)
                }
            }
            .safeAreaInset(edge: .top) {
                if let problem = chat.problem {
                    ProblemBanner(text: problem).padding(.horizontal, 12).padding(.top, 4)
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Community chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ChatProfileView()
                    } label: {
                        HStack(spacing: 6) {
                            ProfilePicture(link: chat.feed?.myAvatar ?? "", fallback: chat.feed?.myName ?? "", address: app.address, size: 24)
                            Text(chat.feed?.myName.isEmpty == false ? chat.feed?.myName ?? "" : "Profile")
                                .font(.system(.footnote, design: .rounded, weight: .bold))
                                .foregroundStyle(Brand.text)
                        }
                        .padding(.leading, 3)
                        .padding(.trailing, 10)
                        .padding(.vertical, 3)
                        .background(Brand.violet.opacity(0.25), in: Capsule())
                        .overlay(Capsule().stroke(Brand.violet.opacity(0.5)))
                    }
                    .accessibilityLabel("Your chat profile")
                }
            }
            .confirmationDialog(
                "Vote to remove \(voteTarget.map { $0.name.isEmpty ? shortAddress($0.from) : $0.name } ?? "")?",
                isPresented: Binding(get: { voteTarget != nil }, set: { if !$0 { voteTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("Vote to remove", role: .destructive) { Task { await vote() } }
            } message: {
                Text("\(chat.feed?.threshold ?? 5) votes within \(chat.feed?.banDays ?? 14) days remove them from the chat for \(chat.feed?.banDays ?? 14) days. A vote can't be taken back.")
            }
            .confirmationDialog(
                "Delete this message?",
                isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete for everyone", role: .destructive) { Task { await delete() } }
            } message: {
                Text("It disappears for everyone, along with any photo or video you shared in it.")
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
                while !Task.isCancelled {
                    await chat.load(app)
                    try? await Task.sleep(for: .seconds(10))
                }
            }
        }
    }

    private func day(_ ts: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

    private func dismissKeyboard() {
        guard composing || showEmoji else { return }
        withAnimation(.smooth(duration: 0.25)) {
            composing = false
            showEmoji = false
        }
    }

    /// Messages from one person within five minutes read as one run of bubbles.
    private func sameRun(_ a: ChatPostView?, _ b: ChatPostView?) -> Bool {
        guard let a, let b else { return false }
        return a.from == b.from && abs(b.ts - a.ts) < 300 && Calendar.current.isDate(day(a.ts), inSameDayAs: day(b.ts))
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, after delay: Double = 0) {
        Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(bottomID, anchor: .bottom) }
            unseen = 0
        }
    }

    private func minutesLeft(_ post: ChatPostView) -> Int? {
        guard post.mine, let until = post.changeUntil else { return nil }
        let left = until - Int64(Date().timeIntervalSince1970)
        return left > 0 ? Int((left + 59) / 60) : nil
    }

    @ViewBuilder
    private func menu(for post: ChatPostView) -> some View {
        ControlGroup {
            ForEach(quickReactions.prefix(4), id: \.self) { emoji in
                Button(emoji) { Task { await chat.toggle(emoji, on: post, app) } }
            }
        }
        Menu {
            ForEach(quickReactions.dropFirst(4), id: \.self) { emoji in
                Button(emoji) { Task { await chat.toggle(emoji, on: post, app) } }
            }
        } label: {
            Label("More reactions", systemImage: "face.smiling")
        }
        Button {
            UIPasteboard.general.string = ChatContent.parse(post.body).compactMap {
                switch $0 {
                case .text(let t): return t
                case .code(_, let c): return c
                case .media: return nil
                }
            }.joined(separator: "\n")
        } label: {
            Label("Copy text", systemImage: "doc.on.doc")
        }
        if let left = minutesLeft(post) {
            Button {
                startEditing(post)
            } label: {
                Label("Edit · \(left) min left", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteTarget = post
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        if !post.mine {
            Button(role: .destructive) {
                voteTarget = post
            } label: {
                Label(post.myVote ? "You voted to remove" : "Vote to remove", systemImage: "hand.raised")
            }
            .disabled(post.myVote)
        }
    }

    // MARK: Composer

    private var room: Int {
        ChatRules.maxBodyCharacters - (attachment == nil ? 0 : 260)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let until = chat.feed?.myRemovedUntil {
                Label("Community votes removed you from the chat until \(Date(timeIntervalSince1970: TimeInterval(until)).formatted(date: .abbreviated, time: .omitted)).", systemImage: "hand.raised.fill")
                    .font(.footnote)
                    .foregroundStyle(Brand.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Brand.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                if let editing {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil").foregroundStyle(Brand.sky)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Editing your message").font(.system(.caption, design: .rounded, weight: .heavy)).foregroundStyle(Brand.sky)
                            if let left = minutesLeft(editing) {
                                Text("\(left) min left to change it").font(.caption2).foregroundStyle(Brand.muted)
                            }
                        }
                        Spacer()
                        Button("Cancel") { cancelEditing() }
                            .font(.system(.caption, design: .rounded, weight: .bold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Brand.sky.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if let attachment {
                    attachmentChip(attachment)
                }
                if showEmoji {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(["😀", "😂", "🥹", "😍", "😎", "🤔", "😮", "😢", "🙏", "👍", "👏", "🙌", "💪", "🔥", "🎉", "❤️", "💜", "✨", "🚀", "💯", "👀", "✅", "🌍", "🔒"], id: \.self) { emoji in
                                Button {
                                    draft += emoji
                                    Haptics.tap()
                                } label: {
                                    Text(emoji).font(.system(size: 26)).frame(width: 40, height: 40)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                let ready = !chat.sending && !uploading
                    && (ChatRules.cleanBody(draft).map { $0.unicodeScalars.count <= room } ?? (attachment != nil && editing == nil))
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
                        .disabled(attachment != nil || uploading)
                        .accessibilityLabel("Add a photo, video or GIF")
                    }
                    HStack(alignment: .bottom, spacing: 4) {
                        TextField(editing == nil ? "Message everyone…" : "Edit your message", text: $draft, axis: .vertical)
                            .lineLimit(1...6)
                            .focused($composing)
                            .foregroundStyle(Brand.text)
                            .padding(.leading, 14)
                            .padding(.vertical, 10)
                        Button {
                            withAnimation(.spring(response: 0.3)) { showEmoji.toggle() }
                        } label: {
                            Image(systemName: showEmoji ? "face.smiling.inverse" : "face.smiling")
                                .font(.system(size: 19))
                                .foregroundStyle(showEmoji ? Brand.pink : Brand.muted)
                                .frame(width: 34, height: 40)
                        }
                        .accessibilityLabel("Emoji")
                        Button {
                            Task { await send() }
                        } label: {
                            Group {
                                if chat.sending || uploading {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: editing == nil ? "arrow.up" : "checkmark").font(.system(size: 16, weight: .heavy))
                                }
                            }
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(ready || chat.sending || uploading ? AnyShapeStyle(Brand.chatGlow) : AnyShapeStyle(Color.white.opacity(0.1)), in: Circle())
                            .shadow(color: ready ? Brand.violet.opacity(0.5) : .clear, radius: 8)
                        }
                        .disabled(!ready)
                        .padding(4)
                        .accessibilityLabel(editing == nil ? "Send" : "Save edit")
                    }
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(LinearGradient(colors: [Brand.violet.opacity(0.6), Brand.sky.opacity(0.3)], startPoint: .leading, endPoint: .trailing))
                    )
                }
                let used = draft.unicodeScalars.count
                if used > room - 60 {
                    Text("\(used)/\(room)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(used > room ? Brand.danger : Brand.muted)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 12)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func attachmentChip(_ a: ChatAttachment) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if let image = a.preview {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Brand.raised
                    Image(systemName: a.isVideo ? "video.fill" : "photo.fill").foregroundStyle(Brand.muted)
                }
                if a.isVideo {
                    Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).padding(5).background(.black.opacity(0.5), in: Circle())
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(a.name).font(.system(.caption, design: .rounded, weight: .bold)).foregroundStyle(Brand.text).lineLimit(1)
                Text(uploading ? "Encrypting and uploading…" : "\(bytes(a.data.count)) · add a caption or send")
                    .font(.caption2).foregroundStyle(Brand.muted)
            }
            Spacer()
            if !uploading {
                Button {
                    attachment = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(Brand.muted)
                }
                .accessibilityLabel("Remove attachment")
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func attach(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            chat.problem = "That photo or video couldn't be read."
            return
        }
        guard data.count <= StorageStore.maxShareBytes else {
            chat.problem = StorageStore.ShareError.tooBig.errorDescription
            return
        }
        let type = item.supportedContentTypes.first
        let isGIF = type?.conforms(to: .gif) ?? false
        let isVideo = type?.conforms(to: .movie) ?? false
        let ext = isGIF ? "gif" : (type?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg"))
        let stamp = Date().formatted(.dateTime.hour().minute().second()).replacingOccurrences(of: ":", with: ".")
        let name = "\(isGIF ? "GIF" : isVideo ? "Video" : "Photo") \(stamp).\(ext)"
        let preview = await Thumbnail.make(for: isVideo ? .video : .photo, data: data).flatMap(UIImage.init(data:))
        withAnimation(.spring(response: 0.3)) { attachment = ChatAttachment(name: name, data: data, preview: preview) }
        composing = true
    }

    private func send() async {
        if let post = editing {
            await saveEdit(post)
            return
        }
        var body = ChatRules.cleanBody(draft) ?? ""
        if let a = attachment {
            uploading = true
            defer { uploading = false }
            do {
                let link = try await storage.uploadForSharing(name: a.name, data: a.data)
                body = body.isEmpty ? link.text : body + "\n" + link.text
            } catch {
                chat.problem = app.message(for: error)
                return
            }
        }
        guard let clean = ChatRules.cleanBody(body) else { return }
        let name = chat.feed?.myName ?? ""
        if await chat.submit(app, { key, now in .post(try ChatSigner.post(key: key, name: name, body: clean, ts: now)) }) {
            draft = ""
            attachment = nil
            showEmoji = false
        }
    }

    private func startEditing(_ post: ChatPostView) {
        editing = post
        // Edit the words; a shared photo or video stays as it is.
        draft = ChatContent.parse(post.body).compactMap {
            switch $0 {
            case .text(let t): return t
            case .code(let lang, let c): return "```\(lang)\n\(c)\n```"
            case .media: return nil
            }
        }.joined(separator: "\n")
        attachment = nil
        composing = true
    }

    private func cancelEditing() {
        editing = nil
        draft = ""
    }

    private func saveEdit(_ post: ChatPostView) async {
        let links = ChatContent.parse(post.body).compactMap { part -> String? in
            if case .media(let link) = part { return link.text }
            return nil
        }
        let text = ChatRules.cleanBody(draft) ?? ""
        guard let body = ChatRules.cleanBody(([text] + links).filter { !$0.isEmpty }.joined(separator: "\n")) else { return }
        if await chat.submit(app, { key, now in .edit(try ChatSigner.edit(key: key, postId: post.id, postTs: post.ts, body: body, ts: now)) }) {
            editing = nil
            draft = ""
        }
    }

    private func delete() async {
        guard let post = deleteTarget else { return }
        deleteTarget = nil
        if await chat.submit(app, { key, now in .delete(try ChatSigner.delete(key: key, postId: post.id, postTs: post.ts, ts: now)) }) {
            // A photo or video shared in it goes too.
            for part in ChatContent.parse(post.body) {
                if case .media(let link) = part, let file = storage.files.first(where: { $0.cid == link.cid }) {
                    storage.delete(file)
                }
            }
        }
    }

    private func vote() async {
        guard let post = voteTarget else { return }
        voteTarget = nil
        _ = await chat.submit(app, { key, now in .vote(try ChatSigner.vote(key: key, target: post.from, ts: now)) })
    }
}

/// Your name and picture in the community chat.
struct ChatProfileView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storage: StorageStore
    @StateObject private var chat = ChatModel()
    @State private var name = ""
    @State private var pickingPicture = false
    @State private var pictureItem: PhotosPickerItem?
    @State private var busy = false
    @State private var saved = false

    var body: some View {
        GlassPage(aurora: Brand.chatAurora) {
            VStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    ProfilePicture(link: chat.feed?.myAvatar ?? "", fallback: name, address: app.address, size: 112)
                        .overlay(Circle().stroke(Brand.chatGlow, lineWidth: 3))
                        .shadow(color: Brand.violet.opacity(0.4), radius: 18)
                    Button {
                        pickingPicture = true
                    } label: {
                        Image(systemName: busy ? "hourglass" : "camera.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Brand.chatGlow, in: Circle())
                            .overlay(Circle().stroke(Brand.ink, lineWidth: 3))
                    }
                    .disabled(busy)
                    .accessibilityLabel("Change profile picture")
                }
                Text(name.isEmpty ? shortAddress(app.address) : name)
                    .font(.system(.title3, design: .rounded, weight: .heavy))
                    .foregroundStyle(Brand.text)
            }
            .padding(.top, 8)
            .reveal(0)
            GlassField(label: "Name in the chat", icon: "person.fill") {
                TextField("Your name", text: $name)
                    .glassInput()
                    .textInputAutocapitalization(.words)
                Text("Up to \(ChatRules.maxNameCharacters) characters. Your address is always shown next to it.")
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
            }
            .reveal(0.04)
            if let problem = chat.problem { ProblemBanner(text: problem) }
            Button(saved ? "Saved" : "Save name") { Task { await saveName() } }
                .buttonStyle(GlowButtonStyle())
                .disabled(busy || ChatRules.cleanName(name) == nil || name == chat.feed?.myName)
            if chat.feed?.myAvatar.isEmpty == false {
                Button("Remove picture") { Task { await setPicture("") } }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(busy)
            }
            NoteCard(text: "Your picture is stored encrypted in your Ego Storage and shared with a link, so anyone in the chat can see it. It counts toward your storage space.",
                     icon: "lock.fill", tint: Brand.sky)
        }
        .navigationTitle("Chat profile")
        .navigationBarTitleDisplayMode(.inline)
        .photosPicker(isPresented: $pickingPicture, selection: $pictureItem, matching: .images)
        .onChange(of: pictureItem) { _, item in
            guard let item else { return }
            pictureItem = nil
            Task { await upload(item) }
        }
        .task {
            storage.attach(app)
            await chat.load(app)
            name = chat.feed?.myName ?? ""
        }
    }

    private func saveName() async {
        guard let clean = ChatRules.cleanName(name) else { return }
        busy = true
        defer { busy = false }
        if await chat.submit(app, { key, now in .name(try ChatSigner.name(key: key, name: clean, ts: now)) }) {
            Haptics.success()
            saved = true
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
            chat.problem = "That picture couldn't be read."
            return
        }
        busy = true
        defer { busy = false }
        // A small square is plenty for a profile picture and keeps it quick to load.
        let side: CGFloat = 320
        let scale = side / min(image.size.width, image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let square = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
        guard let jpeg = square.jpegData(compressionQuality: 0.8) else { return }
        do {
            let link = try await storage.uploadForSharing(name: "Profile picture.jpg", data: jpeg)
            await setPicture(link.text)
        } catch {
            chat.problem = app.message(for: error)
        }
    }

    private func setPicture(_ link: String) async {
        busy = true
        defer { busy = false }
        if await chat.submit(app, { key, now in .avatar(try ChatSigner.avatar(key: key, link: link, ts: now)) }) {
            Haptics.success()
        }
    }
}

/// What this chat is and how it keeps itself civil.
struct ChatIntro: View {
    let feed: ChatFeed

    var body: some View {
        let people = Set(feed.posts.map(\.from)).count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Brand.chatGlow, in: Circle())
                    .shadow(color: Brand.violet.opacity(0.5), radius: 12)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Everyone on Ego")
                        .font(.system(.headline, design: .rounded, weight: .heavy))
                        .foregroundStyle(Brand.text)
                    HStack(spacing: 6) {
                        pill("\(people) \(people == 1 ? "person" : "people")", icon: "person.2.fill", tint: Brand.sky)
                        pill("Signed by each wallet", icon: "signature", tint: Brand.violet)
                    }
                }
            }
            Text("Anyone can read this. \(feed.threshold) removal votes within \(feed.banDays) days remove someone for \(feed.banDays) days. Hold a message to react, copy, edit or vote.")
                .font(.caption)
                .foregroundStyle(Brand.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.45), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(LinearGradient(colors: [Brand.violet.opacity(0.5), Brand.sky.opacity(0.1)], startPoint: .top, endPoint: .bottom))
        )
    }

    private func pill(_ text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

struct DayDivider: View {
    let date: Date

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(Brand.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
            .padding(.vertical, 10)
    }

    private var label: String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}


/// One message: yours on the right in violet light, everyone else's on the left in glass.
/// Text, code, photos, videos and GIFs each get their own look; reactions sit underneath.
struct ChatBubble: View {
    let post: ChatPostView
    let threshold: Int
    /// First and last of a run from the same person.
    let first: Bool
    let last: Bool
    var onReact: (String) -> Void = { _ in }
    var onEdit: () -> Void = {}
    var onOpen: (URL) -> Void = { _ in }

    private var parts: [ChatPart] { ChatContent.parse(post.body) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if post.mine {
                Spacer(minLength: 48)
            } else {
                ProfilePicture(link: post.avatar, fallback: post.name, address: post.from, size: 30)
                    .opacity(last ? 1 : 0)
            }
            VStack(alignment: post.mine ? .trailing : .leading, spacing: 4) {
                if first && !post.mine {
                    HStack(spacing: 6) {
                        Text(post.name.isEmpty ? shortAddress(post.from) : post.name)
                            .font(.system(.caption, design: .rounded, weight: .heavy))
                            .foregroundStyle(ProfilePicture.color(for: post.from))
                        if !post.name.isEmpty {
                            Text(shortAddress(post.from))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Brand.muted)
                        }
                    }
                    .padding(.leading, 6)
                }
                content
                    .onTapGesture(count: 2) { onReact("❤️") }
                    // Reactions sit on the bubble's top corner away from the sender: left on yours, right on others'.
                    .overlay(alignment: post.mine ? .topLeading : .topTrailing) {
                        if !post.reactions.isEmpty {
                            reactions
                                .offset(x: post.mine ? -12 : 12, y: -16)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.top, post.reactions.isEmpty ? 0 : 14)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: post.reactions)
                footer
            }
            if !post.mine { Spacer(minLength: 48) }
        }
        .padding(.top, first ? 8 : 0)
    }

    @ViewBuilder private var content: some View {
        if ChatContent.isOnlyEmoji(post.body) {
            Text(post.body)
                .font(.system(size: 46))
                .padding(.horizontal, 4)
        } else {
            VStack(alignment: post.mine ? .trailing : .leading, spacing: 6) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .text(let text):
                        Text(LocalizedStringKey(text))
                            .font(.body)
                            .tint(post.mine ? .white : Brand.sky)
                            .foregroundStyle(post.mine ? .white : Brand.text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(bubbleFill, in: shape)
                            .overlay(shape.stroke(post.mine ? Color.clear : Color.white.opacity(0.08)))
                    case .code(let language, let code):
                        CodeBlock(language: language, code: code)
                    case .media(let link):
                        ChatMedia(link: link, onOpen: onOpen)
                    }
                }
            }
        }
    }

    private var reactions: some View {
        HStack(spacing: 2) {
            ForEach(post.reactions.prefix(4), id: \.emoji) { r in
                Button {
                    onReact(r.emoji)
                } label: {
                    HStack(spacing: 3) {
                        Text(r.emoji).font(.system(size: 14))
                        if r.count > 1 {
                            Text("\(r.count)").font(.system(size: 11, weight: .heavy, design: .rounded))
                        }
                    }
                    .foregroundStyle(r.mine ? Brand.ink : Brand.text)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(r.mine ? AnyShapeStyle(Brand.chatGlow) : AnyShapeStyle(Brand.raised), in: Capsule())
                    .overlay(Capsule().stroke(Brand.ink, lineWidth: 2))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(r.emoji) \(r.count)\(r.mine ? ", yours" : "")")
            }
        }
    }

    @ViewBuilder private var footer: some View {
        let editable = post.mine && (post.changeUntil ?? 0) > Int64(Date().timeIntervalSince1970)
        if last || post.edited || editable {
            HStack(spacing: 6) {
                if last || post.edited {
                    Text(relativeTime(post.ts) + (post.edited ? " · edited" : ""))
                }
                if editable {
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.sky)
                }
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Brand.muted)
            .padding(.horizontal, 6)
        }
        if !post.mine && post.removalVotes > 0 {
            Label("\(post.removalVotes)/\(threshold) to remove", systemImage: "hand.raised.fill")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.danger)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Brand.danger.opacity(0.12), in: Capsule())
        }
    }

    private var bubbleFill: AnyShapeStyle {
        post.mine ? AnyShapeStyle(Brand.chatGlow) : AnyShapeStyle(.ultraThinMaterial)
    }

    /// The corner nearest the sender is tucked in on the last bubble of a run.
    private var shape: UnevenRoundedRectangle {
        let tucked: CGFloat = last ? 6 : 18
        return post.mine
            ? UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: tucked, topTrailingRadius: 18, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: tucked, bottomTrailingRadius: 18, topTrailingRadius: 18, style: .continuous)
    }
}

/// A photo, GIF or video shared in a message, fetched from Ego Storage and decrypted with the key in its link.
struct ChatMedia: View {
    let link: EgoShareLink
    var onOpen: (URL) -> Void = { _ in }
    @EnvironmentObject private var storage: StorageStore
    @State private var url: URL?
    @State private var image: UIImage?
    @State private var failed = false

    private var kind: LibraryFile.Kind { LibraryFile.Kind.of(name: link.name) }
    private var isGIF: Bool { (link.name as NSString).pathExtension.lowercased() == "gif" }

    var body: some View {
        Button {
            if let url { onOpen(url) } else if failed { failed = false; Task { await load() } }
        } label: {
            ZStack {
                if let image {
                    if isGIF, let url {
                        AnimatedImage(url: url)
                            .aspectRatio(image.size, contentMode: .fit)
                    } else {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                } else {
                    Rectangle().fill(Brand.raised.opacity(0.8))
                        .frame(width: 220, height: kind == .document ? 70 : 160)
                    VStack(spacing: 6) {
                        if failed {
                            Image(systemName: "arrow.clockwise").font(.title3)
                            Text("Couldn't load · tap to retry").font(.caption2)
                        } else if kind == .document {
                            Label(link.name, systemImage: "doc.fill").font(.caption.weight(.bold)).lineLimit(1).padding(.horizontal, 10)
                        } else {
                            ProgressView().tint(Brand.sky)
                        }
                    }
                    .foregroundStyle(Brand.muted)
                }
                if kind == .video, image != nil {
                    Image(systemName: "play.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(16)
                        .background(.black.opacity(0.45), in: Circle())
                }
            }
            .frame(maxWidth: 240, maxHeight: 300)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind == .video ? "Video, \(link.name)" : kind == .photo ? "Photo, \(link.name)" : link.name)
        .task(id: link.cid) { await load() }
    }

    private func load() async {
        do {
            let file = try await storage.openShared(link)
            url = file
            switch kind {
            case .photo:
                image = await Task.detached { UIImage(contentsOfFile: file.path).map { $0.preparingThumbnail(of: CGSize(width: 720, height: 720)) ?? $0 } }.value
            case .video:
                image = await Task.detached {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 720, height: 720)
                    return (try? await generator.image(at: .zero).image).map(UIImage.init(cgImage:))
                }.value
            case .document:
                break
            }
        } catch {
            failed = true
        }
    }
}

/// Plays an animated GIF.
struct AnimatedImage: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = Self.animated(url)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {}

    static func animated(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = min(CGImageSourceGetCount(source), 300)
        var frames: [UIImage] = []
        var duration = 0.0
        for i in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, i, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
            ] as CFDictionary) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            duration += max(delay, 0.02)
            frames.append(UIImage(cgImage: frame))
        }
        return frames.count > 1 ? UIImage.animatedImage(with: frames, duration: duration) : frames.first
    }
}

/// Code between ``` fences: monospaced, coloured, scrolls sideways, with a copy button.
struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Brand.muted)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Haptics.tap()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.sky)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.05))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeHighlighter.highlight(code))
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
        .background(Color(red: 0.05, green: 0.06, blue: 0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Brand.violet.opacity(0.35)))
    }
}

/// A light highlighter that reads well for most languages: comments, strings, numbers and keywords.
enum CodeHighlighter {
    static let keywords: Set<String> = [
        "let", "var", "const", "func", "fn", "function", "def", "class", "struct", "enum", "impl", "trait", "interface",
        "return", "if", "else", "for", "while", "in", "match", "switch", "case", "break", "continue", "import", "from",
        "pub", "use", "mod", "async", "await", "try", "catch", "throw", "throws", "guard", "self", "Self", "this",
        "true", "false", "nil", "null", "None", "Some", "Ok", "Err", "mut", "static", "public", "private", "new",
        "type", "where", "do", "loop", "and", "or", "not", "elif", "lambda", "pass", "yield", "contract", "mapping",
        "uint", "uint256", "address", "string", "bool", "int", "u64", "i64", "u8", "String", "Vec",
    ]

    static func highlight(_ code: String) -> AttributedString {
        var out = AttributedString()
        let chars = Array(code)
        var i = 0
        func emit(_ s: String, _ color: Color) {
            var piece = AttributedString(s)
            piece.foregroundColor = color
            out += piece
        }
        while i < chars.count {
            let c = chars[i]
            // Comments to the end of the line: // and #
            if (c == "/" && i + 1 < chars.count && chars[i + 1] == "/") || c == "#" {
                var j = i
                while j < chars.count && chars[j] != "\n" { j += 1 }
                emit(String(chars[i..<j]), Color(red: 0.45, green: 0.52, blue: 0.62))
                i = j
            } else if c == "\"" || c == "'" || c == "`" {
                var j = i + 1
                while j < chars.count && chars[j] != c && chars[j] != "\n" {
                    j += chars[j] == "\\" ? 2 : 1
                }
                j = min(j + 1, chars.count)
                emit(String(chars[i..<j]), Color(red: 0.98, green: 0.78, blue: 0.45))
                i = j
            } else if c.isNumber {
                var j = i
                while j < chars.count && (chars[j].isNumber || chars[j] == "." || chars[j] == "_" || chars[j] == "x" || chars[j].isHexDigit) { j += 1 }
                emit(String(chars[i..<j]), Brand.pink)
                i = j
            } else if c.isLetter || c == "_" {
                var j = i
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") { j += 1 }
                let word = String(chars[i..<j])
                let isCall = j < chars.count && chars[j] == "("
                emit(word, keywords.contains(word) ? Brand.violet.opacity(1) : isCall ? Brand.sky : (word.first?.isUppercase == true ? Brand.mint : Brand.text))
                i = j
            } else {
                emit(String(c), Brand.text.opacity(0.85))
                i += 1
            }
        }
        return out
    }
}

/// A person's chat picture: their own, or their initial on a colour of their own.
struct ProfilePicture: View {
    let link: String
    let fallback: String
    let address: String
    var size: CGFloat = 30
    @EnvironmentObject private var storage: StorageStore
    @State private var image: UIImage?

    var body: some View {
        let base = Self.color(for: address)
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [base, base.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(String((fallback.isEmpty ? String(address.dropFirst(5)) : fallback).prefix(1)).uppercased())
                    .font(.system(size: size * 0.43, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.2)))
        .accessibilityHidden(true)
        .task(id: link) {
            image = nil
            guard let parsed = try? EgoShareLink(parsing: link),
                  let url = try? await storage.openShared(parsed) else { return }
            image = await Task.detached { UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 160, height: 160)) }.value
        }
    }

    /// Each address gets its own bright colour, the same everywhere it appears.
    static func color(for address: String) -> Color {
        let hue = Double(address.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.95)
    }
}
