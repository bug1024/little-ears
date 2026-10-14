import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Developer-only offscreen snapshots of the real SwiftUI views. No sample tracks or statistics are injected.
@MainActor
enum PreviewRenderer {
    static func render(directory: String, model: AppModel) async {
        while !model.ready && model.errorMessage == nil { try? await Task.sleep(for: .milliseconds(100)) }
        do {
            let target = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            if let index = CommandLine.arguments.firstIndex(of: "--preview-library"), CommandLine.arguments.count > index + 1 {
                await model.importSources([URL(fileURLWithPath: CommandLine.arguments[index + 1])])
                let tracks = Array(model.visibleTracks.prefix(16))
                _ = try await model.createPlaylist(name: "界面验证 · 精选音乐", trackIDs: tracks.map(\.id))
                model.volume = 0; model.start(tracks); model.pause()
                model.seek(20); model.setSpectrumVisible(true)
                try? await Task.sleep(for: .milliseconds(100))
            }
            if CommandLine.arguments.contains("--spectrum-motion"), model.currentTrack != nil {
                try await renderSpectrumMotion(model: model, target: target)
            }
            model.volume = 0
            for (name, page, dark) in [("library-dark", "library", true), ("library-light", "library", false), ("playing-dark", "playing", true), ("playlists-dark", "playlists", true), ("statistics-dark", "stats", true), ("playing-light", "playing", false), ("playlists-light", "playlists", false), ("statistics-light", "stats", false), ("compact-playing-dark", "playing", true), ("compact-library-light", "library", false)] {
                model.page = page
                let width: CGFloat = name.hasPrefix("compact") ? 900 : 1140
                let height: CGFloat = name.hasPrefix("compact") ? 600 : 730
                let content = ContentView(persistSidebarWidth: false).environmentObject(model).environment(\.colorScheme, dark ? .dark : .light)
                let hosting = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = hosting
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
                hosting.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(300))
                guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: target.appendingPathComponent(name + ".png")) }
                window.contentView = nil
            }
            model.page = "stats"
            for dark in [true, false] {
                try await snapshot(ContentView(persistSidebarWidth: false).environmentObject(model).environment(\.colorScheme, dark ? .dark : .light), name: dark ? "compact-statistics-dark" : "compact-statistics-light", width: 900, height: 600, dark: dark, target: target)
            }
            for dark in [true, false] {
                let palette = Palette(dark: dark, accentName: "blue")
                model.sleepTimer.start(.minutes(15))
                try await snapshot(SleepTimerPopover(timer: model.sleepTimer, palette: palette, hasTrack: model.currentTrack != nil).environment(\.colorScheme, dark ? .dark : .light), name: dark ? "sleep-timer-dark" : "sleep-timer-light", width: 232, height: 270, dark: dark, target: target)
                model.sleepTimer.cancel()
                if let track = model.tracks.first {
                    let id = model.stats.tracks.first?.trackID ?? track.id
                    let selection = TrackDetailsTarget(id: id, track: model.tracks.first { $0.id == id })
                    try await snapshot(TrackStatisticsView(target: selection).environmentObject(model).environment(\.colorScheme, dark ? .dark : .light), name: dark ? "track-details-dark" : "track-details-light", width: 620, height: 540, dark: dark, target: target)
                }
                let grid = ListeningCalendar(year: Calendar.current.component(.year, from: Date()))
                let day = grid.days.first { $0.id == model.stats.days.last?.day } ?? grid.days.first { $0.isToday }!
                try await snapshot(DailyListeningDetailsView(day: day).environmentObject(model).environment(\.colorScheme, dark ? .dark : .light), name: dark ? "daily-details-dark" : "daily-details-light", width: 620, height: 540, dark: dark, target: target)
                for accent in ["mint", "lavender", "coral"] {
                    try await snapshot(ListeningFootprintView(palette: Palette(dark: dark, accentName: accent)).environmentObject(model).environment(\.colorScheme, dark ? .dark : .light), name: "footprint-\(accent)-\(dark ? "dark" : "light")", width: 860, height: 220, dark: dark, target: target)
                }
                let unplayed = model.tracks.first { track in !model.stats.tracks.contains { $0.trackID == track.id } }
                let emptyTrack = TrackDetailsTarget(id: unplayed?.id ?? "no-records", track: unplayed)
                try await snapshot(TrackStatisticsView(target: emptyTrack).environmentObject(model).environment(\.colorScheme, dark ? .dark : .light), name: dark ? "track-empty-dark" : "track-empty-light", width: 620, height: 540, dark: dark, target: target)
            }
            try await verifySidebar(model: model, target: target)
            if model.currentTrack != nil {
                model.page = "playing"; model.playCurrent()
                try? await Task.sleep(for: .milliseconds(150))
                for dark in [true, false] {
                    try await snapshot(ContentView(persistSidebarWidth: false).environmentObject(model).environment(\.colorScheme, dark ? .dark : .light), name: dark ? "playing-active-dark" : "playing-active-light", width: 1140, height: 730, dark: dark, target: target)
                }
                model.pause()
            }
            for dark in [true, false] {
                let hosting = NSHostingView(rootView: SettingsView().environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 390), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = hosting; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                hosting.frame = NSRect(x: 0, y: 0, width: 490, height: 390); hosting.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(200))
                if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: target.appendingPathComponent(dark ? "settings-dark.png" : "settings-light.png"))
                }
                window.contentView = nil
            }
            for dark in [true, false] {
                let sheet = PlaylistNameSheet(draft: PlaylistDraft()).environmentObject(model).environment(\.colorScheme, dark ? .dark : .light)
                try await snapshot(sheet, name: dark ? "playlist-sheet-dark" : "playlist-sheet-light", width: 380, height: 214, dark: dark, target: target)
            }
            let empty = AppModel(databasePath: ":memory:", remoteControls: false)
            while !empty.ready && empty.errorMessage == nil { try? await Task.sleep(for: .milliseconds(50)) }
            for (page, name, dark) in [("library", "empty-library-light", false), ("playing", "empty-playing-dark", true)] {
                empty.page = page
                let content = ContentView(persistSidebarWidth: false).environmentObject(empty).environment(\.colorScheme, dark ? .dark : .light)
                try await snapshot(content, name: name, width: 1140, height: 730, dark: dark, target: target)
            }
            await empty.shutdown()
            await model.shutdown()
            exit(0)
        } catch { fputs("Preview rendering failed: \(error)\n", stderr); exit(1) }
    }
    /// Developer benchmark: real library, in-memory DB, no playback, same window and rendering path.
    static func measureNavigation(libraryPath: String, model: AppModel) async {
        while !model.ready && model.errorMessage == nil { try? await Task.sleep(for: .milliseconds(50)) }
        await model.importSources([URL(fileURLWithPath: libraryPath)])
        let hosting = NSHostingView(rootView: ContentView(persistSidebarWidth: false).environmentObject(model).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 730), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; hosting.frame = NSRect(x: 0, y: 0, width: 1140, height: 730)
        window.appearance = NSAppearance(named: .darkAqua)
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        var times: [Double] = []; var evaluations: [Int] = []; var rebuilds: [Int] = []; var layouts: [Double] = []
        for _ in 0..<6 {
            model.page = "playing"; hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
            let count = model.visibleTracksEvaluationCount
            let rebuildCount = model.visibleTracksRebuildCount
            let start = ProcessInfo.processInfo.systemUptime
            model.page = "library"
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            layouts.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
            times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            evaluations.append(model.visibleTracksEvaluationCount - count)
            rebuilds.append(model.visibleTracksRebuildCount - rebuildCount)
        }
        let result: [String: Any] = ["tracks": model.tracks.count, "library_switch_and_offscreen_draw_ms": times, "visible_tracks_evaluations": evaluations, "visible_tracks_rebuilds": rebuilds, "library_layout_ms": layouts]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), let string = String(data: data, encoding: .utf8) { print(string) }
        window.contentView = nil
        await model.shutdown(); exit(0)
    }

    /// Sampled animation of the actual player / FFT views, using muted output and source PCM.
    private static func renderSpectrumMotion(model: AppModel, target: URL) async throws {
        model.page = "playing"; model.volume = 0; model.setSpectrumVisible(true)
        let width = 900, height = 600, perPhase = 8
        var measurements: [[String: Any]] = []
        let destination = CGImageDestinationCreateWithURL(target.appendingPathComponent("spectrum-motion.gif") as CFURL, UTType.gif.identifier as CFString, 5 * perPhase, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let hosting = NSHostingView(rootView: MotionScene(model: model, phase: "开始播放"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        defer { window.contentView = nil; model.pause() }
        for phase in ["开始播放", "暂停 · 保留最后一帧", "恢复播放", "跳转播放位置", "切换下一首"] {
            hosting.rootView = MotionScene(model: model, phase: phase)
            switch phase {
            case "开始播放", "恢复播放": model.playCurrent()
            case "暂停 · 保留最后一帧": model.pause()
            case "跳转播放位置": model.seek(35)
            default: model.next()
            }
            for _ in 0..<perPhase {
                let start = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(for: .milliseconds(125))
                hosting.layoutSubtreeIfNeeded()
                guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                guard let source = bitmap.cgImage,
                      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
                guard let image = context.makeImage() else { continue }
                let delay = ProcessInfo.processInfo.systemUptime - start
                measurements.append(["phase": phase, "seconds": model.position, "title": model.currentTrack?.title ?? "", "levels": model.spectrumDisplay.frame.levels, "delay": delay])
                CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(to: target.appendingPathComponent("spectrum-motion.json"))
    }
    private struct MotionScene: View {
        @ObservedObject var model: AppModel
        let phase: String
        var body: some View {
            VStack(spacing: 0) {
                Text("动态验证 · \(phase) · 输出静音").font(.system(size: 11)).padding(8)
                NowPlayingView(palette: Palette(dark: true, accentName: "blue")).environmentObject(model)
            }.font(.system(size: 12)).foregroundStyle(Palette(dark: true, accentName: "blue").text)
                .background(Palette(dark: true, accentName: "blue").background).environment(\.colorScheme, .dark)
        }
    }

    /// Exercises AppKit's actual divider constraints separately from visual snapshots.
    private static func verifySidebar(model: AppModel, target: URL) async throws {
        model.page = "playing"
        let hosting = NSHostingView(rootView: ContentView(persistSidebarWidth: false).environmentObject(model).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 730), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 1140, height: 730)
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        func findSplit(_ view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            for child in view.subviews { if let split = findSplit(child) { return split } }
            return nil
        }
        guard let split = findSplit(hosting), let sidebar = split.subviews.first else {
            throw NSError(domain: "LittleEars.Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native sidebar divider missing"])
        }
        var results: [String] = []
        for (width, requested, expected, name) in [(1140.0, 100.0, 196.0, "sidebar-minimum"), (1140.0, 340.0, 340.0, "sidebar-wide"), (1140.0, 500.0, 360.0, "sidebar-maximum"), (900.0, 500.0, 280.0, "sidebar-compact")] {
            window.setContentSize(NSSize(width: width, height: 730))
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
            split.setPosition(requested, ofDividerAt: 0)
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
            let actual = sidebar.frame.width
            results.append("window=\(width), requested=\(requested), actual=\(actual), expected=\(expected)")
            guard abs(actual - expected) < 2 else {
                throw NSError(domain: "LittleEars.Preview", code: 2, userInfo: [NSLocalizedDescriptionKey: results.joined(separator: "\n")])
            }
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: target.appendingPathComponent(name + ".png"))
            }
        }
        try results.joined(separator: "\n").write(to: target.appendingPathComponent("sidebar-validation.txt"), atomically: true, encoding: .utf8)
        window.contentView = nil
    }

    private static func snapshot<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat, dark: Bool, target: URL) async throws {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height); hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: target.appendingPathComponent(name + ".png"))
        }
        window.contentView = nil
    }

}
