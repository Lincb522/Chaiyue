import Foundation
import Observation

/// 阅读时长统计：按天累计阅读器处于前台的秒数
@Observable
final class ReadingStats {
    private static let key = "stats.seconds"
    private(set) var seconds: [String: Int]
    @ObservationIgnored private var sessionStart: Date?

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        seconds = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Int] ?? [:]
    }

    func begin() {
        if sessionStart == nil { sessionStart = Date() }
    }

    func end() {
        guard let start = sessionStart else { return }
        sessionStart = nil
        // 单次超过 3 小时视为挂机，只记 3 小时
        let elapsed = min(Date().timeIntervalSince(start), 3 * 3600)
        guard elapsed >= 1 else { return }
        seconds[Self.formatter.string(from: Date()), default: 0] += Int(elapsed)
    }

    func flush() {
        if sessionStart != nil {
            end()
            begin()
        }
        UserDefaults.standard.set(seconds, forKey: Self.key)
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        return c
    }

    var todayMinutes: Int {
        (seconds[Self.formatter.string(from: Date())] ?? 0) / 60
    }

    /// 本周（周一起）每天的分钟数
    var weekMinutes: [Int] {
        let today = calendar.startOfDay(for: Date())
        let weekday = (calendar.component(.weekday, from: today) + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -weekday, to: today) else { return Array(repeating: 0, count: 7) }
        return (0..<7).map { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: monday) else { return 0 }
            return (seconds[Self.formatter.string(from: day)] ?? 0) / 60
        }
    }

    var todayIndex: Int {
        (calendar.component(.weekday, from: Date()) + 5) % 7
    }

    var weekHours: Double {
        Double(weekMinutes.reduce(0, +)) / 60
    }
}
