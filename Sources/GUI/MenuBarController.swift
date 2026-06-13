import SwiftUI
import AppKit
import YibanCheckinCore

/// 菜单栏控制器 — 提供状态图标 + 下拉菜单 + 快速操作
@MainActor
final class MenuBarController: ObservableObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var menu: NSMenu?

    @Published var todayStatus: String = "未签到"
    @Published var isCheckingIn = false

    private init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildStatusIcon()
        buildMenu()
    }

    // MARK: - 图标

    private func buildStatusIcon() {
        guard let button = statusItem.button else { return }
        // 使用 SF Symbol，不同状态不同颜色
        updateIcon()
        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        let title: String
        let color: NSColor

        switch todayStatus {
        case "已签到":
            symbol = "checkmark.circle.fill"; title = "✓"
            color = .systemGreen
        case "签到失败":
            symbol = "exclamationmark.circle.fill"; title = "✗"
            color = .systemOrange
        case "签到中…":
            symbol = "arrow.triangle.2.circlepath"; title = "⟳"
            color = .systemBlue
        default:
            symbol = "circle"; title = "易"
            color = .secondaryLabelColor
        }

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: todayStatus)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) {
            image.isTemplate = true
            button.image = image
            button.contentTintColor = color
        }
        button.attributedTitle = NSAttributedString(
            string: " \(title) ",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                         .foregroundColor: color]
        )
        button.toolTip = "易班签到 — \(todayStatus)"
    }

    // MARK: - 菜单

    private func buildMenu() {
        menu = NSMenu()
        menu?.addItem(NSMenuItem(title: "状态: \(todayStatus)", action: nil, keyEquivalent: ""))
        menu?.addItem(.separator())

        let checkinItem = NSMenuItem(title: "立即签到", action: #selector(manualCheckin), keyEquivalent: "c")
        checkinItem.target = self
        menu?.addItem(checkinItem)

        let showItem = NSMenuItem(title: "打开面板…", action: #selector(showPanel), keyEquivalent: "o")
        showItem.target = self
        menu?.addItem(showItem)

        menu?.addItem(.separator())
        menu?.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
    }

    private func updateMenu() {
        menu?.item(at: 0)?.title = "状态: \(todayStatus)"
    }

    // MARK: - 动作

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        guard let menu = menu else { return }

        // 刷新状态
        refreshStatus()
        updateIcon()
        updateMenu()

        // 显示菜单
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil  // 恢复点击事件由 action 处理
    }

    /// 手动签到（从菜单栏触发）
    @objc func manualCheckin() {
        guard !isCheckingIn else { return }
        Task {
            isCheckingIn = true
            todayStatus = "签到中…"
            updateIcon()

            do {
                let config = Config.load()
                let orchestrator = CheckinOrchestrator(config: config)
                let method = try await orchestrator.performCheckin(wakeDisplay: true)
                todayStatus = "已签到"
                Notifier.checkinSuccess(method: method)
            } catch {
                todayStatus = "签到失败"
                Notifier.checkinFailed(reason: error.localizedDescription)
            }

            isCheckingIn = false
            updateIcon()
            updateMenu()
        }
    }

    @objc private func showPanel() {
        // 激活主窗口
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 如果窗口已关闭，重新打开
        if NSApp.windows.isEmpty {
            // 发送打开窗口的通知
            NotificationCenter.default.post(name: .showMainWindow, object: nil)
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 公开方法

    func refreshStatus() {
        let logPath = Logger.logFile
        guard let content = try? String(contentsOf: logPath, encoding: .utf8) else {
            todayStatus = "未签到"
            return
        }

        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        let lines = content.components(separatedBy: "\n")

        if lines.contains(where: { $0.contains(today) && $0.contains("签到成功") }) {
            todayStatus = "已签到"
        } else if lines.contains(where: { $0.contains(today) && ($0.contains("失败") || $0.contains("ERROR")) }) {
            todayStatus = "签到失败"
        } else {
            todayStatus = "未签到"
        }
    }

    /// 用于 timer 定期刷新
    func periodicRefresh() {
        refreshStatus()
        updateIcon()
        updateMenu()
    }
}

// MARK: - Notification

extension Notification.Name {
    static let showMainWindow = Notification.Name("showMainWindow")
    static let openSettings = Notification.Name("openSettings")
}
