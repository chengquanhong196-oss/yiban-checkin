import Foundation

// MARK: - 签到历史统计（解析日志文件）

public struct CheckinHistory {

    /// 单日记录
    public struct DayRecord {
        public let date: String       // yyyy-MM-dd
        public let success: Bool
        public let method: String     // "API" 或 "OCR"
        public let time: String       // HH:mm
    }

    /// 获取本月所有签到记录
    public static func thisMonth() -> [DayRecord] {
        let all = allRecords()
        let prefix = monthPrefix()
        return all.filter { $0.date.hasPrefix(prefix) }
    }

    /// 本月签到成功天数
    public static func successDaysThisMonth() -> Int {
        thisMonth().filter(\.success).count
    }

    /// 本月总天数
    public static func daysPassedThisMonth() -> Int {
        let calendar = Calendar.current
        guard let range = calendar.range(of: .day, in: .month, for: Date()) else { return 30 }
        return range.count
    }

    /// 当前连续签到天数（从今天往前数）
    public static func currentStreak() -> Int {
        let all = allRecords()
        var streak = 0
        let calendar = Calendar.current
        let today = Date()

        // 检查今天是否已签到
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let todayStr = df.string(from: today)
        let todaySuccess = all.contains { $0.date == todayStr && $0.success }

        // 如果今天还没签到，从昨天开始算
        var checkDate = todaySuccess ? today : calendar.date(byAdding: .day, value: -1, to: today)!

        while true {
            let dateStr = df.string(from: checkDate)
            if all.contains(where: { $0.date == dateStr && $0.success }) {
                streak += 1
                checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate)!
            } else {
                // 如果这一天还没有记录（还没到签到时间），继续往前看
                let todayStart = calendar.startOfDay(for: Date())
                let checkStart = calendar.startOfDay(for: checkDate)
                if checkStart >= todayStart { break } // 今天没签到但还没过，不算断
                break
            }
        }
        return streak
    }

    /// 最近 7 天的状态（今天排最前）
    public static func last7Days() -> [(date: String, weekday: String, success: Bool)] {
        let all = allRecords()
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let wf = DateFormatter(); wf.dateFormat = "EEE"
        wf.locale = Locale(identifier: "zh_CN")

        var result: [(String, String, Bool)] = []
        let calendar = Calendar.current
        for i in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let dateStr = df.string(from: date)
            let success = all.contains { $0.date == dateStr && $0.success }
            result.append((dateStr, wf.string(from: date), success))
        }
        return result
    }

    // MARK: - 私有

    private static func allRecords() -> [DayRecord] {
        guard let content = try? String(contentsOf: Logger.logFile, encoding: .utf8) else { return [] }

        var records: [DayRecord] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let lines = content.components(separatedBy: "\n")
        for line in lines {
            guard line.count > 19 else { continue }
            let ts = String(line.prefix(19)) // [yyyy-MM-dd HH:mm:ss]
            guard let date = dateFormatter.date(from: ts) else { continue }

            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            let dateStr = df.string(from: date)
            let tf = DateFormatter(); tf.dateFormat = "HH:mm"
            let timeStr = tf.string(from: date)

            let isSuccess = line.contains("签到成功")
            let isAPI = line.contains("[API]")
            let previous = records.last
            // 同一天只保留成功的记录，或最后一次失败
            if let prev = previous, prev.date == dateStr {
                if isSuccess || (!prev.success) {
                    records.removeLast()
                } else {
                    continue
                }
            }

            records.append(DayRecord(
                date: dateStr,
                success: isSuccess,
                method: isAPI ? "API" : line.contains("[OCR]") ? "OCR" : "—",
                time: timeStr
            ))
        }
        return records
    }

    private static func monthPrefix() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"
        return f.string(from: Date())
    }
}
