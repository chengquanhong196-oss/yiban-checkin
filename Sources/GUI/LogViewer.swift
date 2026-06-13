import SwiftUI

struct LogViewer: View {
    @EnvironmentObject var checkinManager: CheckinManager
    @State private var autoRefresh = true
    @State private var timer: Timer? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 工具栏
            HStack {
                Text("签到日志")
                    .font(.title)
                    .fontWeight(.bold)

                Spacer()

                Toggle("自动刷新", isOn: $autoRefresh)
                    .toggleStyle(.switch)
                    .onChange(of: autoRefresh) { enabled in
                        if enabled {
                            startAutoRefresh()
                        } else {
                            stopAutoRefresh()
                        }
                    }

                Button(action: { checkinManager.clearLogs() }) {
                    HStack {
                        Image(systemName: "trash")
                        Text("清空")
                    }
                }
                .buttonStyle(.borderless)

                Button(action: { checkinManager.refreshLogs() }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("刷新")
                    }
                }
                .buttonStyle(.borderless)
            }

            // 日志内容
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if checkinManager.logLines.isEmpty {
                            Text("暂无日志")
                                .foregroundColor(.secondary)
                                .padding()
                        } else {
                            ForEach(Array(checkinManager.logLines.enumerated()), id: \.offset) { _, line in
                                LogLineView(line: line)
                            }
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                )
                .onChange(of: checkinManager.logLines.count) { _ in
                    if let last = checkinManager.logLines.indices.last {
                        scrollProxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }

            HStack {
                Text("\(checkinManager.logLines.count) 行日志")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("日志文件: ~/Library/Logs/yiban-checkin.log")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .onAppear {
            checkinManager.refreshLogs()
            if autoRefresh { startAutoRefresh() }
        }
        .onDisappear {
            stopAutoRefresh()
        }
    }

    private func startAutoRefresh() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in checkinManager.refreshLogs() }
        }
    }

    private func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }
}

struct LogLineView: View {
    let line: String

    var body: some View {
        Text(line)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(colorForLine(line))
            .lineLimit(1)
    }

    private func colorForLine(_ line: String) -> Color {
        if line.contains("SUCCESS") || line.contains("成功") || line.contains("✅") {
            return .green
        }
        if line.contains("ERROR") || line.contains("失败") || line.contains("✗") {
            return .orange
        }
        if line.contains("WARN") {
            return .orange
        }
        return .primary
    }
}
