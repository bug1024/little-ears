import SwiftUI
import AppKit
import MediaPlayer
import AVFoundation

@MainActor
final class PlaybackPositionDisplay: ObservableObject {
    @Published var position: Double = 0
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sources: [LibrarySource] = []
    @Published var tracks: [Track] = [] { didSet { cachedVisibleTracks = nil } }
    @Published var playlists: [Playlist] = []
    @Published var playlistItems: [PlaylistItem] = []
    @Published var selectedPlaylistID: String?
    @Published var playlistDraft: PlaylistDraft?
    @Published var savingPlaylists = false
    @Published var queue: [QueueItem] = []
    @Published var currentID: String?
    let playbackPosition = PlaybackPositionDisplay()
    var position: Double { get { playbackPosition.position } set { if newValue != playbackPosition.position { playbackPosition.position = newValue } } }
    @Published var isPlaying = false
    @Published var mode: PlayMode = .sequential
    @Published var volume: Float = 0.7 { didSet { engine.volume = volume } }
    @Published var scanning = false
    @Published var ready = false
    @Published var errorMessage: String?
    @Published var stats = Stats()
    @Published var page = "library"
    @Published var selectedFolder: String? { didSet { if selectedFolder != oldValue { cachedVisibleTracks = nil } } }
    @Published var search = "" { didSet { if search != oldValue { cachedVisibleTracks = nil } } }
    @Published var includeChildren = false { didSet { if includeChildren != oldValue { cachedVisibleTracks = nil } } }
    @Published var sortByDuration = false { didSet { if sortByDuration != oldValue { cachedVisibleTracks = nil } } }
    let spectrumDisplay = SpectrumDisplay()
    private var spectrumRequested = false
    private var spectrumEnabled = true
    private var spectrumWindowVisible = true
    private let engine = PlaybackEngine()
    private let scanner = FileScanner()
    private var database: LibraryDatabase?
    private var roots: [String: URL] = [:]
    private var scopedRoots: [URL] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var session: ListenSession?
    private var coverage = Coverage()
    private var pending: [ListenFragment] = []
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var lastPosition: Double = 0
    private var sinceCheckpoint: Double = 0
    private var writeTask: Task<Void, Never>?
    private var loadedTrackID: String?
    var currentItem: QueueItem? { queue.first { $0.id == currentID } }
    var currentTrack: Track? { currentItem.flatMap { item in tracks.first { $0.id == item.trackID } } }
    private var cachedVisibleTracks: [Track]?
    private(set) var visibleTracksRebuildCount = 0
    private(set) var visibleTracksEvaluationCount = 0
    var visibleTracks: [Track] {
        visibleTracksEvaluationCount += 1
        if let cachedVisibleTracks { return cachedVisibleTracks }
        visibleTracksRebuildCount += 1
        let parts = selectedFolder?.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let sourceID = parts?.first
        let folder = parts?.dropFirst().first ?? ""
        let result = tracks.filter { track in
            let folderOK = sourceID.map { id in
                track.sourceID == id && (track.folder == folder || (includeChildren && (folder.isEmpty || track.folder.hasPrefix(folder + "/"))))
            } ?? true
            return folderOK && (search.isEmpty || track.title.localizedCaseInsensitiveContains(search))
        }.sorted {
            if sortByDuration, $0.duration != $1.duration { return $0.duration < $1.duration }
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.relativePath < $1.relativePath : order == .orderedAscending
        }
        cachedVisibleTracks = result
        return result
    }
    var folderTitle: String {
        guard let selectedFolder else { return "所有音频" }
        let p = selectedFolder.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return p.count > 1 && !p[1].isEmpty ? (p[1] as NSString).lastPathComponent : sources.first { $0.id == p[0] }?.name ?? "音乐库"
    }
    var snapshot: PlayerSnapshot { PlayerSnapshot(queue: queue, currentID: currentID, position: position, mode: mode.rawValue, volume: volume) }
    init(databasePath: String? = nil, remoteControls: Bool = true) {
        let display = spectrumDisplay
        engine.spectrum.setCallback { [weak display] frame in Task { @MainActor in display?.frame = frame } }
        engine.onEnd = { [weak self] in self?.naturalEnd() }
        let playbackTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        RunLoop.main.add(playbackTimer, forMode: .common)
        timer = playbackTimer
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.pause() } })
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine.configurationNotificationObject, queue: .main) { [weak self] _ in Task { @MainActor in self?.pause() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.setSpectrumWindowVisible(false) } })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.setSpectrumWindowVisible(true) } })
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let window = notification.object as? NSWindow, window.title == "Little Ears" else { return }
                Task { @MainActor in self?.setSpectrumWindowVisible(false) }
            })
        }
        for name in [NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let window = notification.object as? NSWindow, window.title == "Little Ears" else { return }
                Task { @MainActor in self?.setSpectrumWindowVisible(true) }
            })
        }
        if remoteControls { setupRemoteControls() }
        Task { await initialize(databasePath: databasePath) }
    }
    private func initialize(databasePath: String?) async {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LittleEars", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let databasePath = databasePath ?? directory.appendingPathComponent("library.sqlite").path
            let db = try await Task.detached { try LibraryDatabase(path: databasePath) }.value
            database = db
            let library = try await db.loadLibrary(); sources = library.0; tracks = library.1
            for var source in sources {
                do {
                    var stale = false
                    let url = try URL(resolvingBookmarkData: source.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                    if url.startAccessingSecurityScopedResource() { scopedRoots.append(url) }
                    roots[source.id] = url
                    if stale {
                        source.bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                        source.path = url.path
                        try await db.saveSource(source)
                    }
                } catch { errorMessage = "无法访问 \(source.name)，请重新授权目录。\(error.localizedDescription)" }
            }
            if let saved = try await db.snapshot() {
                queue = saved.queue; currentID = saved.currentID; position = saved.position
                mode = PlayMode(rawValue: saved.mode) ?? .sequential; volume = saved.volume
            }
            let lists = try await db.loadPlaylists(); playlists = lists.0; playlistItems = lists.1
            selectedPlaylistID = playlists.first?.id
            stats = try await db.stats(); ready = true
        } catch { errorMessage = "无法打开音乐库数据库：\(error.localizedDescription)" }
    }
    func importFolders() {
        guard ready, !scanning else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "加入音乐库"; panel.message = "引用原始音频，不复制或修改文件。"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importSources(urls) }
    }
    func importSources(_ urls: [URL]) async {
            for url in urls {
                do {
                    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                    if sources.contains(where: { source in
                        let path = (roots[source.id] ?? URL(fileURLWithPath: source.path)).resolvingSymlinksInPath().standardizedFileURL.path
                        return path == resolved.path || path.hasPrefix(resolved.path + "/") || resolved.path.hasPrefix(path + "/")
                    }) { errorMessage = "这个目录或其父／子目录已在音乐库中。"; continue }
                    let accessed = url.startAccessingSecurityScopedResource()
                    if accessed { scopedRoots.append(url) }
                    let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                    let source = LibrarySource(id: UUID().uuidString, path: url.path, bookmark: bookmark, name: url.lastPathComponent)
                    try await database?.saveSource(source); sources.append(source); roots[source.id] = url
                    await refresh(source)
                } catch { errorMessage = "导入失败：\(error.localizedDescription)" }
            }
    }
    func refreshAll() { guard !scanning else { return }; Task { for source in sources { await refresh(source) } } }
    private func refresh(_ source: LibrarySource) async {
        scanning = true; defer { scanning = false }
        do {
            guard let root = roots[source.id], FileManager.default.fileExists(atPath: root.path) else { throw CocoaError(.fileReadNoSuchFile) }
            let scanned = try await scanner.scan(source: source, root: root)
            try await database?.scanResult(sourceID: source.id, scanned: scanned)
            if let library = try await database?.loadLibrary() { sources = library.0; tracks = library.1 }
        } catch { errorMessage = "无法刷新 \(source.name)。旧记录已保留，请检查磁盘或目录权限。\n\(error.localizedDescription)" }
    }
    func reauthorize(_ source: LibrarySource) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "重新授权"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                if url.startAccessingSecurityScopedResource() { scopedRoots.append(url) }
                var updated = source
                updated.path = url.path; updated.name = url.lastPathComponent
                updated.bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                try await database?.saveSource(updated); roots[source.id] = url
                await refresh(updated)
            } catch { errorMessage = error.localizedDescription }
        }
    }
    var selectedPlaylist: Playlist? { playlists.first { $0.id == selectedPlaylistID } ?? playlists.first }
    func items(in playlistID: String) -> [PlaylistItem] {
        playlistItems.filter { $0.playlistID == playlistID }.sorted { $0.position < $1.position }
    }
    func playPlaylist(_ playlist: Playlist, at itemID: String? = nil) {
        let entries = items(in: playlist.id)
        let index = itemID.flatMap { id in entries.firstIndex { $0.id == id } } ?? 0
        startQueue(trackIDs: entries.map(\.trackID), atIndex: index)
    }
    func draftPlaylist(trackIDs: [String] = []) { playlistDraft = PlaylistDraft(trackIDs: trackIDs) }
    private func playlistError(_ message: String) -> NSError { NSError(domain: "LittleEars.Playlists", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func playlistDatabase() throws -> LibraryDatabase {
        guard ready, let database else { throw playlistError("音乐库尚未准备好。") }
        guard !savingPlaylists else { throw playlistError("正在保存播放列表，请稍后再试。") }
        return database
    }
    private func validPlaylistName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw playlistError("请输入播放列表名称。") }
        guard name.count <= 100 else { throw playlistError("名称不能超过 100 个字符。") }
        return name
    }
    @discardableResult
    func createPlaylist(name: String, trackIDs: [String]) async throws -> Playlist {
        let db = try playlistDatabase()
        let playlist = Playlist(name: try validPlaylistName(name))
        let entries = trackIDs.enumerated().map { PlaylistItem(playlistID: playlist.id, trackID: $0.element, position: $0.offset) }
        savingPlaylists = true; defer { savingPlaylists = false }
        try await db.savePlaylist(playlist, items: entries)
        playlists.append(playlist); playlistItems.append(contentsOf: entries)
        selectedPlaylistID = playlist.id; page = "playlists"
        return playlist
    }
    private func persistPlaylist(_ playlist: Playlist, entries: [PlaylistItem], name: String? = nil) async throws {
        let db = try playlistDatabase()
        guard var updated = playlists.first(where: { $0.id == playlist.id }) else { throw playlistError("这个播放列表已被删除。") }
        if let name { updated.name = name }
        updated.updatedAt = Date()
        let normalized = entries.enumerated().map { index, item in var copy = item; copy.position = index; return copy }
        savingPlaylists = true; defer { savingPlaylists = false }
        try await db.savePlaylist(updated, items: normalized)
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) { playlists[index] = updated }
        playlistItems.removeAll { $0.playlistID == playlist.id }; playlistItems.append(contentsOf: normalized)
    }
    func appendTracks(_ trackIDs: [String], to playlist: Playlist) async throws {
        var entries = items(in: playlist.id)
        for trackID in trackIDs { entries.append(PlaylistItem(playlistID: playlist.id, trackID: trackID, position: entries.count)) }
        try await persistPlaylist(playlist, entries: entries)
    }
    func replacePlaylistTracks(_ playlist: Playlist, trackIDs: [String]) async throws {
        let entries = trackIDs.enumerated().map { PlaylistItem(playlistID: playlist.id, trackID: $0.element, position: $0.offset) }
        try await persistPlaylist(playlist, entries: entries)
    }
    func movePlaylistItems(in playlist: Playlist, from: IndexSet, to: Int) async throws {
        var entries = items(in: playlist.id)
        guard from.allSatisfy({ entries.indices.contains($0) }), (0...entries.count).contains(to) else { return }
        entries.move(fromOffsets: from, toOffset: to)
        try await persistPlaylist(playlist, entries: entries)
    }
    func removePlaylistItems(in playlist: Playlist, ids: Set<String>) async throws {
        try await persistPlaylist(playlist, entries: items(in: playlist.id).filter { !ids.contains($0.id) })
    }
    func renamePlaylist(_ playlist: Playlist, name: String) async throws {
        try await persistPlaylist(playlist, entries: items(in: playlist.id), name: validPlaylistName(name))
    }
    func deletePlaylist(_ playlist: Playlist) async throws {
        let db = try playlistDatabase()
        savingPlaylists = true; defer { savingPlaylists = false }
        try await db.deletePlaylist(id: playlist.id)
        playlists.removeAll { $0.id == playlist.id }; playlistItems.removeAll { $0.playlistID == playlist.id }
        if selectedPlaylistID == playlist.id { selectedPlaylistID = playlists.first?.id }
    }
    func fileURL(_ track: Track) -> URL? { roots[track.sourceID]?.appendingPathComponent(track.relativePath) }
    func reveal(_ track: Track) { if let url = fileURL(track) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func start(_ tracks: [Track], at track: Track? = nil) {
        startQueue(trackIDs: tracks.map(\.id), atIndex: track.flatMap { selected in tracks.firstIndex { $0.id == selected.id } } ?? 0)
    }
    private func startQueue(trackIDs: [String], atIndex: Int = 0) {
        guard !trackIDs.isEmpty else { return }
        finishSession(reason: "replaced", completed: false)
        engine.stop(); loadedTrackID = nil; isPlaying = false
        queue = trackIDs.map { QueueItem(trackID: $0) }
        currentID = queue[min(max(0, atIndex), queue.count - 1)].id
        position = 0; playCurrent()
    }
    func jump(_ item: QueueItem) {
        finishSession(reason: "skipped", completed: false)
        engine.stop(); loadedTrackID = nil; currentID = item.id; position = 0; playCurrent()
    }
    func togglePlayback() { isPlaying ? pause() : playCurrent() }
    func playCurrent() {
        guard ready else { return }
        if queue.isEmpty { if !visibleTracks.isEmpty { start(visibleTracks) }; return }
        if currentID == nil { currentID = queue.first?.id }
        guard let track = currentTrack else { return }
        do {
            if loadedTrackID != track.id {
                guard let url = fileURL(track), FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
                try engine.load(url, position: position); loadedTrackID = track.id
            } else if position >= engine.duration - 0.05 { try engine.seek(0); position = 0 }
            if session == nil { session = ListenSession(id: UUID().uuidString, trackID: track.id, startedAt: Date()); coverage = Coverage() }
            lastTick = ProcessInfo.processInfo.systemUptime; lastPosition = engine.position
            try engine.play(); isPlaying = true; updateNowPlaying(); checkpoint()
        } catch { skipUnavailable(startingAt: currentID, message: "无法播放「\(track.title)」：\(error.localizedDescription)") }
    }
    private func skipUnavailable(startingAt: String?, message: String) {
        finishSession(reason: "unavailable", completed: false); engine.stop(); loadedTrackID = nil; isPlaying = false
        let start = queue.firstIndex { $0.id == startingAt } ?? 0
        for offset in 1..<max(1, queue.count) {
            let index = start + offset
            if index >= queue.count && mode != .all { break }
            let item = queue[index % queue.count]
            guard let track = tracks.first(where: { $0.id == item.trackID }), let url = fileURL(track), FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try engine.load(url); loadedTrackID = track.id; currentID = item.id; position = 0
                session = ListenSession(id: UUID().uuidString, trackID: track.id, startedAt: Date()); coverage = Coverage()
                lastTick = ProcessInfo.processInfo.systemUptime; lastPosition = 0
                try engine.play(); isPlaying = true; updateNowPlaying(); errorMessage = message + "\n已跳过并播放下一条可用音频。"; return
            } catch { continue }
        }
        errorMessage = message + "\n没有下一条可播放的音频，播放已停止。"; checkpoint(); updateNowPlaying()
    }
    func pause() { tick(); engine.pause(); isPlaying = false; checkpoint(); updateNowPlaying() }
    func seek(_ seconds: Double) {
        guard loadedTrackID != nil else { position = seconds; checkpoint(); previewSpectrumIfNeeded(force: true); return }
        tick()
        do { try engine.seek(seconds); position = engine.position; lastPosition = position; lastTick = ProcessInfo.processInfo.systemUptime; checkpoint(); updateNowPlaying(); previewSpectrumIfNeeded(force: true) }
        catch { pause(); errorMessage = error.localizedDescription }
    }
    func previous() {
        if position > 3 { seek(0); return }
        guard let index = queue.firstIndex(where: { $0.id == currentID }), index > 0 else { seek(0); return }
        jump(queue[index - 1])
    }
    func next() {
        guard let index = queue.firstIndex(where: { $0.id == currentID }) else { return }
        if index + 1 < queue.count { jump(queue[index + 1]) }
        else if mode == .all, let first = queue.first { jump(first) }
        else { pause(); finishSession(reason: "skipped", completed: false) }
    }
    func cycleMode() { mode = mode == .sequential ? .all : mode == .all ? .one : .sequential; checkpoint() }
    func moveQueue(from: IndexSet, to: Int) { queue.move(fromOffsets: from, toOffset: to); checkpoint() }
    private func naturalEnd() {
        recordTick(finalPosition: engine.duration)
        position = engine.duration; isPlaying = false
        let completed = coverage.qualifies(duration: engine.duration, naturalEnd: true)
        finishSession(reason: "naturalEnd", completed: completed)
        guard let index = queue.firstIndex(where: { $0.id == currentID }) else { return }
        if mode == .one { loadedTrackID = nil; position = 0; playCurrent() }
        else if index + 1 < queue.count { currentID = queue[index + 1].id; loadedTrackID = nil; position = 0; playCurrent() }
        else if mode == .all { currentID = queue.first?.id; loadedTrackID = nil; position = 0; playCurrent() }
        else { checkpoint(); updateNowPlaying() }
    }
    private func tick() {
        if isPlaying { recordTick(finalPosition: engine.position); position = engine.position }
        if sinceCheckpoint >= 5 { checkpoint(); sinceCheckpoint = 0 }
    }
    private func recordTick(finalPosition: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastTick
        let progress = finalPosition - lastPosition
        defer { lastTick = now; lastPosition = finalPosition }
        guard isPlaying, var current = session, elapsed > 0, progress > 0 else { return }
        let seconds = min(elapsed, progress)
        coverage.add(from: lastPosition, to: finalPosition)
        current.listenedSeconds += seconds; session = current; sinceCheckpoint += seconds
        for (day, amount) in ListeningClock.split(start: Date().addingTimeInterval(-seconds), seconds: seconds) {
            if let last = pending.indices.last, pending[last].sessionID == current.id, pending[last].day == day {
                pending[last].seconds += amount
            } else {
                pending.append(ListenFragment(sessionID: current.id, trackID: current.trackID, day: day, seconds: amount))
            }
        }
    }
    private func finishSession(reason: String, completed: Bool) {
        if isPlaying { tick() }
        if var current = session {
            current.endedAt = Date(); current.endReason = reason; current.completed = completed
            current.completedDay = completed ? ListeningClock.day(Date()) : nil
            session = current; checkpoint(); session = nil; coverage = Coverage()
        }
    }
    private func checkpoint() {
        guard let db = database else { return }
        let current = session; let fragments = pending; pending.removeAll(); let state = snapshot; let prior = writeTask
        writeTask = Task {
            await prior?.value
            do {
                try await db.checkpoint(session: current, fragments: fragments, snapshot: state)
                stats = try await db.stats()
            } catch {
                pending.insert(contentsOf: fragments, at: 0)
                errorMessage = "保存播放记录失败：\(error.localizedDescription)"
            }
        }
    }
    func shutdown() async {
        pause(); finishSession(reason: "quit", completed: false); checkpoint(); await writeTask?.value
        scopedRoots.forEach { $0.stopAccessingSecurityScopedResource() }
    }
    private func setupRemoteControls() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.playCurrent() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlayback() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }; return .success
        }
    }
    func setSpectrumVisible(_ visible: Bool) { spectrumRequested = visible; synchronizeSpectrum(); previewSpectrumIfNeeded() }
    func setSpectrumEnabled(_ enabled: Bool) { spectrumEnabled = enabled; synchronizeSpectrum(); previewSpectrumIfNeeded() }
    func setSpectrumWindowVisible(_ visible: Bool) { spectrumWindowVisible = visible; synchronizeSpectrum(); previewSpectrumIfNeeded() }
    private func previewSpectrumIfNeeded(force: Bool = false) {
        guard spectrumRequested, spectrumEnabled, spectrumWindowVisible, !isPlaying,
              force || !spectrumDisplay.frame.levels.contains(where: { $0 > 0 }),
              let track = currentTrack, let url = fileURL(track) else { return }
        engine.spectrum.preview(url: url, position: position)
    }
    private func synchronizeSpectrum() { engine.spectrum.setActive(spectrumRequested && spectrumEnabled && spectrumWindowVisible && isPlaying) }
    private func updateNowPlaying() {
        synchronizeSpectrum()
        previewSpectrumIfNeeded()
        guard let track = currentTrack else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: track.duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0]
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
}
