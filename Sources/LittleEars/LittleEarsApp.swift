import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    var reopen: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { reopen?() }; return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { await model.shutdown(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
@main
struct LittleEarsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: AppModel
    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            let directory = CommandLine.arguments[index + 1]
            let historyIndex = CommandLine.arguments.firstIndex(of: "--preview-history")
            let historyPath = historyIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
            let instance = AppModel(databasePath: ":memory:", remoteControls: false, historySnapshotPath: historyPath)
            _model = StateObject(wrappedValue: instance)
            Task { @MainActor in await PreviewRenderer.render(directory: directory, model: instance) }
        } else if let index = CommandLine.arguments.firstIndex(of: "--measure-navigation"), CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            let instance = AppModel(databasePath: ":memory:", remoteControls: false)
            _model = StateObject(wrappedValue: instance)
            Task { @MainActor in await PreviewRenderer.measureNavigation(libraryPath: path, model: instance) }
        } else { _model = StateObject(wrappedValue: AppModel()) }
    }
    var body: some Scene {
        Window("Little Ears", id: "main") {
            MainScene(delegate: delegate).environmentObject(model)
                .onAppear { delegate.model = model }
        }.defaultSize(width: 1140, height: 760)
            .windowToolbarStyle(.unifiedCompact)
            .commands {
                CommandGroup(replacing: .newItem) { Button("添加音频目录…", action: model.importFolders).keyboardShortcut("o").disabled(!model.ready || model.scanning) }
                CommandMenu("播放") {
                    Button(model.isPlaying ? "暂停" : "播放", action: model.togglePlayback).keyboardShortcut("p")
                    Button("上一首", action: model.previous).keyboardShortcut(.leftArrow, modifiers: .command)
                    Button("下一首", action: model.next).keyboardShortcut(.rightArrow, modifiers: .command)
                    Button("切换播放模式", action: model.cycleMode).keyboardShortcut("r")
                }
            }
        Settings { SettingsView() }
    }
}
struct MainScene: View {
    @Environment(\.openWindow) var openWindow
    let delegate: AppDelegate
    @EnvironmentObject var model: AppModel
    @StateObject private var aquariumHUD = AquariumImmersiveHUD()
    var body: some View {
        ZStack {
            if model.aquariumImmersive {
                AquariumImmersiveView(hud: aquariumHUD).environmentObject(model)
            } else {
                ContentView()
            }
        }
            .background(AquariumFullScreenBridge(active: model.aquariumImmersive, exit: { model.aquariumImmersive = false }, activity: { aquariumHUD.recordActivity() }))
            .background(PlaybackKeyboardShortcuts(playingPage: model.page == "playing") { command in
                if model.aquariumImmersive { aquariumHUD.recordActivity() }
                switch command {
                case .togglePlayback: model.togglePlayback()
                case .previous: model.previousTrack()
                case .next: model.next()
                case .volumeUp: model.adjustVolume(by: 0.05)
                case .volumeDown: model.adjustVolume(by: -0.05)
                }
            })
            .onAppear { delegate.reopen = { openWindow(id: "main") } }
    }
}
