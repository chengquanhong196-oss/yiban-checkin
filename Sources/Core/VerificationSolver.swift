import Foundation
import AppKit

// MARK: - AI 验证码检测与自动解决（从 AppAutomator 抽出）

public final class VerificationSolver {
    /// OCR 回调：返回窗口内所有文字及坐标
    public typealias OCRProvider = (CGRect) -> [(text: String, point: CGPoint)]
    /// 截图回调：截取指定区域
    public typealias RegionCapture = (CGRect) -> NSImage?
    /// 点击回调：在屏幕坐标点击
    public typealias ClickHandler = (CGPoint) -> Bool

    private let ocr: OCRProvider
    private let captureRegion: RegionCapture
    private let click: ClickHandler

    public init(ocr: @escaping OCRProvider, captureRegion: @escaping RegionCapture, click: @escaping ClickHandler) {
        self.ocr = ocr
        self.captureRegion = captureRegion
        self.click = click
    }

    // MARK: - 检测

    /// 检测是否有 AI 验证（滑块、选图、验证码等）
    public func detectVerification(inWindow frame: CGRect) -> Bool {
        let allTexts = ocr(frame).map { $0.text }
        let combined = allTexts.joined(separator: " ")

        // 颜色+形状组合（图选验证码）
        let colors = ["红", "绿", "蓝", "黄", "白", "黑", "橙", "紫", "灰", "粉"]
        let shapes = VerificationSolver.allShapes

        for c in colors {
            for s in shapes {
                if combined.contains("\(c)色\(s)") || combined.contains("\(c)\(s)") {
                    Logger.warn("检测到图选验证: \(c)色\(s)")
                    return true
                }
            }
        }

        // 通用验证特征
        let aiHints = [
            "安全验证", "人机验证", "滑块验证", "验证码",
            "拖动滑块", "请完成验证", "请选择",
            "请选出", "图中", "下图", "点击以", "按顺序"
        ]
        for hint in aiHints {
            if combined.contains(hint) {
                Logger.warn("检测到 AI 验证: \(hint)")
                return true
            }
        }

        return false
    }

    // MARK: - 自动解决（或等待手动）

