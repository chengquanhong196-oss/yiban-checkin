import Foundation

/// 通知模块 — macOS 本地通知 + Server酱微信推送
public enum Notifier {

    /// 发送系统通知
    public static func send(title: String, message: String, sound: String? = nil) {
        var script = "display notification \"\(message.escaped)\" with title \"\(title.escaped)\""
        if let s = sound { script += " sound name \"\(s.escaped)\"" }
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", script]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                Logger.info("通知已发送: \(title)")
            } else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                Logger.error("通知发送失败 (exit \(process.terminationStatus)): \(errMsg)")
            }
        } catch {
            Logger.error("通知进程启动失败: \(error.localizedDescription)")
        }
    }

    /// 签到成功
    public static func checkinSuccess(method: String = "API") {
        let time = timeString()
        let tag = method == "OCR" ? "[OCR]" : "[API]"
        let msg = "\(tag) 晚点签到已完成 (\(time))"
        send(title: "易班签到 ✓ \(time)", message: msg, sound: "Glass")
        dialog(msg)
        pushToPhone(title: "易班签到 ✓", body: msg)
    }

    /// 签到失败
    public static func checkinFailed(reason: String, method: String = "API") {
        let tag = method == "OCR" ? "[OCR]" : "[API]"
        let msg = "\(tag) 签到失败\n\(reason)"
        send(title: "易班签到 失败", message: msg, sound: "Basso")
        dialog(msg)
        pushToPhone(title: "易班签到 失败", body: msg)
    }

    /// 不在范围内
    public static func outOfRange(distance: Double) {
        let km = String(format: "%.1f", distance / 1000)
        let msg = "距校区约 \(km) 公里，不在签到范围内"
        send(title: "易班签到 — 已跳过", message: msg)
        pushToPhone(title: "易班签到 — 已跳过", body: msg)
    }

    /// 通用错误
    public static func error(_ message: String) {
        send(title: "易班签到 — 错误", message: message, sound: "Basso")
        dialog(message)
        pushToPhone(title: "易班签到 — 错误", body: message)
    }

    // MARK: 内部

    private static func dialog(_ msg: String) {
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", "display dialog \"\(msg.escaped)\" with title \"易班签到\" buttons {\"知道了\"} default button 1 giving up after 10"]
        try? p.run()
    }

    private static func timeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    // MARK: 手机推送

    private static func pushToPhone(title: String, body: String) {
        let config = Config.load()
        let key = config.pushKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }

        let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        let encodedBody = body
            .replacingOccurrences(of: "\n", with: " ")
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body

        guard let url = URL(string: "https://sctapi.ftqq.com/\(key).send") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "title=\(encodedTitle)&desp=\(encodedBody)".data(using: .utf8)
        req.timeoutInterval = 5

        URLSession.shared.dataTask(with: req) { _, _, error in
            if let error = error {
                Logger.warn("Server酱推送失败: \(error.localizedDescription)")
            } else {
                Logger.info("📱 已推送到微信")
            }
        }.resume()
    }
}

private extension String {
    var escaped: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
