import Foundation

/// 应用配置 — 从 JSON 文件读取，敏感信息（密码、SendKey）走 Keychain 存储
public struct Config: Codable {
    public var yibanBundleID: String = "cn.yiban.mainAPP"
    public var schoolName: String = ""
    public var campusName: String = ""
    public var campusLatitude: Double = 0
    public var campusLongitude: Double = 0
    public var radiusMeters: Double = 500
    /// 易班校本化 App 标识（不同学校不同，默认福州大学）
    public var yibanAct: String = "iapp7463"
    /// OAuth 客户端 ID（与 act 配套）
    public var yibanClientId: String = "95626fa3080300ea"
    /// OCR 导航按钮文字（不同学校易班首页布局不同）
    public var ocrSchoolButton: String = "我的学校"
    public var ocrPortalButton: String = "校本化"
    public var ocrCheckinButton: String = "晚点签到"
    public var locationTimeout: TimeInterval = 15
    public var uiTimeout: TimeInterval = 10
    public var stepDelay: TimeInterval = 2
    public var maxRetries: Int = 3
    public var logLevel: Int = 1  // 0=debug, 1=info, 2=warn, 3=error
    public var yibanUsername: String = ""
    // "auto"=API优先OCR兜底, "api"=仅API不转OCR, "ocr"=仅OCR
    public var checkinMethod: String = "auto"

    // API 设置
    public var apiTimeout: TimeInterval = 20      // API 请求超时（秒）
    public var apiRetries: Int = 1                 // API 失败重试次数

    // 签到时段（24h 制的时+分）
    public var checkinStartHour: Int = 21
    public var checkinStartMinute: Int = 30
    public var checkinEndHour: Int = 23
    public var checkinEndMinute: Int = 0

    // MARK: - 敏感字段（Keychain 存储，不入 JSON）

    /// 易班密码 — 存储于 Keychain，不入 config.json
    public var yibanPassword: String {
        get { Keychain.get("yibanPassword") ?? "" }
        set {
            if newValue.isEmpty { Keychain.delete("yibanPassword") }
            else { Keychain.set(newValue, forKey: "yibanPassword") }
        }
    }

    /// Server酱 SendKey — 存储于 Keychain，不入 config.json
    public var pushKey: String {
        get { Keychain.get("pushKey") ?? "" }
        set {
            if newValue.isEmpty { Keychain.delete("pushKey") }
            else { Keychain.set(newValue, forKey: "pushKey") }
        }
    }

    // MARK: - CodingKeys（排除 Keychain 存储的字段）

    enum CodingKeys: String, CodingKey {
        case yibanBundleID, schoolName, campusName, yibanAct, yibanClientId
        case ocrSchoolButton, ocrPortalButton, ocrCheckinButton
        case campusLatitude, campusLongitude, radiusMeters
        case locationTimeout, uiTimeout, stepDelay, maxRetries
        case logLevel, yibanUsername, checkinMethod
        case apiTimeout, apiRetries
        case checkinStartHour, checkinStartMinute, checkinEndHour, checkinEndMinute
        // yibanPassword 和 pushKey 不在 CodingKeys 中 → 不参与编解码
    }

    public init() {}

    // MARK: - Load / Save

    public static var configPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/yiban-checkin/config.json")
    }

    public static func load() -> Config {
        let path = configPath
        guard let data = try? Data(contentsOf: path) else {
            Logger.warn("配置文件不存在，使用默认配置: \(path.path)")
            return Config()
        }
        do {
            var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            var needsMigration = false

            // 迁移旧字段名 barkKey → pushKey（兼容旧配置）
            if dict["barkKey"] != nil, dict["pushKey"] == nil {
                dict["pushKey"] = dict["barkKey"]
            }

            // 迁移明文密码到 Keychain（只做一次）
            if let pwd = dict["yibanPassword"] as? String, !pwd.isEmpty {
                Keychain.set(pwd, forKey: "yibanPassword")
                dict["yibanPassword"] = ""  // 下次 save 前已为空
                needsMigration = true
                Logger.info("已将密码迁移到 Keychain")
            }
            if let pk = dict["pushKey"] as? String, !pk.isEmpty {
                Keychain.set(pk, forKey: "pushKey")
                dict["pushKey"] = ""  // 下次 save 前已为空
                needsMigration = true
                Logger.info("已将 SendKey 迁移到 Keychain")
            }

            // 移除 Keychain 字段后解码
            dict.removeValue(forKey: "yibanPassword")
            dict.removeValue(forKey: "pushKey")
            dict.removeValue(forKey: "barkKey")

            let migratedData = try JSONSerialization.data(withJSONObject: dict)
            var config = try JSONDecoder().decode(Config.self, from: migratedData)
            Logger.info("已加载配置文件: \(path.path)")
            // 迁移后立即保存，清除磁盘上的明文密码
            if needsMigration {
                config.save()
                Logger.info("已清除配置文件中的明文密码")
            }
            return config
        } catch {
            Logger.error("配置文件解析失败: \(error.localizedDescription)，使用默认配置")
            return Config()
        }
    }

    public func save() {
        let path = Self.configPath
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)  // CodingKeys 自动排除密码
            try data.write(to: path, options: .atomic)
            Logger.info("配置已保存到: \(path.path)")
        } catch {
            Logger.error("保存配置失败: \(error.localizedDescription)")
        }
    }
}