    /// 尝试自动完成图选验证，失败则等待手动（60秒超时）
    public func solveOrWait(inWindow frame: CGRect) throws {
        guard detectVerification(inWindow: frame) else { return }

        if tryAutoSolve(inWindow: frame) {
            Logger.success("自动通过图选验证")
            Thread.sleep(forTimeInterval: 2)
            if !detectVerification(inWindow: frame) { return }
            Logger.warn("自动点击后验证仍存在，等待手动...")
        }

        Logger.info("等待手动完成 AI 验证（最多 60 秒）...")
        Notifier.error("易班需要人机验证，请在 60 秒内手动完成")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 3)
            if !detectVerification(inWindow: frame) {
                Logger.info("AI 验证已通过")
                Thread.sleep(forTimeInterval: 1)
                return
            }
        }
        throw AppError.timeout("AI 验证超时")
    }

    // MARK: - 自动识别

    private func tryAutoSolve(inWindow frame: CGRect) -> Bool {
        let allTexts = ocr(frame)
        let combined = allTexts.map { $0.text }.joined(separator: " ")

        let colorMap: [String: NSColor] = [
            "红": .red, "绿": .green, "蓝": .blue,
            "黄": .yellow, "白": .white, "黑": .black,
            "橙": .orange, "紫": .purple,
            "灰": .gray, "粉": .systemPink
        ]

        var targetColor: NSColor?
        var targetShape: String?
        for (name, color) in colorMap {
            if combined.contains("\(name)色") || combined.contains("\(name)") {
                targetColor = color
                Logger.info("目标颜色: \(name)")
                break
            }
        }
        for shape in VerificationSolver.allShapes {
            if combined.contains(shape) {
                targetShape = shape
                Logger.info("目标形状: \(shape)")
                break
            }
        }

        guard let target = targetColor else {
            Logger.info("未识别到目标颜色，无法自动解决")
            return false
        }

        let optionTexts = allTexts.filter { t in
            t.text.trimmingCharacters(in: .whitespaces).count <= 4
        }

        var bestMatch: CGPoint?
        var bestScore: CGFloat = 0

        for option in optionTexts {
            let point = option.point
            let rect = CGRect(x: point.x - 30, y: point.y - 30, width: 60, height: 60)
            guard let screenshot = captureRegion(rect),
                  let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }

            let sampledColor = Self.sampleDominantColor(from: cgImage)
            let colorDist = Self.colorDistance(sampledColor, target)
            guard colorDist < 0.4 else { continue }

            var shapeScore: CGFloat = 0
            if let ts = targetShape, !VerificationSolver.is3DShape.contains(ts) {
                if Self.detectShape(in: cgImage) != ts { shapeScore = 1 }
            }

            let totalScore = colorDist + shapeScore
            if totalScore < bestScore + 0.01 || bestMatch == nil {
                bestScore = totalScore
                bestMatch = point
            }
        }

        if let match = bestMatch, bestScore < 1.0 {
            Logger.info("自动点击匹配项: colorDist=\(String(format: "%.3f", bestScore))")
            _ = click(match)
            return true
        }

        Logger.warn("未找到匹配项 (bestScore=\(String(format: "%.3f", bestScore)))")
        return false
    }

    // MARK: - 形状检测

    public static func detectShape(in cgImage: CGImage) -> String {
        let w = cgImage.width, h = cgImage.height
        guard let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return "未知" }

        let bpp = cgImage.bitsPerPixel / 8
        let stride = cgImage.bytesPerRow

        var pixels: [(x: Int, y: Int)] = []
        for y in 0..<h {
            for x in 0..<w {
                let offset = y * stride + x * bpp
                if Int(bytes[offset]) < 240 || Int(bytes[offset+1]) < 240 || Int(bytes[offset+2]) < 240 {
                    pixels.append((x, y))
                }
            }
        }
        guard pixels.count > 15 else { return "未知" }

        let cx = Double(pixels.map { $0.x }.reduce(0, +)) / Double(pixels.count)
        let cy = Double(pixels.map { $0.y }.reduce(0, +)) / Double(pixels.count)
        let distances = pixels.map { sqrt(pow(Double($0.x)-cx, 2) + pow(Double($0.y)-cy, 2)) }
        let avgDist = distances.reduce(0, +) / Double(distances.count)
        let distVar = distances.map { pow($0 - avgDist, 2) }.reduce(0, +) / Double(distances.count)
        let circularity = distVar / (avgDist * avgDist)

        let minX = Double(pixels.map { $0.x }.min()!), maxX = Double(pixels.map { $0.x }.max()!)
        let minY = Double(pixels.map { $0.y }.min()!), maxY = Double(pixels.map { $0.y }.max()!)
        let boxW = maxX - minX, boxH = maxY - minY
        let ar = boxW / max(boxH, 1)
        let fillRatio = Double(pixels.count) / (boxW * boxH)

        let top = pixels.min(by: { $0.y < $1.y })!, bottom = pixels.max(by: { $0.y < $1.y })!
        let left = pixels.min(by: { $0.x < $1.x })!, right = pixels.max(by: { $0.x < $1.x })!
        let centerY = (Double(top.y) + Double(bottom.y)) / 2
        let centerX = (Double(left.x) + Double(right.x)) / 2
        let vertSpread = abs(Double(top.y) - centerY) / max(boxH / 2, 1)
        let horizSpread = abs(Double(left.x) - centerX) / max(boxW / 2, 1)

        if circularity < 0.03 { return "圆形" }
        if circularity < 0.07 && (ar > 1.3 || ar < 0.7) { return "椭圆" }
        if fillRatio < 0.45 && ar > 0.7 && ar < 1.4 { return "菱形" }
        if vertSpread > 1.3 || horizSpread > 1.3 { return "五角星" }
        if ar > 0.75 && ar < 1.3 { return "正方形" }
        if ar > 1.3 || ar < 0.7 { return "长方形" }
        return "三角形"
    }

    /// 采样图片中心区域的主色调
    public static func sampleDominantColor(from cgImage: CGImage) -> NSColor {
        guard let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return .clear }

        let w = cgImage.width, h = cgImage.height
        let bpp = cgImage.bitsPerPixel / 8
        let stride = cgImage.bytesPerRow

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, count: CGFloat = 0
        let sampleSize = 10
        let startX = max(0, w/2 - sampleSize/2)
        let startY = max(0, h/2 - sampleSize/2)

        for y in startY..<min(h, startY + sampleSize) {
            for x in startX..<min(w, startX + sampleSize) {
                let offset = y * stride + x * bpp
                r += CGFloat(bytes[offset]) / 255.0
                g += CGFloat(bytes[offset+1]) / 255.0
                b += CGFloat(bytes[offset+2]) / 255.0
                count += 1
            }
        }
        return NSColor(red: r/count, green: g/count, blue: b/count, alpha: 1)
    }

    /// 两个颜色的欧几里得距离
    public static func colorDistance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        sqrt(pow(a.redComponent - b.redComponent, 2) +
             pow(a.greenComponent - b.greenComponent, 2) +
             pow(a.blueComponent - b.blueComponent, 2))
    }

    // MARK: - 辅助

    public static let allShapes: [String] = [
        "三角形", "圆形", "正方形", "长方形", "菱形", "梯形", "椭圆",
        "五角星", "六边形", "心形", "五边形", "半圆", "扇形", "月牙形",
        "立方体", "圆柱体", "圆锥体", "球体", "三角体", "三棱锥",
        "长方体", "正方体", "棱柱", "棱锥", "圆台", "半球体"
    ]

    public static let is3DShape: Set<String> = [
        "立方体", "圆柱体", "圆锥体", "球体", "三角体", "三棱锥",
        "长方体", "正方体", "棱柱", "棱锥", "圆台", "半球体"
    ]
}
