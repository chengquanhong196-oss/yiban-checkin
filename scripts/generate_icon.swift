#!/usr/bin/env swift
import Cocoa

/// 生成 ChatGPT 风格的易班签到图标
/// 圆角六边形 + 渐变 + 白色对勾

let sizes = [
    ("icon_16x16",     16),
    ("icon_16x16@2x",  32),
    ("icon_32x32",     32),
    ("icon_32x32@2x",  64),
    ("icon_128x128",  128),
    ("icon_128x128@2x",256),
    ("icon_256x256",  256),
    ("icon_256x256@2x",512),
    ("icon_512x512",  512),
    ("icon_512x512@2x",1024),
]

let outDir = "/tmp/yiban_icon.iconset"
try? FileManager.default.removeItem(atPath: outDir)
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for (name, size) in sizes {
    let s = CGFloat(size)
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let image = NSImage(size: rect.size)

    image.lockFocus()

    // 背景
    let bgPath = NSBezierPath()
    // 圆角六边形 — 用圆角矩形近似（ChatGPT 风格）
    let inset = s * 0.12
    let bgRect = rect.insetBy(dx: inset, dy: inset)
    let cornerRadius = s * 0.22
    bgPath.appendRoundedRect(bgRect, xRadius: cornerRadius, yRadius: cornerRadius)

    // 渐变填充
    let gradient = NSGradient(colors: [
        NSColor(red: 0.11, green: 0.75, blue: 0.55, alpha: 1.0),  // teal
        NSColor(red: 0.15, green: 0.55, blue: 0.85, alpha: 1.0),  // blue
    ])
    gradient?.draw(in: bgPath, angle: 135)

    // 内部微光
    let innerGlow = NSBezierPath()
    let glowInset = inset + s * 0.04
    let glowRect = rect.insetBy(dx: glowInset, dy: glowInset)
    let glowRadius = cornerRadius - s * 0.02
    innerGlow.appendRoundedRect(glowRect, xRadius: glowRadius, yRadius: glowRadius)
    NSColor.white.withAlphaComponent(0.08).setStroke()
    innerGlow.lineWidth = s * 0.015
    innerGlow.stroke()

    // 对勾
    let checkPath = NSBezierPath()
    let cx = s / 2
    let cy = s / 2
    let w = s * 0.42
    let h = s * 0.30
    let startX = cx - w * 0.45
    let startY = cy + h * 0.05
    let midX   = cx - w * 0.1
    let midY   = cy + h * 0.45
    let endX   = cx + w * 0.5
    let endY   = cy - h * 0.45

    checkPath.move(to: NSPoint(x: startX, y: startY))
    checkPath.line(to: NSPoint(x: midX, y: midY))
    checkPath.line(to: NSPoint(x: endX, y: endY))
    checkPath.lineWidth = s * 0.09
    checkPath.lineCapStyle = .round
    checkPath.lineJoinStyle = .round
    NSColor.white.setStroke()
    checkPath.stroke()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("❌ 生成失败: \(name)")
        continue
    }
    try png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    print("✅ \(name).png (\(size)×\(size))")
}

// 打包为 .icns
let icnsPath = "/tmp/yiban_icon.icns"
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", outDir, "-o", icnsPath]
task.launch()
task.waitUntilExit()

if task.terminationStatus == 0 {
    print("\n🎉 图标已生成: \(icnsPath)")
    // 复制到项目（相对于脚本所在目录）
    let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let dest = scriptDir.appendingPathComponent("../Assets.xcassets/AppIcon.appiconset").path
    try? FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(atPath: "\(dest)/app_icon.icns")
    try FileManager.default.copyItem(atPath: icnsPath, toPath: "\(dest)/app_icon.icns")
    print("📁 已复制到 Xcode 资源目录")
} else {
    print("❌ iconutil 失败: \(task.terminationStatus)")
}
