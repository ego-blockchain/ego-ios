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
    @State private var shown: MainTab? = MainTabs.startTab
    private static var startTab: MainTab {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count,
           let t = MainTab.allCases.first(where: { $0.title.lowercased() == args[i + 1] }) { return t }
        #endif
        return .wallet
    }
    @State private var keyboardUp = false
    /// Pages open over the tabs, such as Earnings, Chat profile and market offers.
    @State private var path = NavigationPath()
    /// The section the pager last came to rest on.
    @State private var settled: MainTab = MainTabs.startTab

    private var tab: Binding<MainTab> {
        Binding(get: { shown ?? .wallet }, set: { next in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) { shown = next }
        })
    }

    @ViewBuilder private func page(_ section: MainTab) -> some View {
        switch section {
        case .wallet: WalletView()
        case .storage: StorageView()
        case .chat: ChatView()
        case .market: MarketView()
        case .settings: SettingsView()
        }
    }

    var body: some View {
        // The five sections side by side. Pages follow the finger and settle one at a time;
        // a sideways strip inside a page (filters, coins, emoji) scrolls first.
        // The five sections side by side: a swipe drags both pages and settles on one, and sideways
        // strips inside a page (filters, coins, emoji) scroll on their own first. The main pages draw
        // their own titles, so the pager's trouble with navigation bars doesn't arise.
        // Pages open over the whole pager, tab bar included. Navigation kept inside the pager
        // lost track of pages closed with Back, so they opened once and came back later.
        NavigationStack(path: $path) {
            TabView(selection: tab) {
                ForEach(MainTab.allCases, id: \.self) { section in
                    page(section).tag(section)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Out of the way while typing, so the keyboard sits right under the message box.
                if !keyboardUp {
                    EgoTabBar(selection: tab)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: WalletPage.self) { page in
                switch page {
                case .earnings: EarningsView()
                }
            }
            .navigationDestination(for: ProfilePage.self) { _ in ChatProfileView() }
            .navigationDestination(for: OfferPage.self) { page in
                OfferDetailView(listing: page.listing, egocUsd: page.egocUsd, mine: page.mine)
            }
        }
        #if DEBUG
        .task {
            if path.isEmpty, ProcessInfo.processInfo.arguments.contains("-openEarnings") { path.append(WalletPage.earnings) }
        }
        #endif
        .background(Brand.ink.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardUp = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardUp = false }
        }
        .onChange(of: shown) { _, now in
            // Only a real move to another section counts. The pager re-reports its page when its size
            // changes, as when the keyboard opens and the tab bar hides, and that must not close the keyboard.
            guard let now, now != settled else { return }
            settled = now
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
    /// Its height above the home indicator: the buttons and their padding.
    static let height: CGFloat = 60

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
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
        // A solid footer: pages end above it instead of showing through.
        .frame(maxWidth: .infinity)
        .background(Brand.card.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }
}

/// Two people sending Ego to each other: coins rise from her phone and arc over to his.
struct ConnectionScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Where the phones are, and the top of the arc, as fractions of the picture.
    private let from = CGPoint(x: 0.335, y: 0.62)
    private let to = CGPoint(x: 0.705, y: 0.655)
    private let peak = CGPoint(x: 0.52, y: 0.16)
    private let gold = Color(red: 1.0, green: 0.85, blue: 0.45)
    private let coins = 5

    var body: some View {
        // Drawn on a canvas over the picture: nothing here feeds back into layout.
        Image("LockPair")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                    let t = reduceMotion ? 0.5 : context.date.timeIntervalSinceReferenceDate
                    Canvas { g, size in
                        var glow = g
                        glow.addFilter(.blur(radius: 8))
                        glow.stroke(arc(size), with: .color(gold.opacity(0.25)), lineWidth: 10)
                        for k in 0..<3 {
                            g.stroke(arc(size, lift: CGFloat(k - 1) * 0.045), with: .color(gold.opacity(0.8)),
                                     style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [1.5, 8], dashPhase: CGFloat(-t * 28) + CGFloat(k * 5)))
                        }
                        guard let coin = g.resolveSymbol(id: 0) else { return }
                        for i in 0..<coins {
                            let p = reduceMotion ? Double(i + 1) / Double(coins + 1)
                                : (t * 0.2 + Double(i) / Double(coins)).truncatingRemainder(dividingBy: 1)
                            let side = size.width * (0.05 + 0.03 * sin(.pi * p))
                            let at = point(p, size)
                            var layer = g
                            layer.opacity = min(1, min(p, 1 - p) * 7)
                            layer.draw(coin, in: CGRect(x: at.x - side / 2, y: at.y - side / 2, width: side, height: side))
                        }
                    } symbols: {
                        EgoCoin(size: 60).tag(0)
                    }
                }
            }
            // The picture is cut at their waists: fade that edge.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .accessibilityElement()
            .accessibilityLabel("Two people sending Ego to each other")
    }

    private func point(_ p: Double, _ size: CGSize, lift: CGFloat = 0) -> CGPoint {
        let q = 1 - p
        let x = q * q * from.x + 2 * q * p * peak.x + p * p * to.x
        let y = q * q * from.y + 2 * q * p * (peak.y + lift) + p * p * to.y
        return CGPoint(x: x * size.width, y: y * size.height)
    }

    private func arc(_ size: CGSize, lift: CGFloat = 0) -> Path {
        Path { path in
            path.move(to: CGPoint(x: from.x * size.width, y: from.y * size.height))
            path.addQuadCurve(to: CGPoint(x: to.x * size.width, y: to.y * size.height),
                              control: CGPoint(x: peak.x * size.width, y: (peak.y + lift) * size.height))
        }
    }
}

/// An Ego coin: the mark on a dark disc with a warm rim.
struct EgoCoin: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.07, green: 0.07, blue: 0.09))
            Image("EgoMark")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(size * 0.2)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color(red: 1.0, green: 0.85, blue: 0.45).opacity(0.8), lineWidth: max(1, size * 0.05)))
        .shadow(color: Color(red: 1.0, green: 0.8, blue: 0.4).opacity(0.7), radius: size * 0.3)
    }
}

struct LockView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ConnectionScene()
                .frame(maxWidth: .infinity)
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
        case "lock": LockView()
        case "scene": VStack { Spacer(); ConnectionScene(); Spacer() }.background(Brand.ink)
        case "market": NavigationStack { MarketView() }
        case "earnings": DemoPush { EarningsView() }
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

/// Opens a page the way the tabs do: from a root with the bar hidden.
struct DemoPush<Page: View>: View {
    @ViewBuilder var page: () -> Page
    @State private var pushed = false

    var body: some View {
        NavigationStack {
            Color.clear.screenBackground()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $pushed) { page() }
                .task { pushed = true }
        }
    }
}
