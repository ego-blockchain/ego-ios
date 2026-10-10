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

struct MainTabs: View {
    var body: some View {
        TabView {
            WalletView()
                .tabItem { Label("Wallet", systemImage: "wallet.pass") }
            StorageView()
                .tabItem { Label("Storage", systemImage: "externaldrive.connected.to.line.below") }
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            MarketView()
                .tabItem { Label("Market", systemImage: "arrow.left.arrow.right.circle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
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

    @ViewBuilder static var view: some View {
        switch current {
        case "receive": ReceiveView(address: "egot1yr99jpx3lq7s6m5kt0dz4n8c2w9vfh3g5qvqckfx")
        case "shield": ShieldSheet()
        case "presale": PresaleView()
        case "restore": NavigationStack { ImportWalletView() }
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
