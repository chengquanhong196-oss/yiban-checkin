import Foundation
import AppKit

// MARK: - 屏幕截图工具（从 AppAutomator 抽出）

public final class ScreenCapture {
    /// 缓存当前窗口 ID，用于高效截图
    public var currentWindowID: CGWindowID?

    public init(windowID: CGWindowID? = nil) {
        self.currentWindowID = windowID
    }

    // MARK: - 截取窗口

    /// 截取指定窗口区域，三套方案依次回退
    public func captureWindow(pid: Int32?, frame: CGRect) -> NSImage? {
        // 方案 1: 用缓存的窗口 ID 直接截取（最快，不需录屏权限）
        if let wid = currentWindowID {
            if let cgImage = CGWindowListCreateImage(
                .null, .optionIncludingWindow,
                wid, [.boundsIgnoreFraming, .bestResolution]
            ) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }

        // 方案 2: 通过 pid 查找窗口截图
        if let pid = pid {
            let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]]

            if let window = windowList?.first(where: {
                ($0[kCGWindowOwnerPID as String] as? Int32) == pid &&
                ($0[kCGWindowLayer as String] as? Int32 ?? 99) <= 24
            }),
            let wid = window[kCGWindowNumber as String] as? CGWindowID,
            let cgImage = CGWindowListCreateImage(
                .null, .optionIncludingWindow, wid,
                [.boundsIgnoreFraming, .bestResolution]
            ) {
                currentWindowID = wid  // 缓存
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }

        // 方案 3: screencapture 全屏再裁剪（需录屏权限）
        return captureFullScreen(croppingTo: frame)
    }

    private func captureFullScreen(croppingTo frame: CGRect) -> NSImage? {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("yiban_full_\(UUID().uuidString).png")

        let process = Process()
        process.launchPath = "/usr/sbin/screencapture"
        process.arguments = ["-x", tempFile.path]
        try? process.run()
        process.waitUntilExit()

        defer { try? FileManager.default.removeItem(at: tempFile) }

        guard process.terminationStatus == 0,
              let fullImage = NSImage(contentsOf: tempFile),
              let cgFull = fullImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Logger.error("截屏失败（退出码: \(process.terminationStatus)）")
            return nil
        }

        let screenWidth = NSScreen.main?.frame.width ?? 1440
        let scale = CGFloat(cgFull.width) / screenWidth
        let cropRect = CGRect(
            x: frame.origin.x * scale,
            y: frame.origin.y * scale,
            width: frame.width * scale,
            height: frame.height * scale
        )

        guard let cropped = cgFull.cropping(to: cropRect) else {
            Logger.warn("裁剪截图失败: cropRect=\(cropRect), fullSize=\(cgFull.width)x\(cgFull.height)")
            return nil
        }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }

    // MARK: - 截取区域

    /// 截取屏幕指定区域（像素坐标），用于验证码小图采样
    public func captureRegion(_ rect: CGRect) -> NSImage? {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("yiban_region_\(UUID().uuidString).png")
        let rectStr = "\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))"
        let process = Process()
        process.launchPath = "/usr/sbin/screencapture"
        process.arguments = ["-R", rectStr, "-x", tempFile.path]
        try? process.run()
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: tempFile) }
        guard process.terminationStatus == 0 else { return nil }
        return NSImage(contentsOf: tempFile)
    }
}
