import Foundation
import AppKit
import Vision

// MARK: - App 自动化模块 (Vision OCR + CGEvent)

public final class AppAutomator {
    private let config: Config
    private let screenCapture: ScreenCapture
    private lazy var verificationSolver: VerificationSolver = {
        VerificationSolver(
            ocr: { [weak self] frame in self?.findAllText(inWindow: frame) ?? [] },
            captureRegion: { [weak self] rect in self?.screenCapture.captureRegion(rect) },
            click: { [weak self] point in self?.click(at: point) ?? false }
        )
    }()

    public init(config: Config) {
        self.config = config
        self.screenCapture = ScreenCapture()
    }

    // MARK: - 启动/激活 App

    public func launchApp() throws -> NSRunningApplication {
        Logger.info("正在启动易班 app...")

        let runningApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: config.yibanBundleID
        )

        if let app = runningApps.first {
            Logger.info("易班已在运行，激活中 (PID: \(app.processIdentifier))")
            app.activate(options: .activateIgnoringOtherApps)
            Thread.sleep(forTimeInterval: config.stepDelay)
            return app
        }

        Logger.info("易班未运行，正在启动...")
        let bundleIDs = [config.yibanBundleID, "cn.yiban.mainAPP", "com.yiban.app", "com.yiban.www"]
        var appURL: URL?
        for bid in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                appURL = url; break
            }
        }
        guard let url = appURL else { throw AppError.appNotFound }

        let semaphore = DispatchSemaphore(value: 0)
        var launchedApp: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: url,
            configuration: { let c = NSWorkspace.OpenConfiguration(); c.activates = true; return c }()) { app, error in
            launchedApp = app
            semaphore.signal()
        }
        semaphore.wait()

        guard let app = launchedApp else { throw AppError.launchFailed }
        Logger.info("易班已启动 (PID: \(app.processIdentifier))")
        Thread.sleep(forTimeInterval: config.stepDelay)
        return app
    }

    // MARK: - 窗口操作

    public func getAppWindow(app: NSRunningApplication) -> (pid: Int32, frame: CGRect)? {
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == app.processIdentifier,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"],
                  w > 100, h > 100 else { continue }

            let layer = window[kCGWindowLayer as String] as? Int32 ?? 99
            if layer > 24 { continue }

            if let wid = window[kCGWindowNumber as String] as? CGWindowID {
                screenCapture.currentWindowID = wid
            }

            let frame = CGRect(x: x, y: y, width: w, height: h)
            Logger.info("找到窗口: (x:\(Int(x)), y:\(Int(y)), w:\(Int(w)), h:\(Int(h)))")
            return (ownerPID, frame)
        }

        Logger.warn("未找到 app 窗口")
        return nil
    }

    public func waitForWindow(app: NSRunningApplication, timeout: TimeInterval? = nil) throws -> CGRect {
        let deadline = Date().addingTimeInterval(timeout ?? config.uiTimeout)
        while Date() < deadline {
            if let (_, frame) = getAppWindow(app: app) { return frame }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw AppError.timeout("等待窗口出现超时")
    }

    // MARK: - OCR 文字识别（使用 screenCapture）

    public func findAllText(inWindow frame: CGRect, maxRetries: Int = 3) -> [(text: String, point: CGPoint)] {
        for attempt in 1...maxRetries {
            if attempt > 1 { Thread.sleep(forTimeInterval: 0.5) }

            guard let screenshot = screenCapture.captureWindow(pid: nil, frame: frame),
                  let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }

            var results: [(text: String, point: CGPoint)] = []
            let semaphore = DispatchSemaphore(value: 0)

            let request = VNRecognizeTextRequest { request, error in
                defer { semaphore.signal() }
                guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    let bbox = observation.boundingBox
                    let imgWidth = CGFloat(cgImage.width)
                    let imgHeight = CGFloat(cgImage.height)
                    let scaleX = imgWidth / frame.width
                    let scaleY = imgHeight / frame.height
                    let xInImage = bbox.midX * imgWidth
                    let yInImage = (1 - bbox.midY) * imgHeight

                    results.append((
                        text: text,
                        point: CGPoint(x: frame.origin.x + xInImage / scaleX,
                                       y: frame.origin.y + yInImage / scaleY)
                    ))
                }
            }

            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en"]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
            semaphore.wait()

            if !results.isEmpty { return results }
        }
        return []
    }

    public func findText(_ searchText: String, inWindow frame: CGRect, fuzzy: Bool = false, maxRetries: Int = 3) -> CGPoint? {
        for attempt in 1...maxRetries {
            if attempt > 1 { Thread.sleep(forTimeInterval: 0.5) }

            guard let screenshot = screenCapture.captureWindow(pid: nil, frame: frame),
                  let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                if attempt == maxRetries { Logger.error("无法截取窗口") }
                continue
            }

            var foundPoint: CGPoint?
            let semaphore = DispatchSemaphore(value: 0)

            let request = VNRecognizeTextRequest { request, error in
                defer { semaphore.signal() }
                if let error = error { Logger.error("OCR 失败: \(error.localizedDescription)"); return }
                guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let text = candidate.string
                    guard text.contains(searchText) else { continue }

                    let bbox = observation.boundingBox
                    let imgWidth = CGFloat(cgImage.width)
                    let imgHeight = CGFloat(cgImage.height)
                    let scaleX = imgWidth / frame.width
                    let scaleY = imgHeight / frame.height
                    var xInImage = bbox.midX * imgWidth
                    let yInImage = (1 - bbox.midY) * imgHeight

                    if text.count > searchText.count {
                        let charWidth = bbox.width * imgWidth / CGFloat(text.count)
                        if let range = text.range(of: searchText) {
                            let prefixLen = text.distance(from: text.startIndex, to: range.lowerBound)
                            let searchCenter = CGFloat(prefixLen) + CGFloat(searchText.count) / 2.0
                            let fullCenter = CGFloat(text.count) / 2.0
                            xInImage += (searchCenter - fullCenter) * charWidth
                        }
                    }

                    let screenX = frame.origin.x + xInImage / scaleX
                    let screenY = frame.origin.y + yInImage / scaleY
                    Logger.info("找到文字 \"\(text)\" 在屏幕坐标: (\(Int(screenX)), \(Int(screenY)))")
                    foundPoint = CGPoint(x: screenX, y: screenY)
                    return
                }
            }

            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
            semaphore.wait()

            if let pt = foundPoint { return pt }
            if attempt < maxRetries { Logger.warn("未找到文字: \"\(searchText)\"，重试 (\(attempt)/\(maxRetries))...") }
        }

        Logger.warn("未找到文字: \"\(searchText)\"（已重试 \(maxRetries) 次）")
        return nil
    }

    public func findAllText(_ searchText: String, inWindow frame: CGRect, fuzzy: Bool = false) -> [CGPoint] {
        guard let screenshot = screenCapture.captureWindow(pid: nil, frame: frame),
              let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }

        var points: [CGPoint] = []
        let semaphore = DispatchSemaphore(value: 0)

        let request = VNRecognizeTextRequest { request, error in
            defer { semaphore.signal() }
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                let match = fuzzy ? text.contains(searchText) || searchText.contains(text)
                                  : text == searchText || text.contains(searchText)
                guard match else { continue }

                let bbox = observation.boundingBox
                let imgWidth = CGFloat(cgImage.width)
                let imgHeight = CGFloat(cgImage.height)
                let scaleX = imgWidth / frame.width
                let scaleY = imgHeight / frame.height
                points.append(CGPoint(
                    x: frame.origin.x + bbox.midX * imgWidth / scaleX,
                    y: frame.origin.y + (1 - bbox.midY) * imgHeight / scaleY
                ))
            }
        }

        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        semaphore.wait()

        return points
    }

    /// 静默搜索文字（不打 WARN 日志）
    private func findTextSilent(_ searchText: String, inWindow frame: CGRect) -> CGPoint? {
        guard let screenshot = screenCapture.captureWindow(pid: nil, frame: frame),
              let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        var foundPoint: CGPoint?
        let semaphore = DispatchSemaphore(value: 0)

        let request = VNRecognizeTextRequest { request, error in
            defer { semaphore.signal() }
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                guard text.contains(searchText) else { continue }

                let bbox = observation.boundingBox
                let imgWidth = CGFloat(cgImage.width)
                let imgHeight = CGFloat(cgImage.height)
                let scaleX = imgWidth / frame.width
                let scaleY = imgHeight / frame.height
                var xInImage = bbox.midX * imgWidth
                let yInImage = (1 - bbox.midY) * imgHeight

                if text.count > searchText.count {
                    let charWidth = bbox.width * imgWidth / CGFloat(text.count)
                    if let range = text.range(of: searchText) {
                        let prefixLen = text.distance(from: text.startIndex, to: range.lowerBound)
                        let searchCenter = CGFloat(prefixLen) + CGFloat(searchText.count) / 2.0
                        let fullCenter = CGFloat(text.count) / 2.0
                        xInImage += (searchCenter - fullCenter) * charWidth
                    }
                }

                foundPoint = CGPoint(x: frame.origin.x + xInImage / scaleX,
                                     y: frame.origin.y + yInImage / scaleY)
                return
            }
        }

        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        semaphore.wait()
        return foundPoint
    }

    public func dumpPage(inWindow frame: CGRect) {
        let texts = findAllText(inWindow: frame)
            .sorted { ($0.point.y, $0.point.x) < ($1.point.y, $1.point.x) }
        Logger.info("页面上共识别到 \(texts.count) 个文字:")
        for t in texts {
            let ry = Int(t.point.y - frame.origin.y)
            let rx = Int(t.point.x - frame.origin.x)
            Logger.info("  [y=\(ry), x=\(rx)] \"\(t.text)\"")
        }
    }

    // MARK: - 模拟点击

    @discardableResult
    public func click(at point: CGPoint) -> Bool {
        Logger.info("点击屏幕坐标: (\(Int(point.x)), \(Int(point.y)))")

        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(20_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(20_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(20_000)
        return true
    }

    public func clickViaAppleScript(at point: CGPoint) -> Bool {
        let script = """
        tell application "System Events"
            click at {\(Int(point.x)), \(Int(point.y))}
        end tell
        """
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", script]
        try? process.run()
        process.waitUntilExit()
        let success = process.terminationStatus == 0
        if !success { Logger.warn("AppleScript 点击失败，可能需要辅助功能权限") }
        return success
    }

    public func clickIcon(forText searchText: String, inWindow frame: CGRect, yOffset: CGFloat = -30) -> Bool {
        guard let textPoint = findText(searchText, inWindow: frame) else {
            Logger.warn("未找到 \"\(searchText)\" 文字，无法点击图标")
            return false
        }
        let iconPoint = CGPoint(x: textPoint.x, y: textPoint.y + yOffset)
        Logger.info("点击 \"\(searchText)\" 图标: (\(Int(iconPoint.x)), \(Int(iconPoint.y)))")
        return click(at: iconPoint)
    }

    // MARK: - 键盘输入

    public func keyCombo(key: String, flags: CGEventFlags) {
        let keyCode: CGKeyCode
        switch key.lowercased() {
        case "a": keyCode = 0
        case "c": keyCode = 8
        case "v": keyCode = 9
        case "x": keyCode = 7
        default: return
        }
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            down.flags = flags; down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            up.flags = flags; up.post(tap: .cghidEventTap)
        }
    }

    public func typeViaScript(_ text: String) {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"System Events\" to keystroke \"\(escaped)\""
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", script]
        try? p.run()
        p.waitUntilExit()
    }

    public func typeString(_ text: String) {
        for char in text {
            let str = String(char)
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                event.keyboardSetUnicodeString(stringLength: str.utf16.count, unicodeString: str.utf16.map { $0 })
                event.post(tap: .cghidEventTap)
                usleep(10_000)
                if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                    up.post(tap: .cghidEventTap)
                }
                usleep(10_000)
            }
        }
    }

    public func scrollDown(inWindow frame: CGRect) {
        let centerX = frame.origin.x + frame.width / 2
        let startY = frame.origin.y + frame.height * 0.7

        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: centerX, y: startY),
                mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(50_000)

        if let scroll = CGEvent(source: nil) {
            scroll.type = .scrollWheel
            scroll.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -3)
            scroll.post(tap: .cghidEventTap)
        }
        usleep(100_000)
    }

    // MARK: - 弹窗处理

    @discardableResult
    public func dismissAnyDialog(inWindow frame: CGRect) -> Bool {
        let dialogButtons = [
            "我知道了", "知道了", "确定", "确认", "好的",
            "不再提醒", "关闭", "取消", "跳过", "以后再说",
            "允许", "继续", "知道了!", "了解",
            "否", "稍后", "暂不", "去设置", "开启",
            "立即体验", "体验", "进入", "去看看", "下次再说"
        ]
        for text in dialogButtons {
            if let point = findTextSilent(text, inWindow: frame) {
                Logger.info("自动关闭弹窗: \(text)")
                click(at: point)
                Thread.sleep(forTimeInterval: 1)
                return true
            }
        }
        return false
    }

    public func dismissReminder(inWindow frame: CGRect) {
        _ = dismissAnyDialog(inWindow: frame)
    }

    @discardableResult
    public func goBack(inWindow frame: CGRect) -> Bool {
        // 返回按钮通常在左上角，坐标约为窗口宽度的 4%，距顶部 50px
        let bx = frame.origin.x + max(frame.width * 0.04, 20)
        let by = frame.origin.y + 50
        Logger.info("点击返回: (\(Int(bx)), \(Int(by)))")
        return click(at: CGPoint(x: bx, y: by))
    }

    // MARK: - 登录检测与执行

    public func checkLoginNeeded(inWindow frame: CGRect, maxDepth: Int = 3) -> Bool {
        guard maxDepth > 0 else {
            Logger.warn("登录检测递归深度耗尽，假定需要登录")
            return true
        }

        let allTexts = findAllText(inWindow: frame)
        let allStrings = allTexts.map { $0.text.trimmingCharacters(in: .whitespaces) }
        let combined = allStrings.joined(separator: " ")

        // 1. 11位手机号
        for t in allStrings {
            if t.count == 11, t.allSatisfy({ $0.isNumber }) {
                Logger.info("检测到登录界面（手机号: \(t)）")
                return true
            }
        }

        // 2. 异地登录弹窗
        if combined.contains("其他地方登录") || combined.contains("已在其他") {
            Logger.info("检测到异地登录弹窗，自动关闭")
            if let ok = findText("确定", inWindow: frame) {
                click(at: ok)
                Thread.sleep(forTimeInterval: 1.5)
            }
            return checkLoginNeeded(inWindow: frame, maxDepth: maxDepth - 1)
        }

        // 3. 会话过期
        let sessionExpired = combined.contains("重新登录") ||
            (combined.contains("新登录") && combined.contains("请")) ||
            allStrings.contains(where: { $0.contains("请") && $0.contains("登录") && $0.count <= 8 })
        if sessionExpired { Logger.info("检测到会话过期提示"); return true }

        // 4. 登录页特征
        if combined.contains("阅读并同意") || combined.contains("服务协议") ||
           combined.contains("请输入手机号") || combined.contains("输入手机号") ||
           combined.contains("手机号登录") || combined.contains("验证码登录") ||
           combined.contains("密码登录") || combined.contains("请输入密码") {
            Logger.info("检测到登录界面")
            return true
        }

        let loginFlags = ["获取验证码", "发送验证码", "验证码", "已阅读并同意", "用户协议", "隐私政策",
                          "还没有账号", "立即注册", "忘记密码"]
        var flagCount = 0
        for flag in loginFlags { if combined.contains(flag) { flagCount += 1 } }
        if flagCount >= 2 { Logger.info("检测到登录界面（特征匹配: \(flagCount)个）"); return true }

        // 5. 底部大"登录"按钮
        for item in allTexts where item.text == "登录" {
            if item.point.y - frame.origin.y > 300 {
                Logger.info("检测到底部登录按钮（y=\(Int(item.point.y - frame.origin.y))）")
                return true
            }
        }

        return false
    }

    public func performLogin(inWindow frame: CGRect) throws {
        Logger.info("正在执行登录...")

        let allTexts = findAllText(inWindow: frame)
        let hasPhone = allTexts.contains(where: {
            let t = $0.text.trimmingCharacters(in: .whitespaces)
            return t.count == 11 && t.allSatisfy({ $0.isNumber })
        })

        if !hasPhone, !config.yibanUsername.isEmpty {
            Logger.info("手机号未填写，尝试输入: \(config.yibanUsername)")
            if let phoneHint = findText("请输入手机号", inWindow: frame) ??
                               findText("手机号", inWindow: frame) ??
                               findText("输入手机号", inWindow: frame) {
                click(at: phoneHint)
                Thread.sleep(forTimeInterval: 0.5)
                typeViaScript(config.yibanUsername)
                Logger.info("已输入手机号")
                Thread.sleep(forTimeInterval: 0.5)
            }
        } else if hasPhone {
            Logger.info("手机号已填写，跳过")
        } else {
            Logger.warn("手机号未填写且配置中无账号")
        }

        // 勾选协议
        let pageTexts = findAllText(inWindow: frame).map { $0.text }
        if !pageTexts.contains(where: { $0.contains("◎") }) {
            click(at: CGPoint(x: frame.origin.x + 24, y: frame.origin.y + 415))
            Logger.info("已勾选协议")
            Thread.sleep(forTimeInterval: 0.5)
        } else {
            Logger.info("协议已勾选，跳过")
        }

        // 输入密码
        if !config.yibanPassword.isEmpty {
            if let pwdField = findText("请输入密码", inWindow: frame) {
                Logger.info("检测到密码输入框，点击并输入...")
                click(at: CGPoint(x: pwdField.x, y: pwdField.y + 35))
                Thread.sleep(forTimeInterval: 0.3)
                typeViaScript(config.yibanPassword)
                Logger.info("已输入密码")
                Thread.sleep(forTimeInterval: 0.5)
            }
        } else {
            Logger.warn("密码未配置")
        }

        // 点击登录
        let freshTexts = findAllText(inWindow: frame)
        for item in freshTexts where item.text == "登录" {
            if item.point.y - frame.origin.y > 400 {
                Logger.info("点击登录按钮")
                click(at: item.point)
                Thread.sleep(forTimeInterval: 2)

                let afterLogin = findAllText(inWindow: frame).map { $0.text }
                let loginErrors: [(String, String)] = [
                    ("请输入正确的手机号", "手机号格式不正确"),
                    ("手机号不正确", "手机号格式不正确"),
                    ("手机号未注册", "该手机号未注册"),
                    ("密码错误", "密码错误"),
                    ("账号或密码错误", "账号或密码错误"),
                ]
                for (keyword, reason) in loginErrors {
                    if afterLogin.contains(where: { $0.contains(keyword) }) {
                        Logger.error("登录失败: \(keyword)")
                        throw AppError.buttonDisabled(reason)
                    }
                }

                if verificationSolver.detectVerification(inWindow: frame) {
                    try verificationSolver.solveOrWait(inWindow: frame)
                    Thread.sleep(forTimeInterval: 1)
                }
                return
            }
        }

        // 备选
        if let loginPt = findText("登录", inWindow: frame), loginPt.y - frame.origin.y > 300 {
            Logger.info("点击登录按钮(备选): y=\(Int(loginPt.y - frame.origin.y))")
            click(at: loginPt)
            Thread.sleep(forTimeInterval: 2)
            return
        }

        throw AppError.elementNotFound("登录按钮")
    }

    // MARK: - 页面检测

    public enum Page {
        case home, schoolPortal, workbench, checkin, login, abnormal, unknown
    }

    public func isPageAbnormal(inWindow frame: CGRect) -> Bool {
        let allTexts = findAllText(inWindow: frame).map { $0.text }
        let combined = allTexts.joined(separator: " ")

        if allTexts.count <= 1 { return true }
        if allTexts.count <= 5 && allTexts.contains(where: { $0 == "网页" }) { return true }

        let abnormalFlags = [
            "网络异常", "网络错误", "加载失败", "无法连接",
            "页面不存在", "请求失败", "服务器错误", "系统繁忙",
            "请稍后重试", "获取失败", "数据异常", "页面过期"
        ]
        for flag in abnormalFlags { if combined.contains(flag) { return true } }
        return false
    }

    public func detectPage(inWindow frame: CGRect) -> Page {
        let allTexts = findAllText(inWindow: frame).map { $0.text }

        if isPageAbnormal(inWindow: frame) { return .abnormal }
        if allTexts.contains(where: { $0.contains("签到时段") || $0.contains("重新定位") }) { return .checkin }
        if allTexts.contains(where: { $0.contains("晚点签到") || $0.contains("晚点名") }) { return .workbench }
        if allTexts.contains(where: { $0.contains("校本化") }) { return .schoolPortal }
        if allTexts.contains(where: { $0.count == 11 && $0.allSatisfy({ $0.isNumber }) }) { return .login }
        if allTexts.contains(where: { $0.contains("请输入手机号") || $0.contains("输入手机号") }) &&
           allTexts.contains(where: { $0.contains("登录") }) { return .login }
        if allTexts.contains(where: { $0.contains("我的学校") }) &&
           allTexts.contains(where: { $0 == "首页" }) { return .home }
        return .unknown
    }

    // MARK: - 导航

    public func enterMySchool(inWindow frame: CGRect) throws {
        _ = dismissAnyDialog(inWindow: frame)
        Logger.info("正在点击「我的学校」...")
        guard let point = findText("我的学校", inWindow: frame) else {
            throw AppError.elementNotFound("我的学校")
        }
        click(at: point)
        Logger.success("已点击「我的学校」")
        Thread.sleep(forTimeInterval: config.stepDelay)
        _ = dismissAnyDialog(inWindow: frame)
        Thread.sleep(forTimeInterval: 0.5)
    }

    public func enterSchoolPortal(inWindow frame: CGRect) throws {
        _ = dismissAnyDialog(inWindow: frame)
        Logger.info("正在点击「校本化」图标...")
        guard clickIcon(forText: "校本化", inWindow: frame, yOffset: -30) else {
            throw AppError.elementNotFound("校本化")
        }
        Logger.success("已进入校本化")
        Thread.sleep(forTimeInterval: 2)
        _ = dismissAnyDialog(inWindow: frame)
        Thread.sleep(forTimeInterval: 0.5)
    }

    public func enterEveningCheckin(inWindow frame: CGRect) throws {
        _ = dismissAnyDialog(inWindow: frame)
        Logger.info("正在点击「晚点签到」图标...")
        guard clickIcon(forText: "晚点签到", inWindow: frame, yOffset: -30) else {
            throw AppError.elementNotFound("晚点签到")
        }
        Logger.success("已进入晚点签到")
        Thread.sleep(forTimeInterval: 1)
        for _ in 1...3 {
            if let pt = findText("我知道了", inWindow: frame) {
                Logger.info("点击「我知道了」关闭温馨提示: (\(Int(pt.x)), \(Int(pt.y)))")
                click(at: pt)
                Thread.sleep(forTimeInterval: 0.5)
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    // MARK: - 签到按钮

    public func clickCheckinButton(inWindow frame: CGRect) throws {
        let now = Date()
        let calendar = Calendar.current
        let currentMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let windowStart = config.checkinStartHour * 60 + config.checkinStartMinute
        let windowEnd = config.checkinEndHour * 60 + config.checkinEndMinute
        if currentMinutes < windowStart || currentMinutes > windowEnd {
            Logger.info("当前时间不在签到时段")
            throw AppError.buttonDisabled("当前不在签到时段(\(String(format: "%02d:%02d", config.checkinStartHour, config.checkinStartMinute))-\(String(format: "%02d:%02d", config.checkinEndHour, config.checkinEndMinute)))")
        }

        Logger.info("正在查找签到按钮...")
        _ = dismissAnyDialog(inWindow: frame)

        let allTexts = findAllText(inWindow: frame).map { $0.text }
        if allTexts.contains(where: { $0.contains("未达签到时段") || $0.contains("不在签到时段") }) {
            Logger.info("页面显示不在签到时段")
            throw AppError.buttonDisabled("当前不在签到时段(\(String(format: "%02d:%02d", config.checkinStartHour, config.checkinStartMinute))-\(String(format: "%02d:%02d", config.checkinEndHour, config.checkinEndMinute)))")
        }

        let beforeTexts = Set(allTexts)
        let keywords = ["未签到", "签到", "点击签到", "我要签到", "已签到"]

        var clicked = false
        for keyword in keywords {
            if let point = findText(keyword, inWindow: frame) {
                if point.y - frame.origin.y > 400 {
                    click(at: point)
                    Logger.success("已点击签到: \(keyword)")
                    clicked = true
                    break
                }
            }
        }

        guard clicked else { throw AppError.elementNotFound("签到按钮") }

        Thread.sleep(forTimeInterval: 3)
        let afterTexts = Set(findAllText(inWindow: frame).map { $0.text })

        let failureHints: [(String, String)] = [
            ("未达签到时段", "当前不在签到时段"),
            ("不在签到范围", "当前位置不在校区范围内"),
            ("不在签到区域", "当前位置不在校区范围内"),
            ("定位失败", "定位失败，无法签到"),
            ("签到失败", "服务器返回签到失败"),
            ("网络异常", "网络异常"),
            ("请重新定位", "需要重新定位"),
        ]
        for (keyword, reason) in failureHints {
            if afterTexts.contains(where: { $0.contains(keyword) }) {
                Logger.error("检测到失败提示: \(keyword)")
                throw AppError.buttonDisabled(reason)
            }
        }

        let dialogBtns = ["我知道了", "确定", "确认", "知道了", "好的", "关闭"]
        let hasDialog = dialogBtns.contains { btn in afterTexts.contains(where: { $0 == btn || $0.contains(btn) }) }

        // ✅ 检查一：明确成功文字
        let successHints = ["已签到", "签到成功", "签到完成", "操作成功", "提交成功", "打卡成功"]
        for hint in successHints {
            if afterTexts.contains(where: { $0.contains(hint) }) {
                if hasDialog { _ = dismissAnyDialog(inWindow: frame) }
                Logger.success("✅ 签到成功：检测到「\(hint)」")
                return
            }
        }

        // ✅ 检查二：页面跳转，按钮消失
        let signinButtons = ["未签到", "签到", "点击签到", "我要签到"]
        let buttonGone = signinButtons.allSatisfy { btn in !afterTexts.contains(where: { $0.contains(btn) }) }
        if buttonGone && beforeTexts != afterTexts {
            if hasDialog {
                Logger.warn("页面变化但存在弹窗，可能是错误提示")
                _ = dismissAnyDialog(inWindow: frame)
                throw AppError.buttonDisabled("签到后弹出未知对话框，请检查")
            }
            Logger.success("✅ 签到成功：页面已跳转，按钮消失，无错误提示")
            return
        }

        // ✅ 检查三：再点一次试试
        if let point = findText("未签到", inWindow: frame), (point.y - frame.origin.y) > 400 {
            Logger.warn("签到未生效，再次点击...")
            click(at: point)
            Thread.sleep(forTimeInterval: 3)

            let retryTexts = findAllText(inWindow: frame).map { $0.text }
            if retryTexts.contains(where: { $0.contains("未达签到时段") }) {
                throw AppError.buttonDisabled("当前不在签到时段(\(String(format: "%02d:%02d", config.checkinStartHour, config.checkinStartMinute))-\(String(format: "%02d:%02d", config.checkinEndHour, config.checkinEndMinute)))")
            }
            if let _ = findText("已签到", inWindow: frame) {
                Logger.success("✅ 签到成功（第二次点击后）")
                return
            }
            let finalTexts = Set(findAllText(inWindow: frame).map { $0.text })
            if signinButtons.allSatisfy({ btn in !finalTexts.contains(where: { $0.contains(btn) }) }) {
                Logger.success("✅ 签到成功：页面已跳转")
                return
            }
        }

        let bottomTexts = findAllText(inWindow: frame).map { $0.text }
        if bottomTexts.contains(where: { $0.contains("未达签到时段") }) {
            throw AppError.buttonDisabled("当前不在签到时段(\(String(format: "%02d:%02d", config.checkinStartHour, config.checkinStartMinute))-\(String(format: "%02d:%02d", config.checkinEndHour, config.checkinEndMinute)))")
        }

        Logger.warn("未能确认签到状态")
        throw AppError.buttonDisabled("未确认签到成功，请检查易班")
    }

    // MARK: - 带重试的操作

    public func withRetry<T>(_ description: String,
                      maxRetries: Int? = nil,
                      operation: () throws -> T) throws -> T {
        let retries = maxRetries ?? config.maxRetries
        var lastError: Error?

        for i in 0..<retries {
            do {
                return try operation()
            } catch {
                lastError = error
                Logger.warn("\(description) — 第 \(i + 1)/\(retries) 次失败: \(error.localizedDescription)")
                if i < retries - 1 { Thread.sleep(forTimeInterval: config.stepDelay) }
            }
        }
        throw lastError ?? AppError.retryExhausted(description)
    }
}

// MARK: - 错误类型

public enum AppError: Error, LocalizedError {
    case appNotFound
    case launchFailed
    case timeout(String)
    case elementNotFound(String)
    case clickFailed(String)
    case buttonDisabled(String)
    case retryExhausted(String)

    public var errorDescription: String? {
        switch self {
        case .appNotFound:   return "未找到易班 App，请确认已安装"
        case .launchFailed:  return "启动易班 App 失败"
        case .timeout(let msg):       return "超时: \(msg)"
        case .elementNotFound(let n): return "找不到「\(n)」，请确认页面是否正确"
        case .clickFailed(let n):     return "点击「\(n)」失败"
        case .buttonDisabled(let r):  return r
        case .retryExhausted(let m):  return "多次重试仍失败: \(m)"
        }
    }
}
