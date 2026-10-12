import EgoKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.phase {
            case .onboarding:
                OnboardingView()
            case .locked:
                LockView()
            case .ready:
                MainTabs()
            }
        }
        .overlay {
            if scenePhase != .active && model.phase == .ready {
                ZStack {
                    Brand.ink.ignoresSafeArea()
                    EgoMark(size: 72)
                }
            }
        }
        #if DEBUG
        .fullScreenCover(isPresented: .constant(DemoFlow.current != nil)) { DemoFlow.view }
        #endif
        .preferredColorScheme(.dark)
        .tint(Brand.lime)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                model.lock()
            }
        }
    }
}

enum MainTab: Int, CaseIterable {
    case wallet, storage, chat, market, settings

    var title: String {
        switch self {
        case .wallet: "Wallet"
        case .storage: "Storage"
        case .chat: "Chat"
        case .market: "Market"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .wallet: "wallet.pass.fill"
        case .storage: "externaldrive.fill.badge.icloud"
        case .chat: "bubble.left.and.bubble.right.fill"
        case .market: "arrow.left.arrow.right.circle.fill"
        case .settings: "gearshape.fill"
        }
    }

    /// Each section's own colour, as its pages use.
    var tint: Color {
        switch self {
        case .wallet: Brand.lime
        case .storage: Brand.mint
        case .chat: Brand.violet
        case .market: Brand.amber
        case .settings: Brand.sky
        }
    }
}

/// The five sections, side by side: swipe left or right to move between them, or tap the bar.
struct MainTabs: View {
    @EnvironmentObject private var app: AppModel
    /// One storage store for the whole app: Chat and Settings upload through it too.
    @StateObject private var storage = StorageStore()
    @State private var tab: MainTab = .wallet
    @State private var keyboardUp = false

    var body: some View {
        TabView(selection: $tab) {
            WalletView().toolbar(.hidden, for: .tabBar).tag(MainTab.wallet)
            StorageView().toolbar(.hidden, for: .tabBar).tag(MainTab.storage)
            ChatView().toolbar(.hidden, for: .tabBar).tag(MainTab.chat)
            MarketView().toolbar(.hidden, for: .tabBar).tag(MainTab.market)
            SettingsView().toolbar(.hidden, for: .tabBar).tag(MainTab.settings)
        }
        .background(Brand.ink.ignoresSafeArea())
        // A clear sideways swipe moves to the next or previous section. Swipes that start at the
        // left edge are left alone, so they still go back a page.
        .simultaneousGesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .global)
                .onEnded { drag in
                    let dx = drag.translation.width, dy = drag.translation.height
                    let flick = drag.predictedEndTranslation.width
                    guard drag.startLocation.x > 30, abs(dx) > 2.2 * abs(dy), abs(dx) > 90 || abs(flick) > 220 else { return }
                    let next = tab.rawValue + (dx < 0 ? 1 : -1)
                    if let target = MainTab(rawValue: next) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { tab = target }
                    }
                }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Out of the way while typing, so the keyboard sits right under the message box.
            if !keyboardUp {
                EgoTabBar(selection: $tab)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardUp = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardUp = false }
        }
        .onChange(of: tab) { _, _ in
            Haptics.tap()
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .environmentObject(storage)
        .onAppear { storage.attach(app) }
        // Checks the plan on every unlock, so an automatic renewal doesn't wait for the Storage tab.
        .task {
            storage.attach(app)
            await storage.refresh()
        }
        .onChange(of: app.phase) { _, _ in storage.attach(app) }
    }
}

struct EgoTabBar: View {
    @Binding var selection: MainTab
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MainTab.allCases, id: \.self) { tab in
                let on = tab == selection
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .symbolEffect(.bounce, value: on)
                        Text(tab.title)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(on ? tab.tint : Brand.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(tab.tint.opacity(0.14))
                                .matchedGeometryEffect(id: "tab", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.08)))
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }
}

struct LockView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            GlowingMark(size: 92)
                .reveal(0)
            VStack(spacing: 8) {
                Text("Ego Wallet")
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [Brand.text, Brand.lime], startPoint: .leading, endPoint: .trailing))
                    .reveal(0.15)
                Text(shortAddress(model.address))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Brand.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .reveal(0.25)
            }
            if let problem = model.problem {
                ProblemBanner(text: problem).reveal(0)
            }
            Spacer()
            if model.seedMissing {
                Button("Restore wallet") { model.deleteWallet() }
                    .buttonStyle(GlowButtonStyle())
                    .reveal(0.35)
            } else {
                Button {
                    Haptics.tap()
                    Task { await model.unlock() }
                } label: {
                    Label("Unlock", systemImage: "faceid")
                }
                .buttonStyle(GlowButtonStyle())
                .reveal(0.35)
                Text("Quantum-safe · Your keys stay on this iPhone")
                    .font(.caption)
                    .foregroundStyle(Brand.muted.opacity(0.8))
                    .reveal(0.45)
            }
        }
        .padding(24)
        .background(AuroraBackground())
        // The app locks itself on the way to the background. Face ID can only
        // show once it's on screen again, so ask then, not when the lock appears.
        .task {
            if scenePhase == .active {
                await model.unlock()
            } else {
                wasInBackground = true  // Locked on the way out; ask once it's back.
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Only after a real trip to the background: the Face ID sheet
            // itself makes the app briefly inactive, and asking again then
            // would loop after a cancel.
            if phase == .background {
                wasInBackground = true
            } else if phase == .active && wasInBackground {
                wasInBackground = false
                if !model.seedMissing { Task { await model.unlock() } }
            }
        }
    }
}

