import SwiftUI
import MetalKit

@MainActor
final class AquariumController: ObservableObject {
    @Published private(set) var configuration: AquariumConfiguration
    @Published private(set) var renderer: TankRenderer?
    @Published private(set) var catalog: [AquariumSpecies] = []
    @Published private(set) var loading = false
    @Published private(set) var applying = false
    @Published private(set) var error: String?
    @Published private(set) var activity = AquariumActivity()
    private(set) var ambient: BubbleAudioController?
    private let defaults: UserDefaults
    private let assets: URL?
    private(set) weak var view: AquariumMetalView?
    private struct SurfaceBinding { weak var view: AquariumMetalView? }
    private var surfaces: [UUID: SurfaceBinding] = [:]
    private weak var window: NSWindow?
    private var tokens: [NSObjectProtocol] = []
    private var musicPlaying = false
    private var sleepMuted = false
    private var presentationOwner: UUID?

    init(defaults: UserDefaults = .standard, assets: URL? = AquariumResources.assets) {
        self.defaults = defaults; self.assets = assets
        configuration = AquariumConfiguration.load(from: defaults)
        observeLifecycle()

    }
    func prepare() async {
        guard renderer == nil, !loading else { return }
        guard let assets else { error = "当前应用未包含水族箱场景资源。"; return }
        loading = true; error = nil
        let config = configuration, shader = AquariumResources.shader
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let catalog = try AquariumResources.catalog(at: assets)
                let renderer = try TankRenderer(assets: assets, shader: shader, shadowResolution: config.shadowResolution, population: config.fishCounts)
                return (renderer, catalog)
            }.value
            renderer = result.0; catalog = result.1
            ambient = BubbleAudioController(url: assets.appendingPathComponent("bubbles.wav"))
            configureSurfaces(); reconcile()
        } catch { self.error = "水族箱加载失败：\(error.localizedDescription)" }
        loading = false
    }
    @discardableResult
    func apply(_ draft: AquariumConfiguration) async -> Bool {
        guard !applying else { return false }
        applying = true; defer { applying = false }
        let next = draft.normalized()
        do {
            var pendingSimulation: TankSimulation?
            if let renderer, next.fishCounts != configuration.fishCounts {
                let data = renderer.data
                let indices = data.species.indices.flatMap { index in Array(repeating: index, count: next.fishCounts[data.species[index].id] ?? 0) }
                let profiles = try indices.map { index -> FishProfile in
                    guard let scale = data.species[index].spawnScale, let radius = data.species[index].collisionRadius else { throw AquariumError.unavailable("Missing fish dimensions") }
                    return FishProfile(spawnScale: scale, collisionRadius: radius)
                }
                let simulation = try await Task.detached(priority: .userInitiated) {
                    try TankSimulation(collider: ReefCollider(points: data.collisionTriangles, margins: data.collisionMargins), profiles: profiles, speciesIndices: indices)
                }.value
                pendingSimulation = simulation
            }
            try renderer?.resizeShadowMap(to: next.shadowResolution)
            if let renderer, let pendingSimulation {
                pendingSimulation.synchronizeClock(to: renderer.simulation.time)
                renderer.simulation = pendingSimulation; renderer.fishCounts = next.fishCounts
            }
            configuration = next; next.save(to: defaults)
            sleepMuted = false; error = nil
            configureSurfaces(); reconcile()
            return true
        } catch { self.error = "无法应用场景，请减少鱼的数量后重试。\n\(error.localizedDescription)"; return false }
    }
    func setPresented(_ presented: Bool, reducedMotion: Bool = false) {
        guard activity.presented != presented || activity.reducedMotion != reducedMotion else { return }
        activity.presented = presented; activity.reducedMotion = reducedMotion; reconcile()
    }
    func present(owner: UUID, reducedMotion: Bool) {
        presentationOwner = owner
        if let view = surfaces[owner]?.view { activate(view) }
        setPresented(true, reducedMotion: reducedMotion)
    }
    func dismiss(owner: UUID) {
        guard presentationOwner == owner else { return }
        presentationOwner = nil
        setPresented(false)
    }
    func setMusicPlaying(_ playing: Bool) {
        musicPlaying = playing
        if playing { sleepMuted = false }
        renderer?.simulationRate = playing ? 1 : 0.55
        reconcile()
    }
    func muteForSleepTimer() { sleepMuted = true; reconcile() }
    func toggleAmbient() {
        // This only changes the sound switch; an unapplied settings draft must not overwrite other saved fields.
        var next = configuration
        next.ambientEnabled.toggle()
        configuration = next
        next.save(to: defaults)
        sleepMuted = false
        reconcile()
    }
    func bind(_ view: AquariumMetalView, owner: UUID) {
        surfaces[owner] = SurfaceBinding(view: view)
        view.onWindowChange = { [weak self, weak view] in
            guard let self, let view, self.presentationOwner == owner else { return }
            self.activate(view)
        }
        if presentationOwner == owner { activate(view) }
    }
    private func activate(_ view: AquariumMetalView) {
        guard self.view !== view || self.window !== view.window else { return }
        // SwiftUI can update the outgoing view after creating the incoming one.
        // Only the surface that actually appeared may own the render loop.
        if self.view !== view { self.view?.isPaused = true }
        self.view = view; self.window = view.window
        configureSurfaces(); updateVisibility()
    }
    func unbind(_ view: AquariumMetalView, owner: UUID) {
        view.isPaused = true; view.delegate = nil; view.onWindowChange = nil
        if surfaces[owner]?.view === view { surfaces.removeValue(forKey: owner) }
        guard self.view === view else { return }
        self.view = nil; window = nil; activity.windowVisible = false; reconcile()
    }
    func stop() {
        activity.presented = false; reconcile(); ambient?.stop()
    }
    private func configureSurfaces() {
        renderer?.moonJellyCount = configuration.moonJellyCount
        renderer?.blueBackdrop = configuration.blueBackdrop
        renderer?.showMoray = configuration.showMoray; renderer?.showStarfish = configuration.showStarfish
        renderer?.caustics = configuration.caustics; renderer?.bubbles = configuration.bubbles
        renderer?.simulationRate = musicPlaying ? 1 : 0.55
        view?.preferredFramesPerSecond = configuration.framesPerSecond
        view?.maximumDimension = configuration.maximumDrawableDimension
        view?.updateResolution()
    }
    private func updateVisibility() {
        var next = activity
        next.windowVisible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        next.appHidden = NSApp?.isHidden ?? false
        if next != activity { activity = next }
        reconcile()
    }
    private func reconcile() {
        renderer?.running = activity.animate
        renderer?.backgroundMotion = !activity.reducedMotion
        renderer?.resetFrameClock()
        view?.updateRenderLoop(animate: activity.animate, displayStaticFrame: activity.canRun)
        let volume = configuration.ambientVolume * (configuration.duckDuringPlayback && musicPlaying ? 0.35 : 1)
        if ambient?.volume != volume { ambient?.volume = volume }
        if ambient?.enabled != configuration.ambientEnabled { ambient?.enabled = configuration.ambientEnabled }
        ambient?.setExternalActivity(activity.canRun && !sleepMuted)
    }
    private func observeLifecycle() {
        let center = NotificationCenter.default
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let affected = note.object as? NSWindow
                Task { @MainActor in
                    guard let self, affected === self.window else { return }
                    if name == NSWindow.willCloseNotification { self.activity.windowVisible = false; self.reconcile() }
                    else { self.updateVisibility() }
                }
            })
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.updateVisibility() } })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
                guard let self else { return }; self.activity.systemAsleep = name == NSWorkspace.willSleepNotification; self.updateVisibility()
            } })
        }
    }
    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token); NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
}

