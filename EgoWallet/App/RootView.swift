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
        VStack(spacing: 24) {
            Spacer()
            EgoMark(size: 72)
            VStack(spacing: 6) {
                Text("Ego Wallet")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(Brand.text)
                Text(shortAddress(model.address))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Brand.muted)
            }
            if let problem = model.problem {
                ProblemBanner(text: problem)
            }
            Spacer()
            if model.seedMissing {
                Button("Restore wallet") { model.deleteWallet() }
                    .buttonStyle(PrimaryButtonStyle())
            } else {
                Button("Unlock") {
                    Task { await model.unlock() }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .screenBackground()
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
