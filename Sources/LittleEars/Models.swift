import Foundation
import GRDB

struct LibrarySource: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "sources"
    var id: String
    var path: String
    var bookmark: Data
    var name: String
}
enum TrackNameMode: String, CaseIterable {
    case metadata, filename
    var title: String { self == .metadata ? "元数据标题" : "文件名称" }
}

struct Track: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    static let databaseTableName = "tracks"
    var id: String
    var sourceID: String
    var relativePath: String
    var identity: String
    var title: String
    var duration: Double
    var format: String
    var fileSize: Int64
    var available: Bool
    var folder: String { (relativePath as NSString).deletingLastPathComponent }
    var filename: String { (relativePath as NSString).lastPathComponent }
    func displayName(_ mode: TrackNameMode) -> String {
        let stem = (filename as NSString).deletingPathExtension
        if mode == .filename { return stem.isEmpty ? filename : stem }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (stem.isEmpty ? filename : stem) : title
    }
    func matchesName(_ query: String) -> Bool {
        query.isEmpty || title.localizedCaseInsensitiveContains(query) || filename.localizedCaseInsensitiveContains(query)
    }
}
struct QueueItem: Codable, Identifiable, Sendable, Hashable {
    var id = UUID().uuidString
    var trackID: String
}
enum PlayMode: String, Codable, CaseIterable {
    case sequential, one, all
    var title: String { switch self { case .sequential: "顺序播放"; case .one: "单曲循环"; case .all: "队列循环" } }
    var symbol: String { switch self { case .sequential: "arrow.right"; case .one: "repeat.1"; case .all: "repeat" } }
}
struct PlayerSnapshot: Codable, Sendable {
    var queue: [QueueItem] = []
    var currentID: String?
    var position: Double = 0
    var mode: String = PlayMode.sequential.rawValue
    var volume: Float = 0.7
}
struct ListenSession: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "sessions"
    var id: String
    var trackID: String
    var startedAt: Date
    var endedAt: Date?
    var listenedSeconds: Double = 0
    var completed = false
    var endReason: String?
    var completedDay: String?
    var checkpointAt: Date?
}
struct ListenFragment: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "fragments"
    var id = UUID().uuidString
    var sessionID: String
    var trackID: String
    var day: String
    var seconds: Double
}
struct TrackStat: FetchableRecord, Decodable, Sendable {
    var trackID: String
    var seconds: Double
    var completions: Int
}
struct DailyStat: FetchableRecord, Decodable, Sendable, Identifiable {
    var day: String
    var seconds: Double
    var id: String { day }
}
struct Stats: Sendable {
    var days: [DailyStat] = []
    var tracks: [TrackStat] = []
    var completions = 0
}
struct Coverage {
    private(set) var intervals: [ClosedRange<Double>] = []
    mutating func add(from: Double, to: Double) {
        guard from.isFinite, to.isFinite, to > from else { return }
        var result: [ClosedRange<Double>] = []
        var incoming = max(0, from)...max(0, to)
        for range in intervals {
            if range.upperBound < incoming.lowerBound { result.append(range) }
            else if range.lowerBound > incoming.upperBound { result.append(incoming); incoming = range }
            else { incoming = min(range.lowerBound, incoming.lowerBound)...max(range.upperBound, incoming.upperBound) }
        }
        result.append(incoming)
        intervals = result
    }
    var seconds: Double { intervals.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }
    func qualifies(duration: Double, naturalEnd: Bool) -> Bool { naturalEnd && duration > 0 && seconds / duration >= 0.9 }
}
enum ListeningClock {
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func split(start: Date, seconds: Double, calendar: Calendar = .current) -> [(String, Double)] {
        guard seconds > 0 else { return [] }
        var cursor = start
        let end = start.addingTimeInterval(seconds)
        var result: [(String, Double)] = []
        while cursor < end {
            let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor))!
            let stop = min(end, next)
            result.append((day(cursor, calendar: calendar), stop.timeIntervalSince(cursor)))
            cursor = stop
        }
        return result
    }
}
func timeLabel(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.isFinite ? seconds : 0))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
func listeningLabel(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : minutes > 0 ? "\(minutes) 分钟" : "\(Int(seconds)) 秒"
}

struct Playlist: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    static let databaseTableName = "playlists"
    var id = UUID().uuidString
    var name: String
    var position = 0
    var createdAt = Date()
    var updatedAt = Date()
}
struct PlaylistItem: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    static let databaseTableName = "playlistItems"
    var id = UUID().uuidString
    var playlistID: String
    var trackID: String
    var position: Int
}
struct PlaylistDraft: Identifiable {
    var id = UUID().uuidString
    var playlistID: String?
    var name = ""
    var trackIDs: [String] = []
}

struct TrackDetailsTarget: Identifiable {
    var id: String
    var track: Track?
}
struct TrackStatistics: FetchableRecord, Decodable, Sendable {
    var seconds: Double
    var completions: Int
    var lastPlayedAt: Date?
    var listeningDays: Int
    static let empty = TrackStatistics(seconds: 0, completions: 0, lastPlayedAt: nil, listeningDays: 0)
}
struct TrackListeningRecord: FetchableRecord, Decodable, Sendable, Identifiable {
    var id: String
    var startedAt: Date
    var seconds: Double
    var completed: Bool
}
struct TrackHistoryCursor: Sendable {
    var startedAt: Date
    var id: String
    init(_ record: TrackListeningRecord) { startedAt = record.startedAt; id = record.id }
}
struct TrackHistoryPage: Sendable {
    var records: [TrackListeningRecord]
    var hasMore: Bool
}
struct TrackStatisticsDetails: Sendable {
    var summary: TrackStatistics
    var days: [DailyStat]
    var history: TrackHistoryPage
}
enum TrackStatisticsPeriod: Int, CaseIterable, Identifiable {
    case week = 7, month = 30, all = 0
    var id: Int { rawValue }
    var title: String { switch self { case .week: "最近 7 天"; case .month: "最近 30 天"; case .all: "全部" } }
    func startDay(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard self != .all else { return nil }
        let start = calendar.date(byAdding: .day, value: -(rawValue - 1), to: calendar.startOfDay(for: now))!
        return ListeningClock.day(start, calendar: calendar)
    }
}

struct DailyListeningStat: FetchableRecord, Decodable, Sendable, Identifiable {
    var day: String
    var seconds: Double
    var completions: Int
    var id: String { day }
}
struct YearlyListeningStats: Sendable {
    var days: [DailyListeningStat]
    var years: [Int]
}
struct DailyTrackListeningStat: Sendable, Identifiable {
    var id: String
    var track: Track?
    var seconds: Double
    var completions: Int
}
struct DailyListeningDetails: Sendable {
    var day: String
    var seconds: Double
    var completions: Int
    var tracks: [DailyTrackListeningStat]
}

func listeningDateLabel(_ date: Date) -> String {
    date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}
