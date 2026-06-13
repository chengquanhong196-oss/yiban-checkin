import SwiftUI
import AppKit

// MARK: - 自动更新检查（基于 GitHub Releases API）

/// 查询 GitHub Releases 最新版本，有新版本时弹窗引导下载
/// 无需 Sparkle 依赖，网络被墙时可替换为自定义服务器
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// GitHub 仓库地址（可配置为自建服务器）
    @AppStorage("updateRepo") var repo = "your-username/yiban-checkin"
    @AppStorage("autoCheckForUpdates") var autoCheckEnabled = true

    var lastCheckDate: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheckDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheckDate") }
    }

    /// 当前版本号（从 Info.plist 读取，开发环境 fallback 为 "1.0.0"）
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private init() {}

    // MARK: - Public API

    /// 手动检查更新（带 UI 反馈）
    func checkForUpdates(showNoUpdate: Bool = true) {
        Task {
            do {
                guard let release = try await fetchLatestRelease() else {
                    if showNoUpdate { showAlert(title: "已是最新", message: "当前版本 \(currentVersion) 已是最新") }
                    return
                }
                showUpdateAlert(release: release)
            } catch {
                if showNoUpdate { showAlert(title: "检查失败", message: error.localizedDescription) }
            }
            lastCheckDate = Date()
        }
    }

    /// 后台静默检查（有新版本才弹窗）
    func checkInBackground() {
        if !autoCheckEnabled { return }
        Task {
            guard let release = try? await fetchLatestRelease() else { return }
            showUpdateAlert(release: release)
            lastCheckDate = Date()
        }
    }

    // MARK: - GitHub API

    private struct GHRelease: Codable {
        let tag_name: String
        let name: String
        let html_url: String
        let body: String?
        let prerelease: Bool
    }

    private func fetchLatestRelease() async throws -> GHRelease? {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.timeoutInterval = 10

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        let release = try JSONDecoder().decode(GHRelease.self, from: data)
        guard !release.prerelease else { return nil }

        // 比较版本号
        let latest = release.tag_name.replacingOccurrences(of: "v", with: "")
        if versionNewer(latest, than: currentVersion) {
            return release
        }
        return nil
    }

    private func versionNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    // MARK: - Alert

    private func showUpdateAlert(release: GHRelease) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(release.name)"
        alert.informativeText = release.body?.prefix(500).description ?? "请前往 GitHub 下载最新版本"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "下载")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: release.html_url)!)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
