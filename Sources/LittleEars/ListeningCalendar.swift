import Foundation

struct ListeningCalendarDay: Identifiable, Sendable {
    var date: Date
    var id: String
    var column: Int
    var row: Int
    var isToday: Bool
    var isFuture: Bool
}
struct ListeningCalendar {
    let days: [ListeningCalendarDay]
    let columns: Int
    let startDay: String
    let endDayExclusive: String
    func moving(from id: String, dayOffset: Int) -> ListeningCalendarDay? {
        guard let index = days.firstIndex(where: { $0.id == id }) else { return nil }
        let next = min(days.count - 1, max(0, index + dayOffset))
        return days[next].isFuture ? nil : days[next]
    }
    init(year: Int, calendar: Calendar = .current, today: Date = Date()) {
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let end = calendar.date(byAdding: .year, value: 1, to: start)!
        let offset = (calendar.component(.weekday, from: start) + 5) % 7
        let todayStart = calendar.startOfDay(for: today)
        var values: [ListeningCalendarDay] = []
        var date = start
        while date < end {
            let index = values.count + offset
            values.append(ListeningCalendarDay(date: date, id: ListeningClock.day(date, calendar: calendar), column: index / 7, row: index % 7, isToday: calendar.isDate(date, inSameDayAs: todayStart), isFuture: date > todayStart))
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        days = values; columns = (values.count + offset + 6) / 7
        startDay = ListeningClock.day(start, calendar: calendar); endDayExclusive = ListeningClock.day(end, calendar: calendar)
    }
}
enum ListeningHeatmapMetric: String, CaseIterable, Identifiable {
    case duration, completions
    var id: String { rawValue }
    var title: String { self == .duration ? "播放时长" : "完整播放次数" }
    static let durationThresholds: [Double] = [15 * 60, 30 * 60, 60 * 60]
    static let completionThresholds = [3, 6, 11]
    func level(_ day: DailyListeningStat) -> Int {
        switch self {
        case .duration:
            guard day.seconds > 0 else { return 0 }
            return 1 + Self.durationThresholds.filter { day.seconds >= $0 }.count
        case .completions:
            guard day.completions > 0 else { return 0 }
            return 1 + Self.completionThresholds.filter { day.completions >= $0 }.count
        }
    }
}
