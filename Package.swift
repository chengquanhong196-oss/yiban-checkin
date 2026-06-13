// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "yiban-checkin",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // 共用核心库
        .target(
            name: "YibanCheckinCore",
            path: "Sources/Core",
            sources: [
                "AppAutomator.swift",
                "CheckinHistory.swift",
                "CheckinOrchestrator.swift",
                "CloudService.swift",
                "Config.swift",
                "Keychain.swift",
                "Logger.swift",
                "SchoolDatabase.swift",
                "LocationChecker.swift",
                "Notifier.swift",
                "PermissionChecker.swift",
                "ScreenCapture.swift",
                "VerificationSolver.swift",
                "YibanAPI.swift"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreLocation"),
            ]
        ),

        // CLI 可执行文件（保持向后兼容）
        .executableTarget(
            name: "yiban-checkin",
            dependencies: ["YibanCheckinCore"],
            path: "Sources/CLI",
            sources: [
                "main.swift"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreLocation"),
            ]
        ),

        // GUI macOS App（含 Sparkle 自动更新）
        .executableTarget(
            name: "YibanCheckin",
            dependencies: ["YibanCheckinCore"],
            path: "Sources/GUI",
            sources: [
                "YibanCheckinApp.swift",
                "ContentView.swift",
                "DashboardView.swift",
                "LogViewer.swift",
                "CheckinManager.swift",
                "MenuBarController.swift",
                "AppUpdater.swift",
                "OnboardingView.swift",
                "SchoolPickerView.swift"
            ],
            resources: [
                .copy("Resources/AppIcon.icns")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("ServiceManagement"),
            ]
        ),

        // 测试
        .testTarget(
            name: "YibanCheckinTests",
            dependencies: ["YibanCheckinCore"],
            path: "Tests/YibanCheckinTests"
        ),
    ]
)
