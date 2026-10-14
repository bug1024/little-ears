import SwiftUI
import AppKit

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
                let tracks = Array(model.visibleTracks.prefix(5))
                _ = try await model.createPlaylist(name: "界面验证 · 精选音乐", trackIDs: tracks.map(\.id))
                model.volume = 0; model.start(tracks); model.pause()
            }
            for (name, page, dark) in [("library-dark", "library", true), ("library-light", "library", false), ("playing-dark", "playing", true), ("playlists-dark", "playlists", true), ("statistics-dark", "stats", true)] {
                model.page = page
                let content = ContentView().environmentObject(model).environment(\.colorScheme, dark ? .dark : .light)
                let hosting = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 730), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = hosting
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                hosting.frame = NSRect(x: 0, y: 0, width: 1140, height: 730)
                hosting.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(300))
                guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: target.appendingPathComponent(name + ".png")) }
                window.contentView = nil
            }
            await model.shutdown()
            exit(0)
        } catch { fputs("Preview rendering failed: \(error)\n", stderr); exit(1) }
    }
}
