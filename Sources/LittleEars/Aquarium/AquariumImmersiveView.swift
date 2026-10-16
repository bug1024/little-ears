import SwiftUI
import AppKit

struct AquariumAmbientButton: View {
    @ObservedObject var controller: AquariumController
    var body: some View {
        Button(action: controller.toggleAmbient) {
            Label("气泡音", systemImage: controller.configuration.ambientEnabled ? "speaker.wave.2" : "speaker.slash")
        }
        .help(controller.configuration.ambientEnabled ? "关闭气泡环境音" : "开启气泡环境音")
        .accessibilityLabel("气泡环境音")
        .accessibilityValue(controller.configuration.ambientEnabled ? "已开启" : "已关闭")
    }
}

@MainActor
final class AquariumImmersiveHUD: ObservableObject {
    @Published private(set) var visible = false
    private var lastActivity: TimeInterval = 0
    private var hovering = false
    func beginSession(accessibilityVisible: Bool = false, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        hovering = false
        lastActivity = time
        visible = accessibilityVisible
    }
    func recordActivity(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastActivity = time
        if !visible { visible = true }
    }
    func setHovering(_ value: Bool, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        hovering = value
        lastActivity = time
        if value && !visible { visible = true }
    }
    func hideIfIdle(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if !hovering && time - lastActivity >= 3 && visible { visible = false }
    }
}

struct AquariumImmersiveView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var hud: AquariumImmersiveHUD
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    private let palette = Palette(dark: true, accentName: "blue")
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AquariumSurface(controller: model.aquarium, musicPlaying: model.isPlaying)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .ignoresSafeArea()
                VStack {
                    HStack {
                        Spacer()
                        Button { model.aquariumImmersive = false } label: {
                            Label("退出全屏", systemImage: "arrow.down.right.and.arrow.up.left")
                        }.help("退出沉浸全屏 · Esc")
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                            .padding(9).modifier(AquariumHUDSurface(radius: 11))
                            .onHover { hud.setHovering($0) }
                    }
                    Spacer()
                    VStack(spacing: 4) {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.currentTrack.map { model.displayName($0) } ?? "水族箱").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text(model.currentTrack?.folder ?? "静静看一会儿鱼，也很好").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 14) {
                                Button(action: model.previousTrack) { Image(systemName: "backward.end.fill") }.accessibilityLabel("上一首")
                                Button(action: model.togglePlayback) { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 19)) }.accessibilityLabel(model.isPlaying ? "暂停" : "播放")
                                Button(action: model.next) { Image(systemName: "forward.end.fill") }.accessibilityLabel("下一首")
                            }.buttonStyle(.borderless).disabled(model.currentTrack == nil)
                                .frame(height: 28)
                            Divider().frame(height: 24)
                            AquariumAmbientButton(controller: model.aquarium).controlSize(.small)
                            HStack(spacing: 6) {
                                Image(systemName: model.volume == 0 ? "speaker.slash" : "speaker.wave.2").foregroundStyle(.secondary)
                                Slider(value: Binding(get: { Double(model.volume) }, set: { model.volume = Float($0) }), in: 0...1)
                                    .frame(width: 80).controlSize(.small).accessibilityLabel("音乐音量")
                            }
                        }
                        PlaybackProgress(palette: palette)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .modifier(AquariumHUDSurface(radius: 15))
                    .frame(maxWidth: 720)
                    .onHover { hud.setHovering($0) }
                }
                .padding(.horizontal, max(20, geometry.size.width * 0.035)).padding(.top, 18).padding(.bottom, 16)
                .opacity(hud.visible ? 1 : 0)
                .allowsHitTesting(hud.visible).accessibilityHidden(!hud.visible)
                .animation(reducedMotion ? nil : .easeOut(duration: hud.visible ? 0.16 : 0.70), value: hud.visible)
            }
        }
        .background(.black).foregroundStyle(.white).preferredColorScheme(.dark).tint(palette.accent)
        .onAppear { hud.beginSession(accessibilityVisible: NSWorkspace.shared.isVoiceOverEnabled); model.setSpectrumVisible(false) }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                if NSWorkspace.shared.isVoiceOverEnabled { hud.recordActivity() } else { hud.hideIfIdle() }
            }
        }
    }
}

