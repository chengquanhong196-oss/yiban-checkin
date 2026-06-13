import Foundation

// MARK: - 云服务 API 客户端

public final class CloudService: ObservableObject {
    public static let shared = CloudService()

    @Published public var isLoggedIn = false
    @Published public var profile: UserProfile?
    @Published public var lastError: String?

    private var token: String? {
        didSet {
            if let t = token { Keychain.set(t, forKey: "cloud_token") }
            else { Keychain.delete("cloud_token") }
        }
    }

    /// 服务器地址（可配置）
    public var baseURL: String {
        UserDefaults.standard.string(forKey: "cloud_server_url") ?? "https://yiban.example.com"
    }

    private let encoder = JSONEncoder()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        token = Keychain.get("cloud_token")
        if token != nil { Task { await loadProfile() } }
    }

    // MARK: - Auth

    @discardableResult
    public func login(email: String, password: String) async throws -> Bool {
        let body = try encoder.encode(["email": email, "password": password])
        let data = try await request("POST", "/api/login", body: body, auth: false)
        let resp = try decoder.decode(TokenResponse.self, from: data)
        token = resp.access_token
        await loadProfile()
        return true
    }

    @discardableResult
    public func register(email: String, password: String) async throws -> Bool {
        let body = try encoder.encode(["email": email, "password": password])
        let data = try await request("POST", "/api/register", body: body, auth: false)
        let resp = try decoder.decode(TokenResponse.self, from: data)
        token = resp.access_token
        await loadProfile()
        return true
    }

    public func logout() {
        token = nil
        Task { @MainActor in
            isLoggedIn = false
            profile = nil
        }
    }

    // MARK: - Profile & Config

    @MainActor
    public func loadProfile() {
        Task {
            do {
                let data = try await request("GET", "/api/me")
                let p = try decoder.decode(UserProfile.self, from: data)
                profile = p
                isLoggedIn = true
                lastError = nil
            } catch {
                if (error as? URLError)?.code == .userAuthenticationRequired {
                    token = nil
                    isLoggedIn = false
                }
                lastError = error.localizedDescription
            }
        }
    }

    public func updateConfig(config: YibanConfig) async throws {
        let body = try encoder.encode(config)
        _ = try await request("PUT", "/api/me/config", body: body)
    }

    public func getHistory() async throws -> [CheckinLogEntry] {
        let data = try await request("GET", "/api/me/history")
        return try decoder.decode([CheckinLogEntry].self, from: data)
    }

    public func triggerCheckin() async throws -> CheckinResult {
        let data = try await request("POST", "/api/me/checkin")
        return try decoder.decode(CheckinResult.self, from: data)
    }

    /// 获取爱发电支付链接
    public func getPaymentLink() async throws -> String {
        let data = try await request("POST", "/api/me/payment-link")
        let resp = try decoder.decode(PaymentLinkResponse.self, from: data)
        return resp.url
    }

    // MARK: - HTTP helper

    private func request(_ method: String, _ path: String,
                         body: Data? = nil, auth: Bool = true) async throws -> Data {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw CloudError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 15

        if auth {
            guard let t = token else { throw CloudError.notLoggedIn }
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        let httpResp = resp as? HTTPURLResponse

        if httpResp?.statusCode == 401 {
            throw CloudError.notLoggedIn
        }
        if let code = httpResp?.statusCode, code >= 400 {
            let msg = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.detail ?? "HTTP \(code)"
            throw CloudError.serverError(msg)
        }
        return data
    }
}

// MARK: - Types

public struct TokenResponse: Codable {
    public let access_token: String
}

public struct UserProfile: Codable {
    public let email: String
    public let tier: String
    public let expires_at: Date?
    public let subscription_active: Bool
    public let has_config: Bool
    public let created_at: Date
}

public struct YibanConfig: Codable {
    public var phone: String
    public var password: String
    public var school: String
    public var campus: String
    public var lat: Double
    public var lng: Double
    public var act: String
    public var client_id: String
    public var push_key: String

    public init(phone: String, password: String, school: String, campus: String,
                lat: Double, lng: Double, act: String, client_id: String, push_key: String) {
        self.phone = phone
        self.password = password
        self.school = school
        self.campus = campus
        self.lat = lat
        self.lng = lng
        self.act = act
        self.client_id = client_id
        self.push_key = push_key
    }
}

public struct CheckinLogEntry: Codable, Identifiable {
    public let id: Int
    public let created_at: Date
    public let success: Bool
    public let method: String
    public let message: String
}

public struct CheckinResult: Codable {
    public let success: Bool
    public let message: String
}

public struct PaymentLinkResponse: Codable {
    public let url: String
    public let user_id: Int
}

public struct ErrorResponse: Codable {
    public let detail: String
}

public enum CloudError: Error, LocalizedError {
    case notLoggedIn
    case invalidURL
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:       return "未登录"
        case .invalidURL:        return "服务器地址无效"
        case .serverError(let m): return m
        }
    }
}
