import Foundation
import AppKit
import CoreLocation
import ApplicationServices

// MARK: - 权限检查工具

public struct PermissionChecker {

    public enum PermissionStatus {
        case granted
        case denied
        case notDetermined
        case unknown
    }

    // MARK: - 单项检查

    /// 辅助功能权限（CGEvent 模拟点击 / AppleScript 需要）
    public static var accessibility: PermissionStatus {
        if AXIsProcessTrusted() { return .granted }
        return .denied
    }

    /// 弹出系统授权弹窗（比手动去设置里找更直接）
    public static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 定位权限
    public static var location: PermissionStatus {
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    // MARK: - 修复链接

    /// 打开系统设置的对应面板
    public static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    public static func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    public static func openLocationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
    }

    // MARK: - 综合检查

    /// 运行诊断，返回所有需要关注的权限
    public struct DiagnosticResult {
        public let accessibilityOK: Bool
        public let locationOK: Bool
        public let configOK: Bool
        public let canLaunchApp: Bool
        public let issues: [String]
    }

    public static func runDiagnostics(config: Config) -> DiagnosticResult {
        var issues: [String] = []

        let axOK = accessibility == .granted
        if !axOK { issues.append("请在「系统设置 → 隐私 → 辅助功能」中授权本应用") }

        let locOK = location != .denied
        if !locOK { issues.append("定位权限被拒绝，无法判断是否在校区附近") }

        let cfgOK = !config.yibanUsername.isEmpty
        if !cfgOK { issues.append("未配置易班手机号") }

        let pwdOK = !config.yibanPassword.isEmpty
        if !pwdOK { issues.append("未配置易班密码") }

        var canLaunch = false
        for bid in [config.yibanBundleID, "cn.yiban.mainAPP", "com.yiban.app", "com.yiban.www"] {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) != nil {
                canLaunch = true
                break
            }
        }
        if !canLaunch { issues.append("未找到易班 App，请确认已安装") }

        return DiagnosticResult(
            accessibilityOK: axOK,
            locationOK: locOK,
            configOK: cfgOK && pwdOK,
            canLaunchApp: canLaunch,
            issues: issues
        )
    }
}