@MainActor
final class AquariumMetalView: MTKView {
    var onWindowChange: (() -> Void)?
    var maximumDimension: CGFloat = 2560
    func updateRenderLoop(animate: Bool, displayStaticFrame: Bool) {
        // enableSetNeedsDisplay=true pauses MetalKit's internal display loop, even
        // when isPaused is subsequently set to false. Use it only for static frames.
        if enableSetNeedsDisplay == animate { enableSetNeedsDisplay = !animate }
        if isPaused == animate { isPaused = !animate }
        if !animate && displayStaticFrame { needsDisplay = true }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateResolution(); onWindowChange?() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateResolution() }
    func updateResolution() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(window?.backingScaleFactor ?? 1, maximumDimension / max(bounds.width, bounds.height))
        drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    }
}

struct AquariumSurface: View {
    @ObservedObject var controller: AquariumController
    let musicPlaying: Bool
    @Environment(\.accessibilityReduceMotion) var reducedMotion
    @State private var presentationID = UUID()
    var body: some View {
        ZStack {
            Color(red: 0.015, green: 0.025, blue: 0.05)
            if let renderer = controller.renderer {
                AquariumMetalSurface(controller: controller, renderer: renderer, presentationID: presentationID)
            } else if controller.loading { ProgressView("正在准备水族箱…").tint(.white) }
            else if let error = controller.error {
                VStack(spacing: 10) { Image(systemName: "fish"); Text(error).multilineTextAlignment(.center); Button("重试") { Task { await controller.prepare() } } }
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).padding()
            }
        }.clipped()
            .task { await controller.prepare() }
            .onAppear { controller.present(owner: presentationID, reducedMotion: reducedMotion); controller.setMusicPlaying(musicPlaying) }
            .onDisappear { controller.dismiss(owner: presentationID) }
            .onChange(of: musicPlaying) { _, value in controller.setMusicPlaying(value) }
            .onChange(of: reducedMotion) { _, value in controller.present(owner: presentationID, reducedMotion: value) }
    }
}
struct AquariumMetalSurface: NSViewRepresentable {
    let controller: AquariumController
    let renderer: TankRenderer
    let presentationID: UUID
    final class Coordinator {
        weak var controller: AquariumController?
        let owner: UUID
        init(owner: UUID) { self.owner = owner }
    }
    func makeCoordinator() -> Coordinator { Coordinator(owner: presentationID) }
    func makeNSView(context: Context) -> AquariumMetalView {
        context.coordinator.controller = controller
        let view = AquariumMetalView(frame: .zero, device: renderer.device)
        view.autoResizeDrawable = false; view.isPaused = true
        view.colorPixelFormat = .bgra8Unorm_srgb; view.depthStencilPixelFormat = .depth32Float
        view.delegate = renderer; view.setAccessibilityLabel("水族箱实时场景")
        controller.bind(view, owner: presentationID); return view
    }
    func updateNSView(_ view: AquariumMetalView, context: Context) { if view.delegate !== renderer { view.delegate = renderer }; controller.bind(view, owner: presentationID) }
    static func dismantleNSView(_ view: AquariumMetalView, coordinator: Coordinator) { coordinator.controller?.unbind(view, owner: coordinator.owner) }
}
