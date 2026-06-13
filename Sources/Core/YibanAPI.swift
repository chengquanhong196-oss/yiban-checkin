import Foundation

// MARK: - 易班 API 直调（纯 URLSession，参照 Qs315490/fyiban）

/// 阻止 URLSession 自动跟随重定向
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        return nil
    }
}

public final class YibanAPI {
    private let config: Config
    private var accessToken: String = ""
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }()

    public init(config: Config) {
        self.config = config
    }

    // MARK: - 请求体编码

    /// 对 form-urlencoded 请求体中的值做安全编码（排除 & = + 等特殊字符）
    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - 登录

    /// 登录 + CAS OAuth 认证，参照 Qs315490/fyiban SchoolBasedAuth._auth()
    /// 改进：区分密码错误 vs 网络错误，不重复无意义的重试
    public func login() async throws -> Bool {
        guard !config.yibanUsername.isEmpty, !config.yibanPassword.isEmpty else {
            throw APIError.loginFailed("未配置手机号或密码", permanent: true)
        }

        // 预置 csrf_token cookie
        for domain in ["api.uyiban.com", "c.uyiban.com", ".uyiban.com"] {
            if let csrfCookie = HTTPCookie(properties: [.domain: domain, .path: "/", .name: "csrf_token", .value: "00000"]) {
                session.configuration.httpCookieStorage?.setCookie(csrfCookie)
            }
        }

        let encryptedPassword = try rsaEncrypt(config.yibanPassword)

        // Step 1: 手机号+密码登录 → Step 2: CAS OAuth
        var lastError: APIError = .loginFailed("未知错误", permanent: false)

        for identify in ["1", "0"] {
            var req = URLRequest(url: URL(string: "https://m.yiban.cn/api/v4/passport/login")!)
            req.httpMethod = "POST"
            req.setValue("Yiban", forHTTPHeaderField: "User-Agent")
            req.setValue("5.1.2", forHTTPHeaderField: "AppVersion")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let body = "ct=2&identify=\(identify)&mobile=\(config.yibanUsername)&password=\(Self.formEncode(encryptedPassword))"
            req.httpBody = body.data(using: .utf8)

            let (data, _) = try await session.data(for: req)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

            // response 可能是 Int 或 String（容错）
            let respCode: Int?
            if let i = json["response"] as? Int { respCode = i }
            else if let s = json["response"] as? String, let i = Int(s) { respCode = i }
            else { respCode = nil }

            Logger.info("login identify=\(identify): response=\(respCode ?? -1)")

            // 密码/账号错误 — 不重试，直接报错
            if let code = respCode, code != 100 {
                let msg = (json["data"] as? [String: Any])?["message"] as? String
                       ?? (json["message"] as? String)
                       ?? errorMessage(for: code)
                Logger.error("登录被拒 (code=\(code)): \(msg)")
                lastError = .loginFailed(msg, permanent: true)
                // identify=0 和 identify=1 的密码验证一样，不用再试
                throw lastError
            }

            // 网络/服务端临时错误 — 可能重试
            guard respCode == 100,
                  let d = json["data"] as? [String: Any],
                  let token = d["access_token"] as? String else {
                lastError = .loginFailed("服务端返回异常: \(String(data: data, encoding: .utf8)?.prefix(100) ?? "")", permanent: false)
                continue  // 换 identify 重试
            }

            accessToken = token
            Logger.success("API 登录成功 (identify=\(identify))")

            // Step 2: 获取 verify_request
            guard let verify = try? await getVerifyRequest() else {
                lastError = .loginFailed("无法获取 verify_request，可能是网络问题", permanent: false)
                Logger.warn(lastError.localizedDescription)
                continue
            }
            Logger.info("verify_request: \(verify.prefix(16))...")

            // Step 3: CAS OAuth 认证
            guard let authSuccess = try? await performCASAuth(verify: verify) else {
                lastError = .loginFailed("CAS OAuth 认证失败（网络或服务端问题）", permanent: false)
                Logger.warn(lastError.localizedDescription)
                continue
            }

            if authSuccess { return true }
        }

        throw lastError
    }

    /// 常见错误码 → 中文消息
    private func errorMessage(for code: Int) -> String {
        switch code {
        case 100: return "成功"
        case 200: return "密码错误"
        case 201: return "账号不存在"
        case 202: return "账号已注销"
        case 210: return "账号或密码错误"
        case 211: return "验证码错误"
        case 400: return "参数错误"
        default:  return "错误码 \(code)"
        }
    }

    // MARK: - 获取 verify_request

    private func getVerifyRequest() async throws -> String {
        var req = URLRequest(url: URL(string: "https://f.yiban.cn/iapp/index?act=\(config.yibanAct)")!)
        req.setValue("Yiban", forHTTPHeaderField: "User-Agent")
        req.setValue("5.1.2", forHTTPHeaderField: "AppVersion")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(accessToken, forHTTPHeaderField: "logintoken")
        req.setValue("https://c.uyiban.com", forHTTPHeaderField: "Origin")

        let noRedirectSession = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        let (data, response) = try await noRedirectSession.data(for: req)
        let httpResp = response as? HTTPURLResponse
        let statusCode = httpResp?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
        Logger.info("f.yiban.cn/iapp/index: HTTP \(statusCode), body=\(body)")

        if let allHeaders = httpResp?.allHeaderFields {
            for (key, value) in allHeaders {
                if let k = key as? String, k.lowercased().contains("location") {
                    Logger.info("  header[\(k)]: \(value)")
                }
            }
        }

        guard let location = httpResp?.allHeaderFields["Location"] as? String else {
            throw APIError.loginFailed("无法获取重定向地址 (HTTP \(statusCode))", permanent: false)
        }

        // Location 格式: https://c.uyiban.com/#/?verify_request=xxx...
        guard let range = location.range(of: "verify_request=") else {
            throw APIError.loginFailed("重定向地址中无 verify_request", permanent: false)
        }
        let after = String(location[range.upperBound...])
        return after.components(separatedBy: "&").first ?? after
    }

    // MARK: - CAS OAuth 认证

    private func performCASAuth(verify: String) async throws -> Bool {
        let clientId = config.yibanClientId
        let redirectUri = "https://f.yiban.cn/\(config.yibanAct)"
        let baseHeaders = [
            "Origin": "https://c.uyiban.com",
            "User-Agent": "Yiban",
            "AppVersion": "5.1.2",
        ]

        let encodedVerify = Self.formEncode(verify)

        // Step 3a: 第一次 auth/yiban
        var req1 = URLRequest(url: URL(string: "https://api.uyiban.com/base/c/auth/yiban?verifyRequest=\(encodedVerify)&CSRF=00000")!)
        for (k, v) in baseHeaders { req1.setValue(v, forHTTPHeaderField: k) }
        let (data1, _) = try await session.data(for: req1)
        Logger.info("auth/yiban #1: \(String(data: data1, encoding: .utf8)?.prefix(120) ?? "")")

        // Step 3b: OAuth code/html
        var req2 = URLRequest(url: URL(string: "https://oauth.yiban.cn/code/html?client_id=\(clientId)&redirect_uri=\(redirectUri)")!)
        for (k, v) in baseHeaders { req2.setValue(v, forHTTPHeaderField: k) }
        let _ = try await session.data(for: req2)
        Logger.info("oauth code/html 完成")

        // Step 3c: OAuth usersure
        var req3 = URLRequest(url: URL(string: "https://oauth.yiban.cn/code/usersure")!)
        req3.httpMethod = "POST"
        for (k, v) in baseHeaders { req3.setValue(v, forHTTPHeaderField: k) }
        req3.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req3.httpBody = "client_id=\(clientId)&redirect_uri=\(redirectUri)".data(using: .utf8)
        let _ = try await session.data(for: req3)
        Logger.info("oauth usersure 完成")

        // Step 3d: 第二次 auth/yiban
        var req4 = URLRequest(url: URL(string: "https://api.uyiban.com/base/c/auth/yiban?verifyRequest=\(encodedVerify)&CSRF=00000")!)
        for (k, v) in baseHeaders { req4.setValue(v, forHTTPHeaderField: k) }
        let (data4, _) = try await session.data(for: req4)
        guard let json = try? JSONSerialization.jsonObject(with: data4) as? [String: Any],
              let code = json["code"] as? Int, code == 0 else {
            Logger.error("auth/yiban #2 失败: \(String(data: data4, encoding: .utf8)?.prefix(200) ?? "")")
            return false
        }

        Logger.success("CAS OAuth 认证完成")
        return true
    }

    // MARK: - 签到（主入口）

    /// 执行晚点签到。如果 Cookie 过期自动 re-login 一次
    public func performEveningCheckin() async throws -> String {
        guard !accessToken.isEmpty else { throw APIError.notLoggedIn }

        // 先获取签到时段
        let range: [String: Any]
        do {
            range = try await getSignRange()
        } catch let error as APIError {
            // Cookie 过期 → 尝试 re-login 一次
            if case .signFailed(let msg, _) = error, msg.contains("请先登录") || msg.contains("未登录") {
                Logger.warn("检测到会话过期，尝试重新登录...")
                accessToken = ""
                if try await login() { range = try await getSignRange() }
                else { throw error }
            } else {
                throw error
            }
        }

        let now = Date().timeIntervalSince1970
        guard let start = range["StartTime"] as? TimeInterval,
              let end = range["EndTime"] as? TimeInterval else {
            throw APIError.signFailed("无法获取签到时段", permanent: false)
        }
        if now < start || now > end {
            throw APIError.signFailed("不在签到时段", permanent: true)
        }

        return try await submitSignIn()
    }

    // MARK: - 签到 API

    private func getSignRange() async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.uyiban.com/nightAttendance/student/index/signPosition?CSRF=00000")!)
        req.setValue("https://c.uyiban.com", forHTTPHeaderField: "Origin")
        req.setValue("Yiban", forHTTPHeaderField: "User-Agent")
        req.setValue("5.1.2", forHTTPHeaderField: "AppVersion")

        let (data, _) = try await session.data(for: req)
        let str = String(data: data, encoding: .utf8) ?? ""
        Logger.info("签到时段: \(str.prefix(150))")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 0,
              let dataDict = json["data"] as? [String: Any],
              let range = dataDict["Range"] as? [String: Any] else {
            // 检查是否需要登录
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["msg"] as? String
            throw APIError.signFailed(msg ?? str.prefix(100).description, permanent: msg?.contains("登录") == true)
        }
        return range
    }

    private func submitSignIn() async throws -> String {
        let signData = """
        {"Reason":"","AttachmentFileName":"","LngLat":"\(config.campusLongitude),\(config.campusLatitude)","Address":"\(config.schoolName)\(config.campusName)校区"}
        """
        let encodedSign = Self.formEncode(signData)

        var req = URLRequest(url: URL(string: "https://api.uyiban.com/nightAttendance/student/index/signIn?CSRF=00000")!)
        req.httpMethod = "POST"
        req.setValue("https://c.uyiban.com", forHTTPHeaderField: "Origin")
        req.setValue("Yiban", forHTTPHeaderField: "User-Agent")
        req.setValue("5.1.2", forHTTPHeaderField: "AppVersion")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "Code=&PhoneModel=&SignInfo=\(encodedSign)&OutState=1".data(using: .utf8)

        let (data, _) = try await session.data(for: req)
        let str = String(data: data, encoding: .utf8) ?? ""
        Logger.info("签到返回: \(str.prefix(200))")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 0 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["msg"] as? String ?? "未知错误"
            throw APIError.signFailed(msg, permanent: false)
        }
        Logger.success("API 签到成功")
        return "签到成功"
    }

    // MARK: - RSA 加密

    private func rsaEncrypt(_ text: String) throws -> String {
        let pemKey = """
        -----BEGIN PUBLIC KEY-----
        MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAzq0rgsM++ZxLRGHpdfre
        Hu6UXhdlUS5P2WOxRG14qU8/iWSb/CkOqgOl8AGcOhlthkvolCdpUvVcVsVUxBv0
        YRN0Jb64zPrn5aLVwQT4RJn5tXvoqLdHIXis7pljXAMDPVZOVlWJkDMk8YU6HDaA
        MqsD6l5p9lg2LMP4OhMgaPX+CkO370LB5vRjJTHp03n+IqfxXoC7DEd+kxRIEM2C
        EDgUSYDJBDgwBvGALZmvB/a1b0im9t1P/EmnuE7uN9NRFoWyVpOiEwo/Ti7rmJGf
        qNT3vvtfWo4nXsm1rYQXsPayoKDSRaba3gFY/1SYWLAuSO2q2da5ZCcsAk5RKy0V
        c1hUg8n6y0YLAvuzoXY5VyNMXkhH5Zc5Kg64b5RxILeZpZG0MV7GFY3sw//k7SNg
        darKT8A0Iv3l3lfguX3HNi6dkf97kS/EiA0tbkIB/JNjv13mq8HL7LijRt2hkKqP
        PhQW88xC/exZilU5pAavoZOPuZIOTUHqtpRq4ZeKl+wDf+e5lPYFDpihWGjplGpa
        4BOSmGeo/SyVFPji9QF4Pk0DRJF/NjwJoAC60xHAVt5Z4gQSOOOjNZDCswA0ry2L
        e8m5cv5vPGY75uVrGqALQ6Xm961PPc5cJ1q7tmEZMj+z5HE7tgAdhiPI6acKgrAv
        +1k4N0OVqKamMS+PVpD05hUCAwEAAQ==
        -----END PUBLIC KEY-----
        """

        let lines = pemKey.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }
        guard let keyData = Data(base64Encoded: lines.joined()) else {
            throw APIError.encryptFailed("无法解析RSA公钥")
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 4096,
        ]
        guard let secKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil) else {
            throw APIError.encryptFailed("无法导入RSA公钥")
        }
        guard let encrypted = SecKeyCreateEncryptedData(
            secKey, .rsaEncryptionPKCS1, text.data(using: .utf8)! as CFData, nil
        ) else {
            throw APIError.encryptFailed("RSA加密失败")
        }
        return (encrypted as Data).base64EncodedString()
    }
}

// MARK: - 错误类型

public enum APIError: Error, LocalizedError {
    case loginFailed(String, permanent: Bool)
    case notLoggedIn
    case signFailed(String, permanent: Bool)
    case encryptFailed(String)

    /// 是否为不可重试的错误（密码错误、不在时段等）
    public var isPermanent: Bool {
        switch self {
        case .loginFailed(_, let p): return p
        case .signFailed(_, let p):  return p
        case .notLoggedIn:           return false
        case .encryptFailed:         return true
        }
    }

    public var errorDescription: String? {
        switch self {
        case .loginFailed(let msg, _): return "API登录失败: \(msg)"
        case .notLoggedIn:             return "未登录"
        case .signFailed(let msg, _):  return "API签到失败: \(msg)"
        case .encryptFailed(let msg):  return "加密失败: \(msg)"
        }
    }
}
