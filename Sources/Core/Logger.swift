import Foundation

/// 日志模块 — 记录所有操作到文件，日志级别可通过 Config 配置
public enum Logger {
    public static let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs")
    public static let logFile = logDir.appendingPathComponent("yiban-checkin.log")

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let logQueue = DispatchQueue(label: "com.yiban.logger", qos: .utility)

    public enum Level: Comparable {
        case debug
        case info
        case warn
        case error
        case success

        private var priority: Int {
            switch self {
            case .debug:   return 0
            case .info:    return 1
            case .success: return 1
            case .warn:    return 2
            case .error:   return 3
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.priority < rhs.priority
        }

        var label: String {
            switch self {
            case .debug:   return "DEBUG"
            case .info:    return "INFO"
            case .warn:    return "WARN"
            case .error:   return "ERROR"
            case .success: return "SUCCESS"
            }
        }
    }

    /// 缓存日志级别，避免递归调用 Config.load()
    private static var _cachedLevel: Level?
    private static var isLoading = false

    /// 当前日志级别（默认 info，通过 refreshLevel() 从 Config 同步）
    public static var currentLevel: Level {
        if let cached = _cachedLevel { return cached }
        return .info
    }

    /// 从 Config 刷新日志级别（由外部在安全时机调用）
    public static func refreshLevel() {
        guard !isLoading else { return }
        isLoading = true
        switch Config.load().logLevel {
        case 0:  _cachedLevel = .debug
        case 2:  _cachedLevel = .warn
        case 3:  _cachedLevel = .error
        default: _cachedLevel = .info
        }
        isLoading = false
    }

    // MARK: - 写入

    public static func log(_ message: String, level: Level = .info) {
        guard level >= currentLevel else { return }

        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level.label)] \(message)\n"

        logQueue.async {
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.data(using: .utf8)?.write(to: logFile, options: .atomic)
            }
        }

        // stdout 只打印 warning 以上级别
        if level >= .warn || level == .success {
            print("[\(level.label)] \(message)")
        }
    }

    public static func debug(_ message: String)   { log(message, level: .debug) }
    public static func info(_ message: String)    { log(message, level: .info) }
    public static func warn(_ message: String)    { log(message, level: .warn) }
    public static func error(_ message: String)   { log(message, level: .error) }
    public static func success(_ message: String) { log(message, level: .success) }
}
