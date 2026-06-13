import Foundation
import AppKit
import YibanCheckinCore

/// 将签到流程封装为可在 SwiftUI 中调用的 ObservableObject
@MainActor
final class CheckinManager: ObservableObject {
    @Published var isCheckingIn = false
    @Published var statusMessage = "就绪"
    @Published var lastCheckinTime: String? = nil
    @Published var lastResult: CheckinResult? = nil
    @Published var currentDistance: String? = nil
    @Published var logLines: [String] = []

    enum CheckinResult {
        case success(time: String)
        case failure(reason: String)
        case skipped(reason: String)
    }

    private var config: Config { Config.load() }

    /// 获取下次签到时间
    var nextCheckinTime: String {
        let c = config
        return "每晚 \(String(format: "%02d:%02d", c.checkinStartHour, c.checkinStartMinute))"
    }

    /// 刷新日志
    func refreshLogs() {
        let logPath = Logger.logFile
        if let content = try? String(contentsOf: logPath, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            logLines = lines.suffix(100)
        }
    }

    /// 清空日志
    func clearLogs() {
        let logPath = Logger.logFile
        try? "".write(to: logPath, atomically: true, encoding: .utf8)
        logLines = []
    }

    /// 获取今日签到状态
    func checkTodayStatus() -> String {
        refreshLogs()
        let today = dateString()
        let successLines = logLines.filter { $0.contains(today) && $0.contains("签到成功") }
        if !successLines.isEmpty { return "已签到" }
        let failedLines = logLines.filter { $0.contains(today) && $0.contains("失败") }
        if !failedLines.isEmpty { return "签到失败" }
        return "未签到"
    }

    /// 快速定位
    func refreshLocation() async {
        let locationChecker = LocationChecker(config: config)
        switch await locationChecker.checkIfNearCampus() {
        case .inRange(let d):  currentDistance = "\(String(format: "%.0f", d))m"
        case .outOfRange(let d): currentDistance = "\(String(format: "%.1f", d / 1000))km"
        case .failed: currentDistance = "定位失败"
        }
    }

    /// 执行手动签到
    func performManualCheckin() async {
        isCheckingIn = true
        statusMessage = "正在签到..."
        Logger.info("========== 手动触发签到 ==========")

        let orchestrator = CheckinOrchestrator(config: config, delegate: self)

        do {
            let method = try await orchestrator.performCheckin(wakeDisplay: false)
            let time = timeString()
            lastCheckinTime = time
            lastResult = .success(time: time)
            statusMessage = "\(method) 签到成功"
            Notifier.checkinSuccess(method: method)
        } catch {
            let reason = error.localizedDescription
            lastCheckinTime = timeString()
            lastResult = .failure(reason: reason)
            statusMessage = "失败: \(reason)"
            Logger.error("手动签到失败: \(reason)")
            Notifier.checkinFailed(reason: reason)
        }

        isCheckingIn = false
        refreshLogs()
    }

    private func dateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func timeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }
}

// MARK: - CheckinDelegate

extension CheckinManager: CheckinDelegate {
    nonisolated func checkinDidUpdateStatus(_ message: String) {
        Task { @MainActor in
            self.statusMessage = message
        }
    }
}
