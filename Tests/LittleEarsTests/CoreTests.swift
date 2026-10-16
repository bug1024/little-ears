import XCTest
import AppKit
import AVFoundation
import GRDB
import Combine
@testable import LittleEars

final class CoreTests: XCTestCase {
    @MainActor
    func testTrackNameModeSortSearchPersistenceAndManualOrder() async throws {
        let suite = "LittleEars.TrackNameTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(databasePath: ":memory:", remoteControls: false, preferences: preferences)
        for _ in 0..<50 { if model.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        func track(_ id: String, _ path: String, _ title: String) -> Track {
            Track(id: id, sourceID: "local", relativePath: path, identity: id, title: title, duration: 20, format: "FLAC", fileSize: 100, available: true)
        }
        let ten = track("ten", "album/10 - Custom.flac", "Alpha")
        let two = track("two", "album/2 - Renamed.flac", "Zulu")
        XCTAssertEqual(model.trackNameMode, .metadata)
        model.tracks = [two, ten]
        XCTAssertEqual(model.visibleTracks.map(\.id), ["ten", "two"])
        model.queue = [QueueItem(trackID: "ten"), QueueItem(trackID: "two")]
        model.currentID = model.queue[0].id
        model.playlistItems = [PlaylistItem(playlistID: "p", trackID: "ten", position: 0), PlaylistItem(playlistID: "p", trackID: "two", position: 1)]
        let queue = model.queue, items = model.playlistItems
        model.trackNameMode = .filename
        XCTAssertEqual(model.visibleTracks.map(\.id), ["two", "ten"])
        XCTAssertEqual(model.displayName(two), "2 - Renamed")
        XCTAssertEqual(model.queue, queue)
        XCTAssertEqual(model.playlistItems, items)
        XCTAssertEqual(preferences.string(forKey: "trackNameMode"), "filename")
        model.search = "ALPHA"
        XCTAssertEqual(model.visibleTracks.map(\.id), ["ten"])
        model.trackNameMode = .metadata; model.search = "RENAMED.FLAC"
        XCTAssertEqual(model.visibleTracks.map(\.id), ["two"])
        model.search = ""; model.sortByDuration = true
        let durationOrder = model.visibleTracks.map(\.id)
        model.trackNameMode = .filename
        XCTAssertEqual(model.visibleTracks.map(\.id), durationOrder)
        XCTAssertEqual(track("blank", "nested/03 - Story.MP3", "  ").displayName(.metadata), "03 - Story")
        XCTAssertEqual(track("dots", "nested/a.b.flac", "A").displayName(.filename), "a.b")
        let restored = AppModel(databasePath: ":memory:", remoteControls: false, preferences: preferences)
        XCTAssertEqual(restored.trackNameMode, .filename)
        await restored.shutdown()
        await model.shutdown()
    }

    @MainActor
    func testLibraryProjectionInvalidatesForFiltersSortAndTrackChanges() async throws {
        let model = AppModel(databasePath: ":memory:", remoteControls: false)
        for _ in 0..<50 { if model.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.ready)
        func track(_ id: String, _ path: String, _ title: String, _ duration: Double, source: String = "local") -> Track {
            Track(id: id, sourceID: source, relativePath: path, identity: id, title: title, duration: duration, format: "WAV", fileSize: 100, available: true)
        }
        model.tracks = [track("ten", "a/10.wav", "Lesson 10", 10), track("two", "a/2.wav", "Lesson 2", 20), track("sub", "a/sub/1.wav", "Lesson 1", 30), track("sibling", "ab/3.wav", "Lesson 3", 40), track("other", "a/4.wav", "Foreign", 50, source: "other")]
        model.selectedFolder = "local|a"
        XCTAssertEqual(model.visibleTracks.map(\.id), ["two", "ten"])
        let rebuilds = model.visibleTracksRebuildCount
        for _ in 0..<20 { model.page = "playing"; model.page = "library"; model.selectedFolder = "local|a"; _ = model.visibleTracks }
        XCTAssertEqual(model.visibleTracksRebuildCount, rebuilds)
        model.includeChildren = true
        XCTAssertEqual(model.visibleTracks.map(\.id), ["sub", "two", "ten"])
        model.search = "LESSON 1"
        XCTAssertEqual(model.visibleTracks.map(\.id), ["sub", "ten"])
        model.search = ""; model.sortByDuration = true
        XCTAssertEqual(model.visibleTracks.map(\.id), ["ten", "two", "sub"])
        model.tracks[0].title = "Updated title"; model.tracks[0].available = false
        XCTAssertEqual(model.visibleTracks.first?.title, "Updated title")
        XCTAssertEqual(model.visibleTracks.first?.available, false)
        model.selectedFolder = "local|"; model.includeChildren = false
        XCTAssertTrue(model.visibleTracks.isEmpty)
        model.includeChildren = true
        XCTAssertEqual(Set(model.visibleTracks.map(\.id)), ["ten", "two", "sub", "sibling"])
        model.selectedFolder = nil
        XCTAssertEqual(model.visibleTracks.count, 5)
        model.tracks.removeAll()
        XCTAssertTrue(model.visibleTracks.isEmpty)
        await model.shutdown()
    }
    @MainActor
    func testPlaybackPositionRefreshDoesNotInvalidateLibraryOrNavigation() async throws {
        let model = AppModel(databasePath: ":memory:", remoteControls: false)
        for _ in 0..<50 { if model.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.ready)
        _ = model.visibleTracks
        let rebuilds = model.visibleTracksRebuildCount
        var appUpdates = 0; var progressUpdates = 0
        let appSubscription = model.objectWillChange.sink { appUpdates += 1 }
        let progressSubscription = model.playbackPosition.objectWillChange.sink { progressUpdates += 1 }
        for second in 1...20 { model.position = Double(second); _ = model.visibleTracks }
        XCTAssertEqual(appUpdates, 0)
        XCTAssertEqual(progressUpdates, 20)
        XCTAssertEqual(model.visibleTracksRebuildCount, rebuilds)
        XCTAssertEqual(model.snapshot.position, 20)
        appSubscription.cancel(); progressSubscription.cancel()
        await model.shutdown()
    }
    func testCoverageMergesReplayedContentAndRequiresNaturalEnd() {
        var coverage = Coverage()
        coverage.add(from: 0, to: 50)
        coverage.add(from: 10, to: 40)
        coverage.add(from: 70, to: 100)
        XCTAssertEqual(coverage.seconds, 80)
        XCTAssertFalse(coverage.qualifies(duration: 100, naturalEnd: true))
        coverage.add(from: 40, to: 80)
        XCTAssertEqual(coverage.seconds, 100)
        XCTAssertTrue(coverage.qualifies(duration: 100, naturalEnd: true))
        XCTAssertFalse(coverage.qualifies(duration: 100, naturalEnd: false))
    }
    func testSeekingToEndDoesNotQualify() {
        var coverage = Coverage()
        coverage.add(from: 99, to: 100)
        XCTAssertFalse(coverage.qualifies(duration: 100, naturalEnd: true))
    }
    func testMidnightSplitsActualTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 23, minute: 59, second: 58))!
        let segments = ListeningClock.split(start: start, seconds: 5, calendar: calendar)
        XCTAssertEqual(segments.map(\.0), ["2026-10-13", "2026-10-14"])
        XCTAssertEqual(segments.map(\.1), [2, 3])
    }
    func testQueueDuplicatesHaveDifferentIdentities() {
        let first = QueueItem(trackID: "same")
        let second = QueueItem(trackID: "same")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.trackID, second.trackID)
    }
    func testDatabasePreservesIdentityHistoryAndIdempotentCheckpoint() async throws {
        let db = try LibraryDatabase(path: ":memory:")
        let source = LibrarySource(id: "source", path: "/test", bookmark: Data(), name: "Test")
        try await db.saveSource(source)
        let original = Track(id: "track", sourceID: source.id, relativePath: "first.wav", identity: "file1", title: "First", duration: 10, format: "WAV", fileSize: 100, available: true)
        try await db.scanResult(sourceID: source.id, scanned: [original])
        var renamed = original; renamed.id = "new"; renamed.relativePath = "renamed.wav"
        try await db.scanResult(sourceID: source.id, scanned: [renamed])
        let library = try await db.loadLibrary()
        XCTAssertEqual(library.1.first?.id, original.id)
        XCTAssertEqual(library.1.first?.relativePath, "renamed.wav")
        let session = ListenSession(id: "session", trackID: original.id, startedAt: Date(), endedAt: Date(), listenedSeconds: 10, completed: true, endReason: "naturalEnd", completedDay: "2026-10-13")
        let fragment = ListenFragment(sessionID: session.id, trackID: original.id, day: "2026-10-13", seconds: 10)
        let snapshot = PlayerSnapshot(queue: [QueueItem(trackID: original.id)], position: 5)
        try await db.checkpoint(session: session, fragments: [fragment], snapshot: snapshot)
        try await db.checkpoint(session: session, fragments: [fragment], snapshot: snapshot)
        try await db.scanResult(sourceID: source.id, scanned: [])
        let stats = try await db.stats()
        XCTAssertEqual(stats.days.first?.seconds, 10)
        XCTAssertEqual(stats.completions, 1)
        let missing = try await db.loadLibrary()
        XCTAssertEqual(missing.1.first?.available, false)
        let restored = try await db.snapshot()
        XCTAssertEqual(restored?.position, 5)
    }
    @MainActor
    func testEngineUsesRealPCMAndSupportsSeekPause() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: path) }
        try Self.writeWAV(path, seconds: 2)
        let engine = PlaybackEngine()
        try engine.load(path)
        XCTAssertEqual(engine.duration, 2, accuracy: 0.01)
        try engine.play()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThan(engine.position, 0.1)
        engine.pause()
        let paused = engine.position
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(engine.position, paused, accuracy: 0.02)
        try engine.seek(1)
        XCTAssertEqual(engine.position, 1, accuracy: 0.03)
        engine.stop()
    }
    @MainActor
    func testImportPlaybackQueueStatisticsAndRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioDirectory = directory.appendingPathComponent("stories")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try Self.writeWAV(audioDirectory.appendingPathComponent("2 Story.wav"), seconds: 2)
        try Self.writeWAV(audioDirectory.appendingPathComponent("10 Story.wav"), seconds: 2)
        let databasePath = directory.appendingPathComponent("test.sqlite").path
        let model = AppModel(databasePath: databasePath, remoteControls: false)
        for _ in 0..<50 { if model.ready || model.errorMessage != nil { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(model.ready, model.errorMessage ?? "Not ready")
        await model.importSources([audioDirectory])
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.tracks.count, 2)
        XCTAssertEqual(model.visibleTracks.map(\.title), ["2 Story", "10 Story"])
        for track in model.tracks { XCTAssertTrue(FileManager.default.fileExists(atPath: model.fileURL(track)!.path)) }
        model.volume = 0
        model.start(model.visibleTracks)
        XCTAssertTrue(model.isPlaying, model.errorMessage ?? "Playback did not start")
        for _ in 0..<65 { if model.stats.completions == 2 { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.stats.completions, 2)
        XCTAssertFalse(model.isPlaying)
        XCTAssertGreaterThan(model.stats.days.reduce(0) { $0 + $1.seconds }, 3.5)
        model.start(model.visibleTracks)
        try await Task.sleep(for: .milliseconds(450))
        model.pause()
        let seconds = model.position
        XCTAssertGreaterThan(seconds, 0.1)
        await model.shutdown()
        let restored = AppModel(databasePath: databasePath, remoteControls: false)
        for _ in 0..<50 { if restored.ready || restored.errorMessage != nil { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(restored.ready)
        XCTAssertEqual(restored.queue.count, 2)
        XCTAssertEqual(restored.position, seconds, accuracy: 0.05)
        XCTAssertFalse(restored.isPlaying)
        XCTAssertEqual(restored.stats.completions, 2)
        let recordedSeconds = restored.stats.days.reduce(0) { $0 + $1.seconds }
        restored.setSpectrumVisible(true)
        restored.seek(1)
        for _ in 0..<20 {
            if restored.spectrumDisplay.frame.levels.contains(where: { $0 > 0 }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(restored.spectrumDisplay.frame.levels.contains(where: { $0 > 0 }))
        XCTAssertEqual(restored.position, 1)
        XCTAssertFalse(restored.isPlaying)
        XCTAssertEqual(restored.stats.days.reduce(0) { $0 + $1.seconds }, recordedSeconds, accuracy: 0.01)
        await restored.shutdown()
    }
    @MainActor
    func testSeekingNearEndCannotCreateCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeWAV(directory.appendingPathComponent("Story.wav"), seconds: 2)
        let model = AppModel(databasePath: ":memory:", remoteControls: false)
        for _ in 0..<50 { if model.ready { break }; try await Task.sleep(for: .milliseconds(100)) }
        await model.importSources([directory]); model.volume = 0
        model.start(model.visibleTracks)
        try await Task.sleep(for: .milliseconds(200))
        model.seek(1.9)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.stats.completions, 0)
        XCTAssertLessThan(model.stats.days.reduce(0) { $0 + $1.seconds }, 0.7)
        await model.shutdown()
    }
    @MainActor
    func testFLACScanMetadataPlaybackSeekAndNaturalEnd() async throws {
        let fixture = Bundle.module.url(forResource: "Story", withExtension: "FLAC", subdirectory: "Fixtures")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let album = directory.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: fixture, to: album.appendingPathComponent("Upper.FLAC"))
        try FileManager.default.copyItem(at: fixture, to: album.appendingPathComponent("Lower.flac"))
        let scanner = FileScanner()
        let source = LibrarySource(id: "flac", path: directory.path, bookmark: Data(), name: "FLAC")
        let tracks = try await scanner.scan(source: source, root: directory)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(Set(tracks.map(\.relativePath)), ["Album/Upper.FLAC", "Album/Lower.flac"])
        for track in tracks {
            XCTAssertEqual(track.format, "FLAC")
            XCTAssertEqual(track.duration, 2, accuracy: 0.02)
            XCTAssertEqual(track.title, "FLAC regression")
        }
        let engine = PlaybackEngine()
        engine.volume = 0
        let ended = expectation(description: "FLAC naturally ends")
        engine.onEnd = { ended.fulfill() }
        try engine.load(fixture)
        XCTAssertEqual(engine.duration, 2, accuracy: 0.01)
        try engine.play()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThan(engine.position, 0.1)
        engine.pause()
        let paused = engine.position
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(engine.position, paused, accuracy: 0.02)
        try engine.seek(1)
        XCTAssertEqual(engine.position, 1, accuracy: 0.03)
        try engine.play()
        await fulfillment(of: [ended], timeout: 3)
        XCTAssertFalse(engine.running)
        engine.stop()
    }
    func testActualFLACLibraryWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["LITTLE_EARS_TEST_LIBRARY"] else {
            throw XCTSkip("Set LITTLE_EARS_TEST_LIBRARY to verify a real library without modifying it")
        }
        let root = URL(fileURLWithPath: path)
        let scanner = FileScanner()
        let source = LibrarySource(id: "verification", path: path, bookmark: Data(), name: "Verification")
        let tracks = try await scanner.scan(source: source, root: root)
        XCTAssertEqual(tracks.count, 164)
        XCTAssertEqual(tracks.filter { $0.format == "FLAC" }.count, 162)
        XCTAssertEqual(tracks.filter { $0.format == "MP3" }.count, 2)
        XCTAssertTrue(tracks.allSatisfy { $0.duration > 0 })
        for track in tracks where track.format == "FLAC" {
            let file = try AVAudioFile(forReading: root.appendingPathComponent(track.relativePath))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024))
            try file.read(into: buffer, frameCount: 1024)
            XCTAssertGreaterThan(buffer.frameLength, 0, track.relativePath)
            XCTAssertEqual(track.duration, Double(file.length) / file.processingFormat.sampleRate, accuracy: 0.001)
        }
        let db = try LibraryDatabase(path: ":memory:")
        try await db.saveSource(source)
        try await db.scanResult(sourceID: source.id, scanned: tracks)
        let library = try await db.loadLibrary()
        XCTAssertEqual(library.1.count, 164)
        XCTAssertTrue(library.1.allSatisfy(\.available))
    }
    func testMalformedFLACCommentsAreSafe() {
        XCTAssertNil(FLACMetadata.title(in: Data()))
        XCTAssertNil(FLACMetadata.title(in: Data([255, 255, 255, 255])))
        XCTAssertNil(FLACMetadata.title(in: Data([0, 0, 0, 0, 255, 255, 255, 255])))
    }
    @MainActor
    func testPlaylistsPersistCustomOrderDuplicatesAndIndependentQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let music = directory.appendingPathComponent("Music")
        let firstAlbum = music.appendingPathComponent("First")
        let secondAlbum = music.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: firstAlbum, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondAlbum, withIntermediateDirectories: true)
        try Self.writeWAV(firstAlbum.appendingPathComponent("A.wav"), seconds: 2)
        try Self.writeWAV(secondAlbum.appendingPathComponent("B.wav"), seconds: 2)
        let path = directory.appendingPathComponent("lists.sqlite").path
        let model = AppModel(databasePath: path, remoteControls: false)
        for _ in 0..<50 { if model.ready { break }; try await Task.sleep(for: .milliseconds(100)) }
        await model.importSources([music]); model.volume = 0
        let a = try XCTUnwrap(model.tracks.first { $0.title == "A" })
        let b = try XCTUnwrap(model.tracks.first { $0.title == "B" })
        let playlist = try await model.createPlaylist(name: "  每天听  ", trackIDs: [a.id, b.id, a.id])
        XCTAssertEqual(playlist.name, "每天听")
        let originalIDs = model.items(in: playlist.id).map(\.id)
        XCTAssertEqual(Set(originalIDs).count, 3)
        model.playPlaylist(playlist, at: originalIDs[2])
        XCTAssertEqual(model.currentID, model.queue[2].id, "Duplicate entries must start at the selected occurrence")
        model.pause()
        let snapshot = model.queue
        try await model.movePlaylistItems(in: playlist, from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(model.items(in: playlist.id).map(\.trackID), [a.id, a.id, b.id])
        XCTAssertEqual(model.items(in: playlist.id).map(\.id), [originalIDs[2], originalIDs[0], originalIDs[1]])
        XCTAssertEqual(model.queue, snapshot)
        try await model.renamePlaylist(playlist, name: "最爱")
        try await model.appendTracks([b.id], to: playlist)
        XCTAssertEqual(model.selectedPlaylist?.name, "最爱", "An older playlist value must not undo a rename")
        let removing = model.items(in: playlist.id)[1].id
        try await model.removePlaylistItems(in: playlist, ids: [removing])
        XCTAssertEqual(model.items(in: playlist.id).map(\.trackID), [a.id, b.id, b.id])
        await model.shutdown()
        let restored = AppModel(databasePath: path, remoteControls: false)
        for _ in 0..<50 { if restored.ready { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(restored.playlists.first?.name, "最爱")
        XCTAssertEqual(restored.items(in: playlist.id).map(\.trackID), [a.id, b.id, b.id])
        XCTAssertEqual(restored.queue, snapshot)
        XCTAssertFalse(restored.isPlaying)
        restored.moveQueue(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(restored.items(in: playlist.id).map(\.trackID), [a.id, b.id, b.id])
        try await restored.replacePlaylistTracks(playlist, trackIDs: restored.queue.map(\.trackID))
        XCTAssertEqual(restored.items(in: playlist.id).map(\.trackID), [b.id, a.id, a.id])
        let saved = try await restored.createPlaylist(name: "另存的队列", trackIDs: restored.queue.map(\.trackID))
        XCTAssertEqual(restored.items(in: saved.id).map(\.trackID), restored.queue.map(\.trackID))
        let queueBeforeDelete = restored.queue
        try await restored.deletePlaylist(playlist)
        XCTAssertEqual(restored.queue, queueBeforeDelete)
        XCTAssertEqual(restored.tracks.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstAlbum.appendingPathComponent("A.wav").path))
        await restored.shutdown()
        let db = try LibraryDatabase(path: path)
        let stored = try await db.loadPlaylists()
        XCTAssertEqual(stored.0.count, 1)
        XCTAssertFalse(stored.1.contains { $0.playlistID == playlist.id })
    }
    @MainActor
    func testBatchPlaylistEditsKeepOrderDuplicateIdentityFilesAndQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let music = directory.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        for name in ["A", "B", "C"] { try Self.writeWAV(music.appendingPathComponent(name + ".wav"), seconds: 1) }
        let path = directory.appendingPathComponent("batch.sqlite").path
        let model = AppModel(databasePath: path, remoteControls: false)
        for _ in 0..<50 { if model.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        await model.importSources([music])
        let tracks = model.visibleTracks
        XCTAssertEqual(tracks.map(\.title), ["A", "B", "C"])
        let playlist = try await model.createPlaylist(name: "批量编辑", trackIDs: tracks.map(\.id))
        try await model.appendTracks([tracks[0].id, tracks[1].id], to: playlist)
        let original = model.items(in: playlist.id)
        XCTAssertEqual(original.map(\.trackID), [tracks[0].id, tracks[1].id, tracks[2].id, tracks[0].id, tracks[1].id])
        model.queue = original.map { QueueItem(trackID: $0.trackID) }
        model.currentID = model.queue[3].id
        let queue = model.queue
        let current = model.currentID
        try await model.removePlaylistItems(in: playlist, ids: [original[0].id, original[2].id, original[4].id])
        let remaining = model.items(in: playlist.id)
        XCTAssertEqual(remaining.map(\.id), [original[1].id, original[3].id], "Remove selected occurrences, preserving the other duplicate")
        XCTAssertEqual(remaining.map(\.position), [0, 1])
        XCTAssertEqual(model.queue, queue)
        XCTAssertEqual(model.currentID, current)
        XCTAssertEqual(model.tracks.count, 3)
        for name in ["A", "B", "C"] { XCTAssertTrue(FileManager.default.fileExists(atPath: music.appendingPathComponent(name + ".wav").path)) }
        await model.shutdown()
        let restored = AppModel(databasePath: path, remoteControls: false)
        for _ in 0..<50 { if restored.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(restored.items(in: playlist.id).map(\.id), remaining.map(\.id))
        XCTAssertEqual(restored.queue, queue)
        XCTAssertEqual(restored.currentID, current)
        await restored.shutdown()
    }
    @MainActor
    func testPlaylistOrderPersistsThroughRenameDeleteAndCreation() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = AppModel(databasePath: path, remoteControls: false)
        for _ in 0..<50 { if model.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        let a = try await model.createPlaylist(name: "A", trackIDs: [])
        let b = try await model.createPlaylist(name: "B", trackIDs: [])
        let c = try await model.createPlaylist(name: "C", trackIDs: [])
        model.selectedPlaylistID = b.id
        model.queue = [QueueItem(trackID: "independent")]; model.currentID = model.queue[0].id
        let queue = model.queue
        try await model.movePlaylists(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(model.playlists.map(\.id), [c.id, a.id, b.id])
        XCTAssertEqual(model.playlists.map(\.position), [0, 1, 2])
        XCTAssertEqual(model.selectedPlaylistID, b.id)
        try await model.renamePlaylist(c, name: "C renamed")
        XCTAssertEqual(model.playlists.map(\.id), [c.id, a.id, b.id], "Renaming through an old value must keep the new position")
        try await model.movePlaylists(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(model.playlists.map(\.id), [a.id, b.id, c.id])
        try await model.deletePlaylist(b)
        XCTAssertEqual(model.selectedPlaylistID, a.id)
        let d = try await model.createPlaylist(name: "D", trackIDs: [])
        XCTAssertEqual(model.playlists.map(\.id), [a.id, c.id, d.id])
        XCTAssertEqual(model.queue, queue)
        let saved = model.playlists
        await model.shutdown()
        let restored = AppModel(databasePath: path, remoteControls: false)
        for _ in 0..<50 { if restored.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(restored.playlists.map(\.id), saved.map(\.id))
        XCTAssertEqual(restored.playlists.map(\.name), saved.map(\.name))
        XCTAssertEqual(restored.playlists.map(\.position), saved.map(\.position))
        for (actual, expected) in zip(restored.playlists, saved) {
            XCTAssertEqual(actual.updatedAt.timeIntervalSince1970, expected.updatedAt.timeIntervalSince1970, accuracy: 0.001)
        }
        XCTAssertEqual(restored.queue, queue)
        await restored.shutdown()
    }
    func testPlaylistOrderMigrationPreservesExistingCreationOrderAndEntries() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let original = try LibraryDatabase(path: path)
        let a = Playlist(name: "A", createdAt: Date(timeIntervalSince1970: 10))
        let b = Playlist(name: "B", createdAt: Date(timeIntervalSince1970: 20))
        let item = PlaylistItem(playlistID: b.id, trackID: "unchanged", position: 0)
        try await original.savePlaylist(b, items: [item])
        try await original.savePlaylist(a, items: [])
        let raw = try DatabaseQueue(path: path)
        try await raw.write { db in
            try db.execute(sql: "ALTER TABLE playlists DROP COLUMN position; DELETE FROM grdb_migrations WHERE identifier = 'v4-playlist-order'")
        }
        let upgraded = try LibraryDatabase(path: path)
        let lists = try await upgraded.loadPlaylists()
        XCTAssertEqual(lists.0.map(\.id), [a.id, b.id])
        XCTAssertEqual(lists.0.map(\.position), [0, 1])
        XCTAssertEqual(lists.1, [item])
        try await upgraded.savePlaylistOrder([b.id, a.id])
        let reordered = try await upgraded.loadPlaylists()
        XCTAssertEqual(reordered.0.map(\.id), [b.id, a.id])
        XCTAssertEqual(reordered.1, [item])
    }
    @MainActor
    func testSpaceShortcutPreservesEditingControlsSheetsAndModifiedKeys() throws {
        func event(_ flags: NSEvent.ModifierFlags = [], key: UInt16 = 49) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: key))
        }
        let space = try event()
        XCTAssertTrue(PlaybackKeyboardShortcuts.shouldHandle(space, responder: NSTableView(), hasSheet: false))
        for responder: NSResponder in [NSTextView(), NSTextField(), NSSearchField(), NSButton(), NSPopUpButton()] {
            XCTAssertFalse(PlaybackKeyboardShortcuts.shouldHandle(space, responder: responder, hasSheet: false))
        }
        XCTAssertFalse(PlaybackKeyboardShortcuts.shouldHandle(space, responder: nil, hasSheet: true))
        for flags: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            XCTAssertFalse(PlaybackKeyboardShortcuts.shouldHandle(try event(flags), responder: nil, hasSheet: false))
        }
        XCTAssertFalse(PlaybackKeyboardShortcuts.shouldHandle(try event(key: 36), responder: nil, hasSheet: false))
    }
    @MainActor
    func testArrowShortcutsRespectNativeFocusAndRepeatPolicy() throws {
        for (key, expected) in [(UInt16(123), PlaybackKeyboardShortcuts.Command.previous), (124, .next), (125, .volumeDown), (126, .volumeUp)] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
            XCTAssertEqual(PlaybackKeyboardShortcuts.command(for: event, responder: NSView(), hasSheet: false, playingPage: true), expected)
            for control: NSView in [NSTableView(), NSOutlineView(), NSCollectionView(), NSSlider(), NSTextView(), NSTextField(), NSPopUpButton()] {
                XCTAssertNil(PlaybackKeyboardShortcuts.command(for: event, responder: control, hasSheet: false, playingPage: true))
                let child = NSView(); control.addSubview(child)
                XCTAssertNil(PlaybackKeyboardShortcuts.command(for: event, responder: child, hasSheet: false, playingPage: true))
            }
            XCTAssertNil(PlaybackKeyboardShortcuts.command(for: event, responder: NSView(), hasSheet: false, playingPage: false))
            for control: NSView in [NSButton()] {
                XCTAssertEqual(PlaybackKeyboardShortcuts.command(for: event, responder: control, hasSheet: false, playingPage: true), expected)
            }
            XCTAssertNil(PlaybackKeyboardShortcuts.command(for: event, responder: nil, hasSheet: true, playingPage: true))
        }
        XCTAssertTrue(PlaybackKeyboardShortcuts.Command.volumeUp.allowsRepeat)
        XCTAssertTrue(PlaybackKeyboardShortcuts.Command.volumeDown.allowsRepeat)
        XCTAssertFalse(PlaybackKeyboardShortcuts.Command.previous.allowsRepeat)
        XCTAssertFalse(PlaybackKeyboardShortcuts.Command.next.allowsRepeat)
    }
    @MainActor
    func testKeyboardVolumeLimitsPersistAndPreviousSkipsElapsedTrack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let music = directory.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        for name in ["A", "B"] { try Self.writeWAV(music.appendingPathComponent(name + ".wav"), seconds: 5) }
        let path = directory.appendingPathComponent("keys.sqlite").path
        let model = AppModel(databasePath: path, remoteControls: false)
        for _ in 0..<50 { if model.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        await model.importSources([music]); model.volume = 0
        let tracks = model.visibleTracks
        model.start(tracks, at: tracks[1]); model.pause(); model.seek(4)
        model.previousTrack(); model.pause()
        XCTAssertEqual(model.currentTrack?.id, tracks[0].id, "Left must select the previous song even after three seconds")
        model.next(); model.pause()
        XCTAssertEqual(model.currentTrack?.id, tracks[1].id)
        model.volume = 0.98; model.adjustVolume(by: 0.05); XCTAssertEqual(model.volume, 1)
        model.adjustVolume(by: 0.05); XCTAssertEqual(model.volume, 1)
        model.volume = 0.02; model.adjustVolume(by: -0.05); XCTAssertEqual(model.volume, 0)
        model.adjustVolume(by: -0.05); XCTAssertEqual(model.volume, 0)
        model.adjustVolume(by: 0.05); XCTAssertEqual(model.volume, 0.05, accuracy: 0.0001)
        await model.shutdown()
        let restored = AppModel(databasePath: path, remoteControls: false)
        for _ in 0..<50 { if restored.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(restored.volume, 0.05, accuracy: 0.0001)
        await restored.shutdown()
    }
    @MainActor
    func testEmptyPlaylistNameRejectedWithoutCreatingRecords() async throws {
        let model = AppModel(databasePath: ":memory:", remoteControls: false)
        for _ in 0..<50 { if model.ready { break }; try await Task.sleep(for: .milliseconds(100)) }
        do { try await model.createPlaylist(name: "  ", trackIDs: []); XCTFail("An empty name must fail") }
        catch { XCTAssertTrue(model.playlists.isEmpty) }
        let empty = try await model.createPlaylist(name: "空列表", trackIDs: [])
        model.playPlaylist(empty)
        XCTAssertTrue(model.queue.isEmpty)
        XCTAssertFalse(model.isPlaying)
        await model.shutdown()
    }
    func testUpgradeFromV2PreservesTracksStatisticsAndQueue() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try LibraryDatabase(path: url.path)
        let source = LibrarySource(id: "existing", path: "/existing", bookmark: Data(), name: "Existing")
        let track = Track(id: "existing-track", sourceID: source.id, relativePath: "a.flac", identity: "a", title: "A", duration: 10, format: "FLAC", fileSize: 100, available: true)
        try await original.saveSource(source)
        try await original.scanResult(sourceID: source.id, scanned: [track])
        let session = ListenSession(id: "history", trackID: track.id, startedAt: Date(), endedAt: Date(), listenedSeconds: 10, completed: true)
        let fragment = ListenFragment(sessionID: session.id, trackID: track.id, day: "2026-10-14", seconds: 10)
        let queue = PlayerSnapshot(queue: [QueueItem(trackID: track.id)], position: 3)
        try await original.checkpoint(session: session, fragments: [fragment], snapshot: queue)
        // Reconstruct the previous release's schema, then run the new migration.
        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            try db.execute(sql: "DROP TABLE playlistItems; DROP TABLE playlists; DELETE FROM grdb_migrations WHERE identifier IN ('v3-playlists', 'v4-playlist-order')")
        }
        let upgraded = try LibraryDatabase(path: url.path)
        let library = try await upgraded.loadLibrary()
        XCTAssertEqual(library.1, [track])
        let stats = try await upgraded.stats()
        XCTAssertEqual(stats.completions, 1)
        XCTAssertEqual(stats.days.first?.seconds, 10)
        let restored = try await upgraded.snapshot()
        XCTAssertEqual(restored?.position, 3)
        XCTAssertEqual(restored?.queue, queue.queue)
        let playlist = Playlist(name: "升级后")
        try await upgraded.savePlaylist(playlist, items: [PlaylistItem(playlistID: playlist.id, trackID: track.id, position: 0)])
        let lists = try await upgraded.loadPlaylists()
        XCTAssertEqual(lists.0.count, 1)
    }
    static func writeWAV(_ url: URL, seconds: Int) throws {
        var data = Data()
        func ascii(_ value: String) { data.append(value.data(using: .ascii)!) }
        func u32(_ value: UInt32) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        let count = 44100 * seconds
        ascii("RIFF"); u32(UInt32(36 + count * 2)); ascii("WAVEfmt "); u32(16); u16(1); u16(1); u32(44100); u32(88200); u16(2); u16(16); ascii("data"); u32(UInt32(count * 2))
        for i in 0..<count { u16(UInt16(bitPattern: Int16(sin(Double(i) * 2 * .pi * 440 / 44100) * 200))) }
        try data.write(to: url)
    }
}
