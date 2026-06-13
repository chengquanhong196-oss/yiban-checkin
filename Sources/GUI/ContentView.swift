import SwiftUI
import YibanCheckinCore

struct ContentView: View {
    @EnvironmentObject var checkinManager: CheckinManager
    @State private var showSettings = false

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("状态", systemImage: "checkmark.shield") }

            LogViewer()
                .tabItem { Label("日志", systemImage: "doc.text") }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
        }
    }
}

// MARK: - Settings as a Sheet (macOS-native pattern)

struct SettingsSheet: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("设置").font(.title2).fontWeight(.bold)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    LocalAccountSection()
                    Divider().padding(.horizontal, 24)
                    CloudAccountSection()
                    Divider().padding(.horizontal, 24)
                    GeneralSection()
                }
                .padding(.vertical, 20)
            }
        }
        .frame(width: 400, height: 440)
    }
}

// MARK: - Settings Sections

struct LocalAccountSection: View {
    @State private var config = Config.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("本地账号", systemImage: "person.fill").font(.headline).padding(.horizontal, 24)

            VStack(spacing: 10) {
                LabeledField("手机号") { TextField("", text: $config.yibanUsername).textFieldStyle(.roundedBorder).onChange(of: config.yibanUsername) { _ in config.save() } }
                LabeledField("密码") { SecureField("", text: Binding(
                    get: { config.yibanPassword },
                    set: { config.yibanPassword = $0; config.save() }
                )).textFieldStyle(.roundedBorder) }
                Text("密码通过 Keychain 安全存储，不上传").font(.caption2).foregroundColor(.secondary)
            }
            .padding(.horizontal, 24)

            Label("学校信息", systemImage: "building.columns.fill").font(.headline).padding(.horizontal, 24).padding(.top, 8)

            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    LabeledField("学校") { TextField("", text: $config.schoolName).textFieldStyle(.roundedBorder) }
                    LabeledField("校区") { TextField("", text: $config.campusName).textFieldStyle(.roundedBorder) }
                }
                HStack(spacing: 12) {
                    LabeledField("纬度") { TextField("", value: $config.campusLatitude, format: .number).textFieldStyle(.roundedBorder) }
                    LabeledField("经度") { TextField("", value: $config.campusLongitude, format: .number).textFieldStyle(.roundedBorder) }
                }
            }
            .padding(.horizontal, 24)

            Text("修改后自动保存").font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 24)
        }
    }
}

struct CloudAccountSection: View {
    @StateObject private var cloud = CloudService.shared
    @State private var email = ""
    @State private var password = ""
    @State private var serverURL = ""
    @State private var isRegistering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("云同步", systemImage: "cloud.fill").font(.headline).padding(.horizontal, 24)

            if cloud.isLoggedIn, let profile = cloud.profile {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.email).font(.callout).fontWeight(.medium)
                        Text(tierLabel(profile)).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("退出", role: .destructive) { cloud.logout() }
                }
                .padding(.horizontal, 24)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("部署后端后，登录即可开启云签到（Mac 关机也能签）")
                        .font(.caption).foregroundColor(.secondary)

                    LabeledField("服务器地址") {
                        HStack {
                            TextField("https://你的域名.com", text: $serverURL)
                                .textFieldStyle(.roundedBorder)
                            Button("保存") {
                                UserDefaults.standard.set(serverURL, forKey: "cloud_server_url")
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        LabeledField("邮箱") {
                            TextField("your@email.com", text: $email).textFieldStyle(.roundedBorder)
                        }
                        LabeledField("密码") {
                            SecureField("至少6位", text: $password).textFieldStyle(.roundedBorder)
                        }
                    }

                    HStack(spacing: 8) {
                        Button("登录") {
                            Task { _ = try? await cloud.login(email: email, password: password) }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(email.isEmpty || password.count < 6)
                        Button("注册") {
                            Task { _ = try? await cloud.register(email: email, password: password) }
                        }
                        .disabled(email.isEmpty || password.count < 6)
                    }

                    if let err = cloud.lastError {
                        Text(err).font(.caption).foregroundColor(.red)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
        .onAppear { serverURL = cloud.baseURL }
    }

    private func tierLabel(_ p: UserProfile) -> String {
        p.subscription_active ? p.tier : "免费"
    }
}

struct GeneralSection: View {
    @AppStorage("autoCheckForUpdates") private var autoCheck = true
    @State private var logLevel: Int = Config.load().logLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("通用", systemImage: "gearshape").font(.headline).padding(.horizontal, 24)

            VStack(spacing: 8) {
                Toggle("自动检查更新", isOn: $autoCheck).padding(.horizontal, 24)
                HStack {
                    Text("日志级别").font(.body)
                    Picker("", selection: $logLevel) {
                        Text("调试").tag(0 as Int)
                        Text("信息").tag(1 as Int)
                        Text("警告").tag(2 as Int)
                        Text("错误").tag(3 as Int)
                    }
                    .pickerStyle(.segmented).frame(width: 240)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .onChange(of: logLevel) { lv in
                    var c = Config.load(); c.logLevel = lv; c.save()
                }
            }

            VStack(spacing: 6) {
                Button(action: { AppUpdater.shared.checkForUpdates() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                        Text("检查更新").font(.callout)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button(action: {
                    let result = PermissionChecker.runDiagnostics(config: Config.load())
                    let alert = NSAlert()
                    alert.messageText = result.issues.isEmpty ? "✅ 一切就绪" : "⚠️ 发现问题"
                    alert.informativeText = result.issues.joined(separator: "\n")
                    alert.runModal()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "stethoscope")
                        Text("运行诊断").font(.callout)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Shared Helpers

struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    init(_ label: String, @ViewBuilder content: @escaping () -> Content) { self.label = label; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundColor(.secondary)
            content()
        }
    }
}
