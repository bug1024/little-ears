import XCTest
import GRDB
@testable import LittleEars

final class FeatureTests: XCTestCase {
    @MainActor
    func testSleepDeadlineReplacementCancellationAndWallClock() {
        var now = Date(timeIntervalSince1970: 1000)
        let timer = SleepTimerManager(now: { now }, automatic: false)
        var expirations = 0
        timer.onExpired = { expirations += 1 }
        timer.start(.minutes(15)); XCTAssertEqual(timer.remainingSeconds, 900)
        let deadline = timer.deadline
        now = now.addingTimeInterval(61.2); timer.checkDeadline()
        XCTAssertEqual(timer.remainingSeconds, 839); XCTAssertEqual(timer.deadline, deadline)
        timer.start(.minutes(30)); XCTAssertEqual(timer.remainingSeconds, 1800)
        now = now.addingTimeInterval(900); XCTAssertFalse(timer.checkDeadline())
        timer.cancel(); now = now.addingTimeInterval(900); XCTAssertFalse(timer.checkDeadline()); XCTAssertEqual(expirations, 0)
        timer.start(.minutes(15)); now = now.addingTimeInterval(3600)
        XCTAssertTrue(timer.checkDeadline()); XCTAssertEqual(expirations, 1); XCTAssertEqual(timer.mode, .off)
        XCTAssertFalse(timer.checkDeadline()); XCTAssertEqual(expirations, 1)
        timer.start(.trackEnd); XCTAssertFalse(timer.checkDeadline()); XCTAssertTrue(timer.consumeTrackEnd()); XCTAssertFalse(timer.consumeTrackEnd())
    }
    @MainActor
    private func playbackModel(timer: SleepTimerManager? = nil) async throws -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let music = directory.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        for name in ["A", "B"] { try CoreTests.writeWAV(music.appendingPathComponent(name + ".wav"), seconds: 1) }
        let model = AppModel(databasePath: directory.appendingPathComponent("library.sqlite").path, remoteControls: false, sleepTimer: timer)
        for _ in 0..<100 { if model.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.ready); await model.importSources([music]); model.volume = 0
        return (model, directory)
    }
    @MainActor
    func testEndTimerOverridesAllLoopModesWithoutDuplicateCompletions() async throws {
        for mode: PlayMode in [.sequential, .one, .all] {
            let (model, directory) = try await playbackModel()
            model.mode = mode; model.sleepTimer.start(.trackEnd); model.start(model.visibleTracks)
            let id = try XCTUnwrap(model.currentTrack?.id); let current = model.currentID; let queue = model.queue
            for _ in 0..<100 { if model.sleepTimer.mode == .off { break }; try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertEqual(model.sleepTimer.mode, .off); XCTAssertFalse(model.isPlaying)
            XCTAssertEqual(model.currentID, current); XCTAssertEqual(model.queue, queue)
            let result = try await model.trackStatistics(id, startDay: nil, endDay: "9999-12-31")
            XCTAssertEqual(result.summary.completions, 1); XCTAssertEqual(result.history.records.count, 1)
            try await Task.sleep(for: .milliseconds(120)); XCTAssertFalse(model.isPlaying)
            await model.shutdown(); try FileManager.default.removeItem(at: directory)
        }
    }
    @MainActor
    func testDeadlinePausePreservesPartialTimeAndNeverRestoresTimer() async throws {
        var now = Date()
        let timer = SleepTimerManager(now: { now }, automatic: false)
        let (model, directory) = try await playbackModel(timer: timer)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.start(model.visibleTracks); let id = try XCTUnwrap(model.currentTrack?.id)
        timer.start(.minutes(15)); let deadline = timer.deadline
        try await Task.sleep(for: .milliseconds(160)); model.pause()
        now = now.addingTimeInterval(60); timer.checkDeadline(); XCTAssertEqual(timer.remainingSeconds, 840)
        model.jump(model.queue[1]); XCTAssertEqual(timer.deadline, deadline)
        model.page = "stats"; model.setSpectrumWindowVisible(false)
        now = now.addingTimeInterval(900); model.setSpectrumWindowVisible(true)
        XCTAssertFalse(model.isPlaying); XCTAssertEqual(timer.mode, .off)
        let first = try await model.trackStatistics(id, startDay: nil, endDay: "9999-12-31")
        XCTAssertGreaterThan(first.summary.seconds, 0); XCTAssertEqual(first.summary.completions, 0)
        timer.start(.minutes(30)); await model.shutdown(); XCTAssertEqual(timer.mode, .off)
        let restored = AppModel(databasePath: directory.appendingPathComponent("library.sqlite").path, remoteControls: false)
        for _ in 0..<100 { if restored.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(restored.sleepTimer.mode, .off); XCTAssertFalse(restored.isPlaying)
        await restored.shutdown()
    }
    @MainActor
    func testEndTimerFollowsManualTrackSwitchAndQueueClearCancelsIt() async throws {
        let (model, directory) = try await playbackModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.sleepTimer.start(.trackEnd); model.start(model.visibleTracks)
        try await Task.sleep(for: .milliseconds(120)); model.pause()
        XCTAssertEqual(model.sleepTimer.mode, .trackEnd)
        let second = model.queue[1]; model.jump(second)
        XCTAssertEqual(model.sleepTimer.mode, .trackEnd)
        for _ in 0..<100 { if model.sleepTimer.mode == .off { break }; try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(model.isPlaying); XCTAssertEqual(model.currentID, second.id)
        model.sleepTimer.start(.trackEnd); model.queue = []; XCTAssertEqual(model.sleepTimer.mode, .off)
        await model.shutdown()
    }
    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return calendar
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func testMondayCalendarLeapYearsEdgesAndFutureDates() {
        let calendar = calendar(); let today = date("2026-10-14T20:30:00+08:00")
        for (year, count, row) in [(2024, 366, 0), (2025, 365, 2), (2026, 365, 3)] {
            let grid = ListeningCalendar(year: year, calendar: calendar, today: today)
            XCTAssertEqual(grid.days.count, count); XCTAssertEqual(Set(grid.days.map(\.id)).count, count)
            XCTAssertEqual(grid.days.first?.row, row); XCTAssertEqual(grid.days.first?.column, 0)
            XCTAssertEqual(grid.days.last?.id, "\(year)-12-31")
            XCTAssertEqual(grid.days.last?.column, grid.columns - 1)
            XCTAssertTrue(grid.days.allSatisfy { $0.row == (calendar.component(.weekday, from: $0.date) + 5) % 7 })
        }
        XCTAssertEqual(ListeningCalendar(year: 2012, calendar: calendar, today: today).columns, 54)
        let grid = ListeningCalendar(year: 2026, calendar: calendar, today: today)
        XCTAssertTrue(grid.days.first { $0.id == "2026-10-14" }!.isToday)
        XCTAssertFalse(grid.days.first { $0.id == "2026-10-14" }!.isFuture)
        XCTAssertTrue(grid.days.first { $0.id == "2026-10-15" }!.isFuture)
        XCTAssertEqual(grid.endDayExclusive, "2027-01-01")
        XCTAssertEqual(grid.moving(from: "2026-10-14", dayOffset: -7)?.id, "2026-10-07")
        XCTAssertNil(grid.moving(from: "2026-10-14", dayOffset: 1))
        XCTAssertEqual(grid.moving(from: "2026-01-01", dayOffset: -1)?.id, "2026-01-01")
    }
    func testHeatmapThresholdsAndPeriodLocalBoundaries() {
        for (seconds, expected) in [(0.0,0), (0.1,1), (899,1), (900,2), (1799,2), (1800,3), (3599,3), (3600,4)] {
            XCTAssertEqual(ListeningHeatmapMetric.duration.level(DailyListeningStat(day: "", seconds: seconds, completions: 0)), expected)
        }
        for (count, expected) in [(0,0), (1,1), (2,1), (3,2), (5,2), (6,3), (10,3), (11,4)] {
            XCTAssertEqual(ListeningHeatmapMetric.completions.level(DailyListeningStat(day: "", seconds: 20, completions: count)), expected)
        }
        let now = date("2026-10-14T00:01:00+08:00")
        XCTAssertEqual(TrackStatisticsPeriod.week.startDay(now: now, calendar: calendar()), "2026-10-08")
        XCTAssertEqual(TrackStatisticsPeriod.month.startDay(now: now, calendar: calendar()), "2026-09-15")
        XCTAssertNil(TrackStatisticsPeriod.all.startDay(now: now, calendar: calendar()))
    }
    private func seed(_ db: LibraryDatabase) async throws {
        let source = LibrarySource(id: "source", path: "/fixture", bookmark: Data(), name: "Source")
        try await db.saveSource(source)
        let tracks = ["A", "B"].map { Track(id: $0, sourceID: source.id, relativePath: $0 + ".wav", identity: $0, title: $0, duration: 40, format: "WAV", fileSize: 1, available: true) }
        try await db.scanResult(sourceID: source.id, scanned: tracks)
        func session(_ id: String, track: String, start: String, fragments: [(String, Double)], completed: String? = nil) async throws {
            let start = date(start)
            let s = ListenSession(id: id, trackID: track, startedAt: start, endedAt: start.addingTimeInterval(fragments.reduce(0) { $0 + $1.1 }), listenedSeconds: fragments.reduce(0) { $0 + $1.1 }, completed: completed != nil, completedDay: completed)
            let f = fragments.map { ListenFragment(sessionID: id, trackID: track, day: $0.0, seconds: $0.1) }
            try await db.checkpoint(session: s, fragments: f, snapshot: PlayerSnapshot())
        }
        try await session("s1", track: "A", start: "2026-10-13T23:59:50+08:00", fragments: [("2026-10-13",10),("2026-10-14",20),("2026-10-14",10)], completed: "2026-10-14")
        try await session("s2", track: "A", start: "2026-10-14T12:00:00+08:00", fragments: [("2026-10-14",20)])
        try await session("s3", track: "A", start: "2026-10-14T12:00:00+08:00", fragments: [("2026-10-14",10),("2026-10-14",20)], completed: "2026-10-14")
        try await session("s4", track: "B", start: "2025-12-31T23:59:59+08:00", fragments: [("2025-12-31",1),("2026-01-01",5)], completed: "2026-01-01")
        try await session("s5", track: "B", start: "2026-10-14T11:00:00+08:00", fragments: [("2026-10-14",20)])
        try await db.checkpoint(session: ListenSession(id: "idle", trackID: "A", startedAt: date("2026-10-14T13:00:00+08:00")), fragments: [], snapshot: PlayerSnapshot())
    }
    func testTrackStatisticsDoNotMultiplyCompletionsAndHistoryPaginates() async throws {
        let db = try LibraryDatabase(path: ":memory:"); try await seed(db)
        let first = try await db.trackStatistics("A", startDay: "2026-10-14", endDay: "2026-10-14")
        XCTAssertEqual(first.summary.seconds, 90); XCTAssertEqual(first.summary.completions, 2)
        XCTAssertEqual(first.summary.listeningDays, 2)
        XCTAssertEqual(first.summary.lastPlayedAt, date("2026-10-14T12:00:00+08:00"))
        XCTAssertEqual(first.days.map(\.seconds), [80])
        XCTAssertEqual(first.history.records.map(\.id), ["s3", "s2", "s1"])
        let page = try await db.trackHistory("A", startDay: nil, endDay: "2026-10-14", limit: 2)
        XCTAssertTrue(page.hasMore); XCTAssertEqual(page.records.map(\.id), ["s3", "s2"])
        let next = try await db.trackHistory("A", startDay: nil, endDay: "2026-10-14", before: TrackHistoryCursor(page.records.last!), limit: 2)
        XCTAssertFalse(next.hasMore); XCTAssertEqual(next.records.map(\.id), ["s1"])
        let empty = try await db.trackStatistics("missing", startDay: nil, endDay: "2026-10-14")
        XCTAssertEqual(empty.summary.seconds, 0); XCTAssertEqual(empty.summary.completions, 0); XCTAssertNil(empty.summary.lastPlayedAt)
        XCTAssertTrue(empty.days.isEmpty); XCTAssertTrue(empty.history.records.isEmpty)
    }
    func testYearAndDayAggregatesKeepMidnightCompletionDayAndUnavailableFiles() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try LibraryDatabase(path: path); try await seed(db)
        let before = try await db.stats()
        let year = try await db.yearlyListeningStats(startDay: "2026-01-01", endDayExclusive: "2027-01-01")
        XCTAssertEqual(year.days.reduce(0) { $0 + $1.completions }, before.completions)
        XCTAssertEqual(year.days.reduce(0) { $0 + $1.seconds }, 115)
        let today = try await db.dailyListeningDetails(day: "2026-10-14")
        XCTAssertEqual(today.seconds, 100); XCTAssertEqual(today.completions, 2); XCTAssertEqual(today.tracks.map(\.id), ["A", "B"])
        XCTAssertEqual(today.tracks.first?.seconds, 80)
        let oldYear = try await db.yearlyListeningStats(startDay: "2025-01-01", endDayExclusive: "2026-01-01")
        XCTAssertEqual(oldYear.days.first?.seconds, 1); XCTAssertEqual(oldYear.days.first?.completions, 0)
        let playlist = Playlist(name: "References")
        try await db.savePlaylist(playlist, items: [PlaylistItem(playlistID: playlist.id, trackID: "A", position: 0), PlaylistItem(playlistID: playlist.id, trackID: "A", position: 1)])
        try await db.deletePlaylist(id: playlist.id); try await db.scanResult(sourceID: "source", scanned: [])
        let restored = try LibraryDatabase(path: path)
        let after = try await restored.dailyListeningDetails(day: "2026-10-14")
        XCTAssertEqual(after.seconds, today.seconds); XCTAssertEqual(after.completions, today.completions)
        XCTAssertTrue(after.tracks.allSatisfy { $0.track?.available == false })
        let empty = try await restored.dailyListeningDetails(day: "2026-10-12")
        XCTAssertEqual(empty.seconds, 0); XCTAssertEqual(empty.completions, 0); XCTAssertTrue(empty.tracks.isEmpty)
        let finalStats = try await restored.stats()
        XCTAssertEqual(finalStats.completions, before.completions)
    }
    func testReadonlyHistoryBackupDoesNotChangeOriginalSessions() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let original = try LibraryDatabase(path: path); try await seed(original)
        let copy = try LibraryDatabase(path: ":memory:", copyingHistoryFrom: path)
        let copiedDay = try await copy.dailyListeningDetails(day: "2026-10-14")
        XCTAssertEqual(copiedDay.seconds, 100)
        var config = Configuration(); config.readonly = true
        let readonly = try DatabaseQueue(path: path, configuration: config)
        let open = try await readonly.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions WHERE id = 'idle' AND endedAt IS NULL") }
        XCTAssertEqual(open, 1)
    }
}