#if DEBUG
/// Opens one flow straight away for screenshots: launch with `-demo send|receive|shield|presale|restore|done`.
enum DemoFlow {
    static var current: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demo"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var demoFeed: ChatFeed {
        let now = Int64(Date().timeIntervalSince1970)
        func post(_ id: Int, _ from: String, _ name: String, _ body: String, mine: Bool = false, votes: Int = 0, reactions: String = "[]") -> String {
            let until = mine ? "\(now + 1800)" : "null"
            return #"{"id":"p\#(id)","from":"\#(from)","name":"\#(name)","body":"\#(body)","ts":\#(now - Int64(600 - id * 60)),"mine":\#(mine),"edited":false,"change_until":\#(until),"removal_votes":\#(votes),"my_vote":false,"removed_until":null,"reactions":\#(reactions)}"#
        }
        let posts = [
            post(1, "egot1qk2v8xw0a9m3", "Lena", "Just set up a node on my old laptop. Storage page is super clear."),
            post(2, "egot1qk2v8xw0a9m3", "Lena", "Anyone sharing space on testnet yet?"),
            post(3, "egot1zz8y7rp4c2nd", "", "Running two desktops here, 400 GB shared.", reactions: #"[{"emoji":"🔥","count":3,"mine":true},{"emoji":"👍","count":1,"mine":false}]"#),
            post(7, "egot1zz8y7rp4c2nd", "", "Reading the feed from Swift:\\n```swift\\nlet feed = try await client.chatFeed(viewer: me)\\nprint(feed.posts.count) // latest 200\\n```"),
            post(8, "egot1qk2v8xw0a9m3", "Lena", "🎉🎉"),
            post(4, "egot1me00000000000", "Ari", "Same, the phone app picks it up right away 🙌", mine: true),
            post(5, "egot1me00000000000", "Ari", "Delete now removes the copies everywhere too.", mine: true),
            post(6, "egot1spam0000000xx", "", "free coins dm me", votes: 3),
        ].joined(separator: ",")
        let json = #"{"me":"egot1me00000000000","my_name":"Ari","my_removed_until":null,"threshold":5,"ban_days":14,"oldest":null,"posts":[\#(posts)]}"#
        return try! JSONDecoder().decode(ChatFeed.self, from: Data(json.utf8))
    }

    @MainActor @ViewBuilder static var view: some View {
        switch current {
        case "receive": ReceiveView(address: "egot1yr99jpx3lq7s6m5kt0dz4n8c2w9vfh3g5qvqckfx")
        case "shield": ShieldSheet()
        case "presale": PresaleView()
        case "plans": NavigationStack { PlansPage(firstTime: true).navigationTitle("Storage") }.environmentObject(StorageStore())
        case "library": NavigationStack { LibraryView().navigationTitle("Storage") }.environmentObject(StorageStore())
        case "presalecard": VStack { PresaleCard(); Spacer() }.padding(16).screenBackground()
        case "restore": NavigationStack { ImportWalletView() }
        case "market": MarketView()
        case "tabs": MainTabs()
        case "filedetail":
            FileDetailView(file: LibraryFile(file: try! FileCrypto.encrypt(Data(repeating: 7, count: 300_000)), name: "Beach trip.pdf"))
                .environmentObject(StorageStore())
        case "planssheet": NavigationStack { PlansPage(firstTime: false) }.environmentObject(StorageStore())
        case "chat":
            ZStack {
                AuroraBackground(intensity: 0.55, colors: Brand.chatAurora)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ChatIntro(feed: demoFeed)
                        DayDivider(date: Date())
                        ForEach(Array(demoFeed.posts.enumerated()), id: \.element.id) { i, post in
                            ChatBubble(post: post, threshold: 5,
                                       first: i == 0 || demoFeed.posts[i - 1].from != post.from,
                                       last: i + 1 == demoFeed.posts.count || demoFeed.posts[i + 1].from != post.from)
                        }
                    }
                    .padding(12)
                }
            }
            .environmentObject(StorageStore())
        case "done":
            FlowSheet(icon: "arrow.up.right", title: "On its way", step: 2) {
                SuccessBurst(title: "Sent", subtitle: "It shows as pending until the network confirms it.")
                HashCard(hash: "0x7a3f9c2e81d4b6a05f3e2c19d8b7a6f5e4d3c2b1a09f8e7d6c5b4a3928170615")
            } footer: {
                Button("Done") {}.buttonStyle(GlowButtonStyle())
            }
        default: SendView()
        }
    }
}
#endif