/// Native window-local blur with a dark tint, separate from control opacity.
private struct AquariumHUDSurface: ViewModifier {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reducedTransparency
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if !reducedTransparency { AquariumHUDGlass() }
                    Color.black.opacity(reducedTransparency ? 0.88 : 0.36)
                }.allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
    }
}
private struct AquariumHUDGlass: NSViewRepresentable {
    final class EffectView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> EffectView {
        let view = EffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: EffectView, context: Context) {}
}

/// Keeps the window's original fullscreen state, including an exit requested during an entry animation.
struct AquariumFullScreenSession {
    enum Action: Equatable { case none, enter, exit, restoreLayout }
    private(set) var active = false
    private(set) var originallyFullScreen: Bool?
    private(set) var transitioning = false
    mutating func update(active: Bool, fullScreen: Bool) -> Action {
        if active && originallyFullScreen == nil { originallyFullScreen = fullScreen }
        self.active = active
        return reconcile(fullScreen: fullScreen)
    }
    mutating func willTransition() { transitioning = true }
    mutating func didEnter() -> Action { transitioning = false; return reconcile(fullScreen: true) }
    mutating func didExit() -> Action {
        transitioning = false
        let restore = active
        active = false; originallyFullScreen = nil
        return restore ? .restoreLayout : .none
    }
    private mutating func reconcile(fullScreen: Bool) -> Action {
        guard let original = originallyFullScreen, !transitioning else { return .none }
        if active {
            if !fullScreen && !original { transitioning = true; return .enter }
        } else {
            if fullScreen && !original { transitioning = true; return .exit }
            originallyFullScreen = nil
        }
        return .none
    }
}

struct AquariumFullScreenBridge: NSViewRepresentable {
    let active: Bool
    let exit: () -> Void
    let activity: () -> Void
    func makeNSView(context: Context) -> BridgeView { BridgeView() }
    func updateNSView(_ view: BridgeView, context: Context) {
        view.exit = exit; view.activity = activity; view.requestedActive = active
        // Window transitions and callbacks must happen after SwiftUI's view update.
        view.scheduleUpdate()
    }
    static func dismantleNSView(_ view: BridgeView, coordinator: ()) { view.cleanUp() }

    final class BridgeView: NSView {
        var exit: (() -> Void)?
        var activity: (() -> Void)?
        var requestedActive = false
        private var session = AquariumFullScreenSession()
        private var tokens: [NSObjectProtocol] = []
        private var monitor: Any?
        private var originalMouseMoved: Bool?
        private var scheduled = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { cleanUp(); return }
            guard tokens.isEmpty else { return }
            for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.willCloseNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    guard let self else { return }
                    switch note.name {
                    case NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification: self.session.willTransition()
                    case NSWindow.didEnterFullScreenNotification: self.perform(self.session.didEnter())
                    case NSWindow.didExitFullScreenNotification: self.perform(self.session.didExit())
                    case NSWindow.willCloseNotification:
                        self.session = AquariumFullScreenSession(); self.requestedActive = false
                        self.restoreMouseEvents(); self.exit?()
                    default: break
                    }
                })
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .scrollWheel, .keyDown]) { [weak self] event in
                guard let self, self.requestedActive, let window = self.window, event.window === window, window.isKeyWindow else { return event }
                // Ignore synthetic pointer movement while AppKit animates entry.
                if event.type != .mouseMoved || !self.session.transitioning { self.activity?() }
                if event.type == .keyDown && event.keyCode == 53 && window.attachedSheet == nil { self.exit?(); return nil }
                return event
            }
            scheduleUpdate()
        }
        func scheduleUpdate() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.scheduled = false
                guard let window = self.window else { return }
                if self.requestedActive && self.originalMouseMoved == nil {
                    self.originalMouseMoved = window.acceptsMouseMovedEvents
                    window.acceptsMouseMovedEvents = true
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(nil)
                } else if !self.requestedActive { self.restoreMouseEvents() }
                self.perform(self.session.update(active: self.requestedActive, fullScreen: window.styleMask.contains(.fullScreen)))
            }
        }
        private func perform(_ action: AquariumFullScreenSession.Action) {
            switch action {
            case .none: break
            case .enter, .exit: window?.toggleFullScreen(nil)
            case .restoreLayout: requestedActive = false; restoreMouseEvents(); exit?()
            }
        }
        private func restoreMouseEvents() {
            if let originalMouseMoved { window?.acceptsMouseMovedEvents = originalMouseMoved; self.originalMouseMoved = nil }
        }
        func cleanUp() {
            restoreMouseEvents()
            for token in tokens { NotificationCenter.default.removeObserver(token) }; tokens.removeAll()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
        deinit {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
