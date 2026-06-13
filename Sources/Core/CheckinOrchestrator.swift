import Foundation
import AppKit

// MARK: - 统一签到编排器（CLI 和 GUI 共用一个实现）

/// 签到过程中的状态回调
public protocol CheckinDelegate: AnyObject {
    func checkinDidUpdateStatus(_ message: String)
}

/// 默认空实现（CLI 模式不需要实时状态）
public extension CheckinDelegate {
    func checkinDidUpdateStatus(_ message: String) {}
}

public final class CheckinOrchestrator {
    private let config: Config
    private weak var delegate: CheckinDelegate?

    public init(config: Config, delegate: CheckinDelegate? = nil) {
        self.config = config
        self.delegate = delegate
    }

    private func status(_ msg: String) {
        Logger.info(msg)
        delegate?.checkinDidUpdateStatus(msg)
    }

    // MARK: - 主入口

    /// 执行签到，成功返回方法名（"API" 或 "OCR"），失败 throw
    @MainActor
    public func performCheckin(wakeDisplay: Bool = true) async throws -> String {
        Logger.info("========== 开始签到流程 ==========")

        // 仅 CLI 模式需要唤醒屏幕
        var caffeinate: Process?
        if wakeDisplay {
            caffeinate = Self.wakeDisplayProcess()
        }
        defer { caffeinate?.terminate() }

        let method = config.checkinMethod

        // ——— API 方式（非纯 OCR 模式） ———
        if method != "ocr" {
            do {
                status("[API] 尝试 API 签到...")
                let api = YibanAPI(config: config)
                if try await api.login() {
                    _ = try await api.performEveningCheckin()
                    Logger.success("========== API 签到成功 ==========")
                    return "API"
                }
            } catch {
                let msg = error.localizedDescription
                Logger.warn("API 签到失败: \(msg)")
                if method == "api" { throw error }
                // 不可恢复的错误（密码错误、不在时段等）→ 不转 OCR
                if let apiErr = error as? APIError, apiErr.isPermanent {
                    Logger.info("API 永久性错误，不转 OCR")
                    throw error
                }
                status("[API] 失败，转 OCR: \(msg)")
            }
        }

        // ——— OCR 方式 ———
        status("[OCR] 开始 OCR 签到...")
        try await performOCRSignIn()
        Logger.success("========== OCR 签到成功 ==========")
        return "OCR"
    }

    // MARK: - OCR 签到流程

    @MainActor
    private func performOCRSignIn() async throws {
        // 清理残留对话框
        let cleanup = Process()
        cleanup.launchPath = "/usr/bin/osascript"
        cleanup.arguments = ["-e", "try\n  tell application \"System Events\" to keystroke return\nend try"]
        cleanup.standardOutput = FileHandle.nullDevice
        cleanup.standardError = FileHandle.nullDevice
        try? cleanup.run()

        let automator = AppAutomator(config: config)

        // Step 1: 定位
        status("[1/5] 检查定位...")
        let locationChecker = LocationChecker(config: config)
        switch await locationChecker.checkIfNearCampus() {
        case .inRange(let d):
            Logger.success("位置确认: 在校园 \(String(format: "%.0f", d))m 范围内")
        case .outOfRange(let d):
            Logger.info("不在校园范围内，跳过签到")
            throw AppError.buttonDisabled("距校区 \(String(format: "%.1f", d / 1000))km")
        case .failed(let msg):
            Logger.warn("定位失败: \(msg)，跳过定位检查继续签到")
        }

        // Step 2: 启动
        status("[2/5] 启动易班 app...")
        let app = try automator.launchApp()

        // Step 3: 窗口
        status("[3/5] 获取 app 窗口...")
        let windowFrame = try automator.waitForWindow(app: app)

        // Step 4: 登录 + 导航
        status("[4/5] 检查登录状态并导航...")
        try await navigateToCheckin(automator: automator, windowFrame: windowFrame)

        // Step 5: 签到
        automator.dismissAnyDialog(inWindow: windowFrame)
        status("[5/5] 点击签到按钮...")
        try automator.withRetry("点击签到") {
            try automator.clickCheckinButton(inWindow: windowFrame)
        }
    }

