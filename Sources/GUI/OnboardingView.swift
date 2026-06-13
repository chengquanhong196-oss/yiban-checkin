import SwiftUI
import YibanCheckinCore

// MARK: - 首次启动引导向导

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompleted = false
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            // 步骤指示器
            HStack(spacing: 0) {
                Spacer()
                ForEach(0..<4) { i in
                    Circle()
                        .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 10, height: 10)
                    if i < 3 {
                        Rectangle()
                            .fill(i < step ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(height: 2).frame(width: 32)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            // 步骤内容
            Group {
                switch step {
                case 0: WelcomeStep(next: { step = 1 })
                case 1: PermissionsStep(next: { step = 2 })
                case 2: SchoolStep(next: { step = 3 })
                case 3: AccountStep(done: { hasCompleted = true })
                default: EmptyView()
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: step)
        .frame(minWidth: 460, minHeight: 380)
    }
}

// MARK: - Step 0: Welcome

struct WelcomeStep: View {
    let next: () -> Void
    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 56)).foregroundColor(.accentColor)
            Text("欢迎使用易班签到")
                .font(.title).fontWeight(.bold)
            Text("自动完成每晚签到，再也不怕忘记。\nMac 在时本地签，Mac 不在云端签。")
                .font(.body).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("开始设置") { next() }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Spacer().frame(height: 40)
        }
    }
}

// MARK: - Step 1: Permissions

struct PermissionsStep: View {
    let next: () -> Void
    @State private var axOK = PermissionChecker.accessibility == .granted
    @State private var locOK = PermissionChecker.location != .denied

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("权限检查").font(.title).fontWeight(.bold)
            Text("签到需要以下两项权限").font(.body).foregroundColor(.secondary)

            VStack(spacing: 12) {
                PermissionRow(
                    icon: "accessibility",
                    title: "辅助功能权限",
                    desc: "用于模拟鼠标点击，自动操作易班 App",
                    ok: axOK,
                    fixAction: {
                        PermissionChecker.requestAccessibilityPermission()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { refresh() }
                    }
                )
                PermissionRow(
                    icon: "location.fill",
                    title: "定位权限",
                    desc: "用于判断是否在校区范围内",
                    ok: locOK,
                    fixAction: { PermissionChecker.openLocationSettings() }
                )
            }

            Text(axOK && locOK ? "一切就绪" : "请先开启上方权限再继续")
                .font(.callout).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer(minLength: 24)

            HStack {
                Button("跳过") { next() }.buttonStyle(.bordered).controlSize(.large)
                Spacer()
                Button("我已开启，继续") { next() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(.horizontal, 40).padding(.vertical, 32)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        axOK = PermissionChecker.accessibility == .granted
        locOK = PermissionChecker.location != .denied
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let desc: String
    let ok: Bool
    let fixAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3)
                .foregroundColor(ok ? .green : .orange).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).fontWeight(.medium)
                Text(desc).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if ok {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            } else {
                Button("开启…") { fixAction() }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(12).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Step 2: School

struct SchoolStep: View {
    let next: () -> Void
    @State private var school = ""
    @State private var campus = ""
    @State private var lat = ""
    @State private var lng = ""
    @State private var act = ""
    @State private var clientId = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置学校").font(.title).fontWeight(.bold)
            Text("搜索并选择你的学校，坐标和校本化参数将自动填入。")
                .font(.body).foregroundColor(.secondary)

            SchoolPicker(schoolName: $school, campusName: $campus,
                         lat: $lat, lng: $lng, act: $act, clientId: $clientId)

            Spacer(minLength: 24)

            HStack {
                Button("回头再说") { next() }.buttonStyle(.bordered).controlSize(.large)
                Spacer()
                Button(action: { saveAndNext() }) {
                    Text("保存并继续")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(.horizontal, 40).padding(.vertical, 32)
    }

    private func saveAndNext() {
        var c = Config.load()
        c.schoolName = school; c.campusName = campus
        c.campusLatitude = Double(lat) ?? c.campusLatitude
        c.campusLongitude = Double(lng) ?? c.campusLongitude
        c.yibanAct = act; c.yibanClientId = clientId
        c.save()
        next()
    }
}
// MARK: - Step 3: Account

struct AccountStep: View {
    let done: () -> Void
    @State private var phone = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("配置账号").font(.title).fontWeight(.bold)
            Text("填写易班登录信息，用于自动签到。\n密码通过 Keychain 安全存储，不会上传。")
                .font(.body).foregroundColor(.secondary)

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("手机号").font(.caption).foregroundColor(.secondary)
                    TextField("11 位手机号", text: $phone).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("密码").font(.caption).foregroundColor(.secondary)
                    SecureField("易班密码", text: $password).textFieldStyle(.roundedBorder)
                }
            }

            Spacer(minLength: 24)

            HStack {
                Button("跳过") { done() }.buttonStyle(.bordered).controlSize(.large)
                Spacer()
                Button(action: { saveAndDone() }) {
                    Text("开始使用")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(.horizontal, 40).padding(.vertical, 32)
    }

    private func saveAndDone() {
        var c = Config.load()
        c.yibanUsername = phone
        c.yibanPassword = password  // 走 Keychain
        c.save()
        done()
    }
}
