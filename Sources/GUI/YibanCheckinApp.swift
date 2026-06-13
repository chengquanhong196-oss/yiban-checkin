import SwiftUI
import YibanCheckinCore

@main
struct YibanCheckinApp: App {
    @StateObject private var checkinManager = CheckinManager()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    private let statusTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some Scene {
        WindowGroup("易班签到") {
            if hasCompletedOnboarding {
                ContentView()
                    .environmentObject(checkinManager)
                    .frame(minWidth: 640, minHeight: 480)
                    .onReceive(statusTimer) { _ in
                        MenuBarController.shared.periodicRefresh()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .showMainWindow)) { _ in
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                    }
            } else {
                OnboardingView()
            }
        }
        .defaultSize(width: 720, height: 520)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])
    }

    init() {
        Logger.refreshLevel()  // 先初始化日志级别，防止递归
        _ = MenuBarController.shared
        _ = AppUpdater.shared
        MenuBarController.shared.periodicRefresh()

        if shouldCheckForUpdatesToday() {
            AppUpdater.shared.checkInBackground()
        }
    }

    private func shouldCheckForUpdatesToday() -> Bool {
        guard let last = AppUpdater.shared.lastCheckDate else { return true }
        return !Calendar.current.isDate(last, inSameDayAs: Date())
    }
}