    // MARK: - 导航流程

    @MainActor
    private func navigateToCheckin(automator: AppAutomator, windowFrame: CGRect) async throws {
        automator.dismissAnyDialog(inWindow: windowFrame)

        // 先尝试返回离开异常页面
        for i in 1...3 {
            let pg = automator.detectPage(inWindow: windowFrame)
            if pg != .unknown, pg != .abnormal { break }
            status("页面异常，尝试返回 (\(i)/3)...")
            automator.goBack(inWindow: windowFrame)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            automator.dismissAnyDialog(inWindow: windowFrame)
        }

        // 检查登录
        automator.dumpPage(inWindow: windowFrame)
        if automator.checkLoginNeeded(inWindow: windowFrame) {
            status("正在登录...")
            try automator.performLogin(inWindow: windowFrame)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            automator.dismissAnyDialog(inWindow: windowFrame)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        } else {
            Logger.info("无需登录，已保持登录状态")
        }

        // 登录后检测
        var page = automator.detectPage(inWindow: windowFrame)
        if page == .login {
            Logger.error("登录后仍在登录页，登录失败")
            throw AppError.buttonDisabled("登录失败，请检查手机号和密码是否正确")
        }

        // 不在已知导航页就返回
        if page != .home && page != .schoolPortal && page != .workbench && page != .checkin {
            status("登录后在非导航页，返回首页...")
            for _ in 1...3 {
                automator.goBack(inWindow: windowFrame)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                automator.dismissAnyDialog(inWindow: windowFrame)
                page = automator.detectPage(inWindow: windowFrame)
                if page == .home { break }
            }
            if page != .home && page != .schoolPortal && page != .workbench && page != .checkin {
                page = .home
            }
        }

        // 最后兜底
        var backAttempts = 0
        while (page == .unknown || page == .login || page == .abnormal) && backAttempts < 2 {
            status("页面仍异常，再试返回...")
            automator.goBack(inWindow: windowFrame)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            automator.dismissAnyDialog(inWindow: windowFrame)
            page = automator.detectPage(inWindow: windowFrame)
            backAttempts += 1
        }

        automator.dumpPage(inWindow: windowFrame)
        Logger.info("最终页面: \(page)")

        // 按页面层级逐步导航
        do {
            switch page {
            case .home:
                status("导航: 首页 → 我的学校")
                try automator.withRetry("我的学校") { try automator.enterMySchool(inWindow: windowFrame) }
                fallthrough
            case .schoolPortal:
                status("导航: → 校本化")
                try automator.withRetry("校本化") { try automator.enterSchoolPortal(inWindow: windowFrame) }
                fallthrough
            case .workbench:
                status("导航: → 晚点签到")
                try automator.withRetry("晚点签到") { try automator.enterEveningCheckin(inWindow: windowFrame) }
                fallthrough
            case .checkin:
                break  // 已在签到页，由调用方点按钮
            default:
                status("未知页面，尝试完整流程...")
                try automator.withRetry("我的学校") { try automator.enterMySchool(inWindow: windowFrame) }
                try automator.withRetry("校本化") { try automator.enterSchoolPortal(inWindow: windowFrame) }
                try automator.withRetry("晚点签到") { try automator.enterEveningCheckin(inWindow: windowFrame) }
            }
        } catch {
            Logger.error("导航失败(页面=\(page)): \(error.localizedDescription)")
            automator.dumpPage(inWindow: windowFrame)
            throw error
        }
    }

    // MARK: - 屏幕唤醒（仅 CLI 用）

    @MainActor
    public static func wakeDisplayProcess() -> Process? {
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: CGPoint(x: 1, y: 1), mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
        let p = Process()
        p.launchPath = "/usr/bin/caffeinate"
        p.arguments = ["-d", "-t", "90"]
        try? p.run()
        Logger.info("屏幕已唤醒，防显示休眠已开启")
        return p
    }
}
