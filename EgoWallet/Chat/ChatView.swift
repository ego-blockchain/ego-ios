import EgoKit
import SwiftUI

@MainActor
final class ChatModel: ObservableObject {
    @Published var feed: ChatFeed?
    @Published var problem: String?
    @Published var sending = false

    func load(_ app: AppModel) async {
        let viewer = app.address
        do {
            feed = try await app.perform { try await $0.chatFeed(viewer: viewer) }
            problem = nil
        } catch {
            problem = app.message(for: error)
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
            try await app.perform { try await $0.chatSubmit(wire) }
            await load(app)
            return true
        } catch {
            problem = app.message(for: error)
            return false
        }
    }
}

struct ChatView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var chat = ChatModel()
    @State private var draft = ""
    @State private var naming = false
    @State private var nameDraft = ""
    @State private var editing: ChatPostView?
    @State private var editDraft = ""
    @State private var voteTarget: ChatPostView?
    @State private var deleteTarget: ChatPostView?

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
                                               first: !sameRun(previous, post), last: !sameRun(post, following))
                                        .id(post.id)
                                        .contextMenu { menu(for: post) }
                                }
                            } else {
                                ProgressView().tint(Brand.sky).frame(maxWidth: .infinity).padding(.top, 60)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: chat.feed?.posts.last?.id) { _, last in
                        if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                    }
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
                    Button {
                        nameDraft = chat.feed?.myName ?? ""
                        naming = true
                    } label: {
                        Label(chat.feed?.myName.isEmpty == false ? chat.feed?.myName ?? "" : "Set name", systemImage: "person.crop.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.system(.footnote, design: .rounded, weight: .bold))
                            .foregroundStyle(Brand.text)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Brand.violet.opacity(0.25), in: Capsule())
                            .overlay(Capsule().stroke(Brand.violet.opacity(0.5)))
                    }
                    .accessibilityLabel("Your name in the chat")
                }
            }
            .alert("Your name in the chat", isPresented: $naming) {
                TextField("Name", text: $nameDraft)
                Button("Save") { Task { await saveName() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Up to 24 characters. Your address is always shown next to it.")
            }
            .alert("Edit message", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Message", text: $editDraft)
                Button("Save") { Task { await saveEdit() } }
                Button("Cancel", role: .cancel) { editing = nil }
            } message: {
                Text("You can change a message for one hour after posting it.")
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
                Button("Delete", role: .destructive) { Task { await delete() } }
            } message: {
                Text("It disappears for everyone.")
            }
            .task {
                while !Task.isCancelled {
                    await chat.load(app)
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
    }

    private func day(_ ts: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

    /// Messages from one person within five minutes read as one run of bubbles.
    private func sameRun(_ a: ChatPostView?, _ b: ChatPostView?) -> Bool {
        guard let a, let b else { return false }
        return a.from == b.from && abs(b.ts - a.ts) < 300 && Calendar.current.isDate(day(a.ts), inSameDayAs: day(b.ts))
    }

    @ViewBuilder
    private func menu(for post: ChatPostView) -> some View {
        Button {
            UIPasteboard.general.string = post.body
        } label: {
            Label("Copy text", systemImage: "doc.on.doc")
        }
        if post.mine, let until = post.changeUntil, until > Int64(Date().timeIntervalSince1970) {
            Button {
                editDraft = post.body
                editing = post
            } label: {
                Label("Edit", systemImage: "pencil")
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

    private var composer: some View {
        VStack(spacing: 4) {
            if let until = chat.feed?.myRemovedUntil {
                Label("Community votes removed you from the chat until \(Date(timeIntervalSince1970: TimeInterval(until)).formatted(date: .abbreviated, time: .omitted)).", systemImage: "hand.raised.fill")
                    .font(.footnote)
                    .foregroundStyle(Brand.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Brand.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                let ready = !chat.sending && ChatRules.cleanBody(draft) != nil
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message everyone…", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .foregroundStyle(Brand.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                    Button {
                        Haptics.tap()
                        Task { await post() }
                    } label: {
                        Group {
                            if chat.sending {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "arrow.up").font(.system(size: 16, weight: .heavy))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(ready || chat.sending ? AnyShapeStyle(Brand.chatGlow) : AnyShapeStyle(Color.white.opacity(0.1)), in: Circle())
                        .shadow(color: ready ? Brand.violet.opacity(0.5) : .clear, radius: 8)
                    }
                    .disabled(!ready)
                    .padding(5)
                    .accessibilityLabel("Send")
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(LinearGradient(colors: [Brand.violet.opacity(0.6), Brand.sky.opacity(0.3)], startPoint: .leading, endPoint: .trailing))
                )
                let used = draft.unicodeScalars.count
                if used > ChatRules.maxBodyCharacters - 60 {
                    Text("\(used)/\(ChatRules.maxBodyCharacters)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(used > ChatRules.maxBodyCharacters ? Brand.danger : Brand.muted)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 12)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func post() async {
        guard let text = ChatRules.cleanBody(draft) else { return }
        let name = chat.feed?.myName ?? ""
        if await chat.submit(app, { key, now in .post(try ChatSigner.post(key: key, name: name, body: text, ts: now)) }) {
            draft = ""
        }
    }

    private func saveName() async {
        guard let name = ChatRules.cleanName(nameDraft) else {
            chat.problem = "A name can be at most \(ChatRules.maxNameCharacters) characters."
            return
        }
        _ = await chat.submit(app, { key, now in .name(try ChatSigner.name(key: key, name: name, ts: now)) })
    }

    private func saveEdit() async {
        guard let post = editing, let text = ChatRules.cleanBody(editDraft) else { return }
        editing = nil
        _ = await chat.submit(app, { key, now in .edit(try ChatSigner.edit(key: key, postId: post.id, postTs: post.ts, body: text, ts: now)) })
    }

    private func delete() async {
        guard let post = deleteTarget else { return }
        deleteTarget = nil
        _ = await chat.submit(app, { key, now in .delete(try ChatSigner.delete(key: key, postId: post.id, postTs: post.ts, ts: now)) })
    }

    private func vote() async {
        guard let post = voteTarget else { return }
        voteTarget = nil
        _ = await chat.submit(app, { key, now in .vote(try ChatSigner.vote(key: key, target: post.from, ts: now)) })
    }
}

/// What this chat is and how it keeps itself civil.
struct ChatIntro: View {
    let feed: ChatFeed

    var body: some View {
        let people = Set(feed.posts.map(\.from)).count
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(Brand.chatGlow, in: Circle())
                .shadow(color: Brand.violet.opacity(0.5), radius: 16)
            Text("Everyone on Ego")
                .font(.system(.title3, design: .rounded, weight: .heavy))
                .foregroundStyle(Brand.text)
            HStack(spacing: 8) {
                pill("\(people) \(people == 1 ? "person" : "people") here", icon: "person.2.fill", tint: Brand.sky)
                pill("Signed by each wallet", icon: "signature", tint: Brand.violet)
            }
            Text("Anyone can read this. \(feed.threshold) removal votes within \(feed.banDays) days remove someone for \(feed.banDays) days. Hold a message to copy, edit or vote.")
                .font(.caption)
                .foregroundStyle(Brand.muted)
                .multilineTextAlignment(.center)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial.opacity(0.45), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(LinearGradient(colors: [Brand.violet.opacity(0.5), Brand.sky.opacity(0.1)], startPoint: .top, endPoint: .bottom))
        )
        .padding(.top, 8)
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
struct ChatBubble: View {
    let post: ChatPostView
    let threshold: Int
    /// First and last of a run from the same person.
    let first: Bool
    let last: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if post.mine {
                Spacer(minLength: 56)
            } else {
                ChatAvatar(post: post).opacity(last ? 1 : 0)
            }
            VStack(alignment: post.mine ? .trailing : .leading, spacing: 3) {
                if first && !post.mine {
                    HStack(spacing: 6) {
                        Text(post.name.isEmpty ? shortAddress(post.from) : post.name)
                            .font(.system(.caption, design: .rounded, weight: .heavy))
                            .foregroundStyle(ChatAvatar.color(for: post.from))
                        if !post.name.isEmpty {
                            Text(shortAddress(post.from))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Brand.muted)
                        }
                    }
                    .padding(.leading, 6)
                }
                Text(post.body)
                    .font(.body)
                    .foregroundStyle(post.mine ? .white : Brand.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(bubbleFill, in: shape)
                    .overlay(shape.stroke(post.mine ? Color.clear : Color.white.opacity(0.08)))
                if last || post.edited {
                    Text(relativeTime(post.ts) + (post.edited ? " · edited" : ""))
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
            if !post.mine { Spacer(minLength: 56) }
        }
        .padding(.top, first ? 8 : 0)
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

struct ChatAvatar: View {
    let post: ChatPostView

    var body: some View {
        let base = Self.color(for: post.from)
        Circle()
            .fill(LinearGradient(colors: [base, base.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 30, height: 30)
            .overlay(
                Text(String((post.name.isEmpty ? String(post.from.dropFirst(5)) : post.name).prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            )
            .overlay(Circle().stroke(Color.white.opacity(0.2)))
            .accessibilityHidden(true)
    }

    /// Each address gets its own bright color, the same everywhere it appears.
    static func color(for address: String) -> Color {
        let hue = Double(address.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.95)
    }
}
