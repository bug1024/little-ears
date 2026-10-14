import SwiftUI
import AppKit
import AVFoundation

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
