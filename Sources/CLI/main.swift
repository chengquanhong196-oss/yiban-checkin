import Foundation
import AppKit
import YibanCheckinCore

// MARK: - 主入口

Logger.refreshLevel()  // 必须在 Config.load() 之前调用，防止递归
let config = Config.load()
let args = CommandLine.arguments

if args.contains("--inspect") || args.contains("-i") {
    await inspectApp()
} else if args.contains("--config") || args.contains("-c") {
    createConfigTemplate()
} else if args.contains("--test-notify") {
    Notifier.send(title: "易班签到测试", message: "这是一条测试通知")
    Logger.info("测试通知已发送")
} else if args.contains("--diagnose") || args.contains("-d") {
    runDiagnostics()
} else if args.contains("--check-api") {
    await checkAPI()
} else {
    await performCheckinWithRetry()
}

// MARK: - 签到（带重试）

@MainActor
func performCheckinWithRetry() async {
    let bundleID = config.yibanBundleID
    var lastError: String = ""
    var usedMethod = "OCR"
    let orchestrator = CheckinOrchestrator(config: config)

    for attempt in 1...2 {
        do {
            usedMethod = try await orchestrator.performCheckin(wakeDisplay: true)
            Notifier.checkinSuccess(method: usedMethod)
            return
        } catch {
            lastError = error.localizedDescription
            Logger.warn("第 \(attempt) 次失败: \(lastError)")
            // 永久性错误（密码错、不在时段）不重试
            if let apiErr = error as? APIError, apiErr.isPermanent { break }
            if attempt < 2 {
                Logger.info("重启 app 重试...")
                NSRunningApplication.runningApplications(
                    withBundleIdentifier: bundleID
                ).first?.terminate()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
                            cont.resume()
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
    Notifier.checkinFailed(reason: lastError, method: usedMethod)
}

// MARK: - UI 探查模式

@MainActor
func inspectApp() async {
    let bundleID = config.yibanBundleID
    print("🔍 易班 App 窗口探查工具")
    print("================================\n")

    let automator = AppAutomator(config: config)
    let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first

    guard let app = app else {
        print("⚠️  未找到运行中的易班 app")
        print("   Bundle ID: \(bundleID)")
        print("   请先手动打开易班 app，然后重新运行")
        return
    }

    app.activate(options: .activateIgnoringOtherApps)
    try? await Task.sleep(nanoseconds: 1_000_000_000)

    print("📱 App 名称: \(app.localizedName ?? "未知")")
    print("🆔 Bundle ID: \(app.bundleIdentifier ?? "未知")")
    print("📍 PID: \(app.processIdentifier)")

    guard let (_, frame) = automator.getAppWindow(app: app) else {
        print("\n❌ 无法获取窗口信息")
        return
    }

    print("\n🪟 窗口信息:")
    print("   位置: (\(Int(frame.origin.x)), \(Int(frame.origin.y)))")
    print("   大小: \(Int(frame.width)) x \(Int(frame.height))")
    print("   中心: (\(Int(frame.midX)), \(Int(frame.midY)))")

    print("\n--- OCR 文字识别 (\(frame.width)x\(frame.height)) ---")
    print("正在对窗口截图并识别所有文字...\n")

    let allTexts = automator.findAllText(inWindow: frame)
    let sorted = allTexts.sorted { $0.point.y < $1.point.y }
    print("识别到 \(sorted.count) 个文本区域:\n")
    for item in sorted {
        let y = Int(item.point.y - frame.origin.y)
        let x = Int(item.point.x - frame.origin.x)
        print("  [y=\(String(format: "%4d", y)), x=\(String(format: "%3d", x))]  \"\(item.text)\"")
    }

    print("\n--- 关键词搜索 ---")
    for text in ["校本化", "晚点签到", "签到", "福州大学", "登录", "首页"] {
        if let point = automator.findText(text, inWindow: frame, fuzzy: false) {
            print("  ✅ \"\(text)\" → (\(Int(point.x - frame.origin.x)), \(Int(point.y - frame.origin.y)))")
        } else {
            print("  ❌ \"\(text)\" → 未找到")
        }
    }
    print("\n========================================")
    print("探查完成。")

    print("\n--- 当前配置 ---")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(config), let json = String(data: data, encoding: .utf8) {
        print(json)
    }
}

// MARK: - 诊断模式

func runDiagnostics() {
    print("🔍 系统诊断")
    print("================================\n")

    let result = PermissionChecker.runDiagnostics(config: config)

    let status = { (ok: Bool) -> String in ok ? "✅" : "❌" }
    print("\(status(result.accessibilityOK)) 辅助功能权限")
    print("\(status(result.locationOK)) 定位权限")
    print("\(status(result.configOK)) 账号密码配置")
    print("\(status(result.canLaunchApp)) 易班 App 已安装")

    if !result.issues.isEmpty {
        print("\n⚠️ 待处理:")
        for issue in result.issues {
            print("  • \(issue)")
        }
    } else {
        print("\n✅ 一切就绪，可以签到")
    }

    print("\n--- 当前配置 ---")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(config), let json = String(data: data, encoding: .utf8) {
        print(json)
    }
}

// MARK: - API 连通性检查

@MainActor
func checkAPI() async {
    print("🌐 API 连通性检查")
    print("================================\n")

    guard !config.yibanUsername.isEmpty, !config.yibanPassword.isEmpty else {
        print("❌ 未配置手机号或密码")
        return
    }

    let cfg = config  // 捕获 MainActor 值
    print("📱 手机号: \(cfg.yibanUsername.prefix(3))****\(cfg.yibanUsername.suffix(4))")
    print("⏳ 正在登录...")

    let api = YibanAPI(config: cfg)
    do {
        let loggedIn = try await api.login()
        if loggedIn {
            print("✅ 登录成功")
            print("⏳ 正在获取签到时段...")
            do {
                let result = try await api.performEveningCheckin()
                print("✅ 签到测试: \(result)")
            } catch {
                print("⚠️ 签到失败: \(error.localizedDescription)")
                print("   （如果提示不在时段，说明 API 流程正常）")
            }
        } else {
            print("❌ 登录失败")
        }
    } catch {
        print("❌ \(error.localizedDescription)")
    }
    print("\n================================")
}

// MARK: - 配置模板

func createConfigTemplate() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let defaultConfig = Config()
    if let data = try? encoder.encode(defaultConfig), let json = String(data: data, encoding: .utf8) {
        print(json)
    }
}
