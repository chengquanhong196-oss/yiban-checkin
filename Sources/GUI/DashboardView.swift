import SwiftUI
import YibanCheckinCore

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var checkinManager: CheckinManager
    @State private var todayStatus: String = "检查中..."
    @State private var countdown: String = "--:--:--"
    @State private var countdownColor: Color = .secondary
    @State private var checkinMethod: String = Config.load().checkinMethod
    @State private var schoolName: String = Config.load().schoolName
    @State private var campusName: String = Config.load().campusName
    @State private var showSchoolSheet = false
    @State private var showStats = false

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 28) {
                statusHeader

                // ── 签到按钮 ──
                checkinButton

                // ── 信息卡片 ──
                infoRow

                // ── 学校 ──
                schoolButton

                // ── 7天 + 统计 ──
                WeekStrip()
                    .padding(.horizontal, 4)

                // ── 签到结果 ──
                if let result = checkinManager.lastResult {
                    resultBanner(result)
                }

                // ── 诊断（可折叠） ──
                DiagnosticPanel()
            }
            .padding(28)
        }
        .frame(maxWidth: 480)
        .onAppear {
            todayStatus = checkinManager.checkTodayStatus()
            Task { await checkinManager.refreshLocation() }
            updateCountdown()
        }
        .onReceive(timer) { _ in updateCountdown() }
        .sheet(isPresented: $showSchoolSheet) {
            SchoolConfigSheet(schoolName: $schoolName, campusName: $campusName,
                              onSave: { refreshConfig() })
        }
    }

    // MARK: - Status Header

    var statusHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(statusColor.opacity(0.10)).frame(width: 52, height: 52)
                Image(systemName: statusIcon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(statusColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.headline)
                if todayStatus != "已签到" {
                    Text(countdown)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundColor(countdownColor)
                } else {
                    Text("今日已完成")
                        .font(.subheadline).foregroundColor(.green)
                }
            }

            Spacer()
        }
    }

    // MARK: - Check-in Button

    var checkinButton: some View {
        Button(action: {
            Task {
                await checkinManager.performManualCheckin()
                todayStatus = checkinManager.checkTodayStatus()
            }
        }) {
            HStack(spacing: 8) {
                if checkinManager.isCheckingIn {
                    ProgressView().scaleEffect(0.8).controlSize(.small)
                    Text("签到中…")
                } else {
                    Text(todayStatus == "已签到" ? "重新签到" : "立即签到")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(checkinManager.isCheckingIn)
        .tint(todayStatus == "已签到" ? .green : .accentColor)
    }

    // MARK: - Info Row

    var infoRow: some View {
        HStack(spacing: 0) {
            InfoCell(icon: "location.fill", label: "距校区",
                     value: checkinManager.currentDistance ?? "--")
            Divider().frame(height: 32)
            InfoCell(icon: "clock.fill", label: "签到时段",
                     value: {
                        let c = Config.load()
                        return "\(String(format: "%02d:%02d", c.checkinStartHour, c.checkinStartMinute))–\(String(format: "%02d:%02d", c.checkinEndHour, c.checkinEndMinute))"
                     }())
            Divider().frame(height: 32)
            InfoCell(icon: "bolt.fill", label: "方式",
                     value: checkinMethod == "ocr" ? "OCR" : "API")
        }
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - School Button

    var schoolButton: some View {
        Button(action: { showSchoolSheet = true }) {
            HStack(spacing: 10) {
                Image(systemName: "building.columns.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                Text(schoolDisplayName)
                    .font(.subheadline)
                Spacer()
                Text("设置").font(.caption).foregroundColor(.accentColor)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var schoolDisplayName: String {
        if schoolName.isEmpty { return "点击设置学校" }
        return "\(schoolName)\(campusName)校区"
    }

    // MARK: - Result Banner

    func resultBanner(_ result: CheckinManager.CheckinResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.systemImage)
                .foregroundColor(result.color).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).fontWeight(.medium)
                if let t = checkinManager.lastCheckinTime {
                    Text(t).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(result.color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .transition(.opacity)
    }

    // MARK: - Helpers

    private func updateCountdown() {
        let config = Config.load()
        let now = Date()
        var comps = DateComponents()
        comps.hour = config.checkinStartHour; comps.minute = config.checkinStartMinute
        guard let target = Calendar.current.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) else {
            countdown = "--:--:--"; return
        }
        let diff = target.timeIntervalSince(now)
        if diff <= 0 { countdown = "进行中"; countdownColor = .green }
        else if diff < 600 { countdownColor = .orange }
        else if diff < 3600 { countdownColor = .blue }
        else { countdownColor = .secondary }
        countdown = formatInterval(diff)
    }

    private func formatInterval(_ secs: TimeInterval) -> String {
        let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60, s = Int(secs) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private func refreshConfig() {
        let c = Config.load()
        schoolName = c.schoolName; campusName = c.campusName; checkinMethod = c.checkinMethod
    }

    private var statusTitle: String {
        todayStatus == "已签到" ? "今日已签到" : todayStatus == "签到失败" ? "等待下次签到" : "等待签到"
    }
    private var statusIcon: String {
        todayStatus == "已签到" ? "checkmark" : "clock"
    }
    private var statusColor: Color {
        todayStatus == "已签到" ? .green : todayStatus == "签到失败" ? .orange : .blue
    }
}

// MARK: - Info Cell

struct InfoCell: View {
    let icon: String; let label: String; let value: String
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 13)).foregroundColor(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold))
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

// MARK: - Week Strip

struct WeekStrip: View {
    @State private var days: [(date: String, weekday: String, success: Bool)] = []
    @State private var streak: Int = 0
    @State private var monthSuccess: Int = 0
    @State private var monthTotal: Int = 0

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(days, id: \.date) { day in
                    VStack(spacing: 4) {
                        Text(day.weekday).font(.system(size: 9)).foregroundColor(.secondary)
                        ZStack {
                            Circle()
                                .fill(day.success ? Color.green.opacity(0.12) : Color.secondary.opacity(0.06))
                                .frame(width: 24, height: 24)
                            if day.success {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: 16) {
                Label("连续 \(streak) 天", systemImage: "flame.fill")
                    .font(.caption2).foregroundColor(.orange)
                Label("本月 \(monthSuccess)/\(monthTotal) 天", systemImage: "calendar")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .onAppear {
            days = CheckinHistory.last7Days()
            streak = CheckinHistory.currentStreak()
            monthSuccess = CheckinHistory.successDaysThisMonth()
            monthTotal = CheckinHistory.daysPassedThisMonth()
        }
    }
}

// MARK: - Diagnostic Panel

struct DiagnosticPanel: View {
    @State private var diagnostics: PermissionChecker.DiagnosticResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: allOK ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 14)).foregroundColor(allOK ? .green : .orange)
                Text(allOK ? "一切就绪" : "\(badCount) 项待处理")
                    .font(.callout).fontWeight(.medium).foregroundColor(.secondary)
                Spacer()
            }

            if let d = diagnostics {
                VStack(spacing: 2) {
                    DiagRow(ok: d.locationOK, label: "定位权限",
                            fix: "开启…", fixAction: { PermissionChecker.openLocationSettings() })
                    DiagRow(ok: d.canLaunchApp, label: "易班已安装",
                            fix: "安装", fixAction: { NSWorkspace.shared.open(URL(string: "https://apps.apple.com/cn/app/id1146968687")!) })
                    DiagRow(ok: d.accessibilityOK, label: "辅助功能权限",
                            fix: "授权", fixAction: { PermissionChecker.requestAccessibilityPermission() })
                    DiagRow(ok: d.configOK, label: "账号配置",
                            fix: "设置", fixAction: {
                                NotificationCenter.default.post(name: .openSettings, object: nil)
                            })
                }
            }
        }
        .padding(14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { refreshDiag() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshDiag()
        }
    }

    private func refreshDiag() { diagnostics = PermissionChecker.runDiagnostics(config: Config.load()) }

    private var allOK: Bool {
        guard let d = diagnostics else { return true }
        return d.accessibilityOK && d.locationOK && d.configOK && d.canLaunchApp
    }
    private var badCount: Int {
        guard let d = diagnostics else { return 0 }
        return [d.accessibilityOK, d.locationOK, d.configOK, d.canLaunchApp].filter { !$0 }.count
    }
}

struct DiagRow: View {
    let ok: Bool; let label: String; let fix: String; let fixAction: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13)).foregroundColor(ok ? .green : .secondary.opacity(0.3))
            Text(label).font(.callout).foregroundColor(ok ? .secondary : .primary)
            Spacer()
            if !ok {
                Button(fix) { fixAction() }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - School Config Sheet

struct SchoolConfigSheet: View {
    @Binding var schoolName: String
    @Binding var campusName: String
    let onSave: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var lat = ""; @State private var lng = ""
    @State private var act = ""; @State private var clientId = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("修改学校").font(.title2).fontWeight(.bold); Spacer(); Button("取消") { dismiss() }.buttonStyle(.bordered).controlSize(.small) }

            SchoolPicker(schoolName: $schoolName, campusName: $campusName,
                         lat: $lat, lng: $lng, act: $act, clientId: $clientId)

            if act.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledField("校本化 App ID") { TextField("iapp...", text: $act).textFieldStyle(.roundedBorder) }
                    LabeledField("OAuth Client ID") { TextField("必填", text: $clientId).textFieldStyle(.roundedBorder) }
                    Text("不同学校有不同参数，可从学校易班管理员处获取，或通过抓包易班 App 获取。").font(.caption2).foregroundColor(.secondary)
                }
            }

            Button(action: { saveAndClose() }) { Text("保存").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(24).frame(width: 440, height: 480)
        .onAppear {
            let c = Config.load()
            lat = c.campusLatitude == 0 ? "" : String(c.campusLatitude)
            lng = c.campusLongitude == 0 ? "" : String(c.campusLongitude)
            act = c.yibanAct; clientId = c.yibanClientId
        }
    }
    private func saveAndClose() {
        var c = Config.load(); c.schoolName = schoolName; c.campusName = campusName
        c.campusLatitude = Double(lat) ?? c.campusLatitude; c.campusLongitude = Double(lng) ?? c.campusLongitude
        c.yibanAct = act; c.yibanClientId = clientId; c.save(); onSave(); dismiss()
    }
}

// MARK: - CheckinResult helpers

extension CheckinManager.CheckinResult {
    var title: String {
        switch self { case .success: return "签到成功"; case .failure(let r): return r; case .skipped(let r): return r }
    }
    var systemImage: String {
        switch self { case .success: return "checkmark.circle.fill"; case .failure: return "xmark.circle.fill"; case .skipped: return "slash.circle.fill" }
    }
    var color: Color {
        switch self { case .success: return .green; case .failure: return .orange; case .skipped: return .secondary }
    }
}
