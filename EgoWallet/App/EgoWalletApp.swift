import SwiftUI

@main
struct EgoWalletApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
        .onChange(of: phase) { _, now in
            if now == .background { AppModel.scheduleRefresh() }
        }
        .backgroundTask(.appRefresh(AppModel.refreshTask)) {
            await AppModel.scheduleRefresh()
            await model.backgroundCheck()
        }
    }
}
