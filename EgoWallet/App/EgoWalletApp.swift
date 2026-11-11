import SwiftUI
import UserNotifications

@main
struct EgoWalletApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    init() {
        UNUserNotificationCenter.current().delegate = NotificationRelay.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { NotificationRelay.shared.model = model }
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
