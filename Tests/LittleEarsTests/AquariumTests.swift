import XCTest
import MetalKit
import SwiftUI
@testable import LittleEars

final class AquariumTests: XCTestCase {
    func testOldScenePreferencesGainJelliesWithoutLosingUserChoices() throws {
        var previous = AquariumConfiguration()
        previous.fishCounts = [306: 2]; previous.ambientEnabled = true; previous.ambientVolume = 0.27; previous.energySaving = true
        let encoded = try JSONEncoder().encode(previous)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "moonJellyCount")
        json["jellyfishOnly"] = true // Removed experimental setting must be ignored.
        let migrated = try JSONDecoder().decode(AquariumConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated, previous)
        previous.moonJellyCount = 100
        XCTAssertEqual(previous.normalized().moonJellyCount, 5)
        previous.moonJellyCount = -1
        XCTAssertEqual(previous.normalized().moonJellyCount, 0)
    }
    func testOptionalMoonJellyGeometryRendersAndChangesWithTime() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let assets = root.appendingPathComponent("build/Little Ears.app/Contents/Resources/AquariumAssets")
        guard MTLCreateSystemDefaultDevice() != nil, FileManager.default.fileExists(atPath: assets.appendingPathComponent("tank.json").path) else { throw XCTSkip("Local assets unavailable") }
        let renderer = try TankRenderer(assets: assets, shader: AquariumResources.shader, population: [:])
        renderer.moonJellyCount = 3; renderer.bubbles = false
        let a = try XCTUnwrap(renderer.offscreen(width: 1208, height: 800))
        renderer.simulation.synchronizeClock(to: 1.3)
        let b = try XCTUnwrap(renderer.offscreen(width: 1208, height: 800))
        renderer.moonJellyCount = 0
        let empty = try XCTUnwrap(renderer.offscreen(width: 1208, height: 800))
        func changed(_ a: CGImage, _ b: CGImage) -> Int {
            let lhs = a.dataProvider!.data! as Data, rhs = b.dataProvider!.data! as Data
            return stride(from: 0, to: lhs.count, by: 4).filter { i in (0..<3).contains { abs(Int(lhs[i + $0]) - Int(rhs[i + $0])) > 3 } }.count
        }
        XCTAssertGreaterThan(changed(a, b), 2000, "Real GPU geometry and material must move between frames")
        XCTAssertGreaterThan(changed(b, empty), 5000, "Jellies must actually contribute visible pixels")

    }
    func testOptionalDiscreteBubblesAreCentralSparseAndAnimated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let assets = root.appendingPathComponent("build/Little Ears.app/Contents/Resources/AquariumAssets")
        guard MTLCreateSystemDefaultDevice() != nil, FileManager.default.fileExists(atPath: assets.appendingPathComponent("tank.json").path) else { throw XCTSkip("Local assets unavailable") }
        let renderer = try TankRenderer(assets: assets, shader: AquariumResources.shader, population: [:])
        let first = try XCTUnwrap(renderer.offscreen(width: 640, height: 360))
        renderer.simulation.synchronizeClock(to: 1.3)
        let next = try XCTUnwrap(renderer.offscreen(width: 640, height: 360))
        renderer.bubbles = false
        let off = try XCTUnwrap(renderer.offscreen(width: 640, height: 360))
        func changes(_ a: CGImage, _ b: CGImage, central: Bool) -> Int {
            let lhs = a.dataProvider!.data! as Data, rhs = b.dataProvider!.data! as Data
            var count = 0
            for y in 0..<180 { for x in 0..<640 where ((300..<390).contains(x)) == central {
                let i = y * a.bytesPerRow + x * 4
                if (0..<3).contains(where: { abs(Int(lhs[i + $0]) - Int(rhs[i + $0])) > 3 }) { count += 1 }
            } }
            return count
        }
        XCTAssertGreaterThan(changes(next, off, central: true), 30)
        XCTAssertLessThan(changes(next, off, central: true), 1500, "Bubbles must remain discrete, leaving clear water between them")
        XCTAssertEqual(changes(next, off, central: false), 0)
        XCTAssertGreaterThan(changes(first, next, central: true), 30)
    }
    @MainActor
    func testOutgoingViewCannotStealIncomingSurfaceBinding() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let controller = AquariumController(assets: nil)
        let oldID = UUID(), newID = UUID()
        let old = AquariumMetalView(frame: .zero, device: device)
        let incoming = AquariumMetalView(frame: .zero, device: device)
        controller.present(owner: oldID, reducedMotion: false)
        controller.bind(old, owner: oldID)
        controller.bind(incoming, owner: newID)
        controller.bind(old, owner: oldID) // SwiftUI's last outgoing update.
        controller.present(owner: newID, reducedMotion: false)
        XCTAssertTrue(controller.view === incoming)
        controller.bind(old, owner: oldID)
        controller.unbind(old, owner: oldID)
        controller.dismiss(owner: oldID)
        XCTAssertTrue(controller.view === incoming)
        XCTAssertTrue(controller.activity.presented)
        incoming.onWindowChange?()
        XCTAssertTrue(controller.view === incoming)
        controller.unbind(incoming, owner: newID)
        controller.dismiss(owner: newID)
        XCTAssertNil(controller.view)
        XCTAssertFalse(controller.activity.presented)
    }
    @MainActor
    func testMetalViewUsesContinuousLoopAndReturnsFromStaticOrHiddenState() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = AquariumMetalView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), device: device)
        for _ in 0..<3 {
            view.updateRenderLoop(animate: true, displayStaticFrame: true)
            XCTAssertFalse(view.enableSetNeedsDisplay, "Event-driven mode disables the continuous render loop")
            XCTAssertFalse(view.isPaused)
            view.updateRenderLoop(animate: false, displayStaticFrame: false)
            XCTAssertTrue(view.isPaused)
            view.updateRenderLoop(animate: false, displayStaticFrame: true)
            XCTAssertTrue(view.enableSetNeedsDisplay)
            XCTAssertTrue(view.isPaused)
        }
        view.updateRenderLoop(animate: true, displayStaticFrame: true)
        XCTAssertFalse(view.enableSetNeedsDisplay)
        XCTAssertFalse(view.isPaused)
        view.updateRenderLoop(animate: false, displayStaticFrame: false)
    }
    func testImmersionRestoresWindowAndHandlesExitDuringEntry() {
        var session = AquariumFullScreenSession()
        XCTAssertEqual(session.update(active: true, fullScreen: false), .enter)
        XCTAssertEqual(session.update(active: true, fullScreen: false), .none)
        XCTAssertEqual(session.update(active: false, fullScreen: false), .none)
        XCTAssertEqual(session.didEnter(), .exit)
        XCTAssertEqual(session.didExit(), .none)
        XCTAssertNil(session.originallyFullScreen)
        XCTAssertEqual(session.update(active: true, fullScreen: false), .enter)
        XCTAssertEqual(session.didEnter(), .none)
        XCTAssertEqual(session.update(active: false, fullScreen: true), .exit)
        XCTAssertEqual(session.didExit(), .none)
    }
    func testImmersionKeepsExistingFullscreenAndFollowsNativeExit() {
        var session = AquariumFullScreenSession()
        XCTAssertEqual(session.update(active: true, fullScreen: true), .none)
        XCTAssertEqual(session.update(active: false, fullScreen: true), .none)
        XCTAssertNil(session.originallyFullScreen)
        XCTAssertEqual(session.update(active: true, fullScreen: true), .none)
        session.willTransition()
        XCTAssertEqual(session.didExit(), .restoreLayout)
        XCTAssertFalse(session.active)
    }
    @MainActor
    func testImmersionControlsStayVisibleDuringInteraction() {
        let hud = AquariumImmersiveHUD()
        XCTAssertFalse(hud.visible)
        hud.beginSession(at: 1)
        XCTAssertFalse(hud.visible)
        hud.setHovering(false, at: 2)
        XCTAssertFalse(hud.visible) // An initial hover-exit must not flash the HUD.
        hud.recordActivity(at: 10)
        hud.hideIfIdle(at: 12.9); XCTAssertTrue(hud.visible)
        hud.hideIfIdle(at: 13); XCTAssertFalse(hud.visible)
        hud.recordActivity(at: 14); XCTAssertTrue(hud.visible)
        hud.setHovering(true, at: 15)
        hud.hideIfIdle(at: 100); XCTAssertTrue(hud.visible)
        hud.setHovering(false, at: 101)
        hud.hideIfIdle(at: 103); XCTAssertTrue(hud.visible)
        hud.hideIfIdle(at: 104); XCTAssertFalse(hud.visible)
        hud.recordActivity(at: 105)
        hud.beginSession(at: 106)
        XCTAssertFalse(hud.visible) // Re-entering fullscreen starts hidden again.
        hud.beginSession(accessibilityVisible: true, at: 107)
        XCTAssertTrue(hud.visible)
    }
    @MainActor
    func testAmbientShortcutPersistsWithoutChangingOtherSettings() {
        let name = "LittleEars.AquariumTests.shortcut.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var original = AquariumConfiguration()
        original.fishCounts = [306: 2]; original.ambientVolume = 0.32; original.energySaving = true
        original.save(to: defaults)
        let controller = AquariumController(defaults: defaults, assets: nil)
        controller.toggleAmbient()
        original.ambientEnabled = true
        XCTAssertEqual(controller.configuration, original)
        XCTAssertEqual(AquariumConfiguration.load(from: defaults), original)
        controller.toggleAmbient()
        XCTAssertFalse(AquariumController(defaults: defaults, assets: nil).configuration.ambientEnabled)
        XCTAssertNil(controller.renderer); XCTAssertNil(controller.ambient)
    }
    @MainActor
    func testOldPresentationCannotStopImmersiveSurface() {
        let controller = AquariumController(assets: nil)
        let normal = UUID(), immersive = UUID()
        controller.present(owner: normal, reducedMotion: false)
        controller.present(owner: immersive, reducedMotion: false)
        controller.dismiss(owner: normal)
        XCTAssertTrue(controller.activity.presented)
        controller.dismiss(owner: immersive)
        XCTAssertFalse(controller.activity.presented)
    }
    func testConfigurationNormalizesAndSurvivesReload() throws {
        let name = "LittleEars.AquariumTests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: "LittleEars.AquariumTests.temporary")!
        defaults.removePersistentDomain(forName: "LittleEars.AquariumTests.temporary")
        defer { defaults.removePersistentDomain(forName: "LittleEars.AquariumTests.temporary") }
        var configuration = AquariumConfiguration()
        configuration.fishCounts = Dictionary(uniqueKeysWithValues: (299...329).map { ($0, 10) })
        configuration.fishCounts[300] = -4
        configuration.ambientVolume = .nan
        configuration.ambientEnabled = true; configuration.blueBackdrop = true; configuration.energySaving = true
        let normalized = configuration.normalized()
        XCTAssertEqual(normalized.totalFish, 40)
        XCTAssertFalse(normalized.fishCounts.keys.contains(299)); XCTAssertFalse(normalized.fishCounts.keys.contains(328))
        XCTAssertNil(normalized.fishCounts[300]); XCTAssertTrue(normalized.fishCounts.values.allSatisfy { (1...3).contains($0) })
        XCTAssertEqual(normalized.ambientVolume, 0.16)
        configuration.save(to: defaults)
        XCTAssertEqual(AquariumConfiguration.load(from: defaults), normalized)
        defaults.set(Data(name.utf8), forKey: AquariumConfiguration.defaultsKey)
        XCTAssertEqual(AquariumConfiguration.load(from: defaults), AquariumConfiguration())
    }
    func testLifecycleGateForEveryVisibilityAndMotionCombination() {
        for presented in [false, true] { for visible in [false, true] { for hidden in [false, true] { for asleep in [false, true] { for reduced in [false, true] {
            let activity = AquariumActivity(presented: presented, windowVisible: visible, appHidden: hidden, systemAsleep: asleep, reducedMotion: reduced)
            XCTAssertEqual(activity.canRun, presented && visible && !hidden && !asleep)
            XCTAssertEqual(activity.animate, activity.canRun && !reduced)
        } } } } }
    }
    func testPopulationSupportsRepeatedAndEmptySpecies() throws {
        let reef = ReefCollider(points: [])
        let profiles = Array(repeating: FishProfile(spawnScale: 0.6, collisionRadius: 0.5), count: 40)
        let indices = (0..<40).map { $0 % 14 }
        let simulation = try TankSimulation(collider: reef, profiles: profiles, speciesIndices: indices)
        XCTAssertEqual(simulation.swimmers.count, 40)
        XCTAssertEqual(simulation.swimmers.map(\.species), indices)
        for (i, fish) in simulation.swimmers.enumerated() {
            for other in simulation.swimmers.prefix(i) { XCTAssertGreaterThan(simd_distance(fish.position, other.position), fish.radius + other.radius) }
        }
        simulation.synchronizeClock(to: 55)
        XCTAssertEqual(simulation.time, 55)
        XCTAssertTrue(try TankSimulation(collider: reef, profiles: [], speciesIndices: []).swimmers.isEmpty)
    }
    @MainActor
    func testMissingAssetsAreRecoverableAndDoNotCreateAudioOrRenderer() async {
        let defaults = UserDefaults(suiteName: "LittleEars.AquariumTests.missing")!
        defer { defaults.removePersistentDomain(forName: "LittleEars.AquariumTests.missing") }
        let controller = AquariumController(defaults: defaults, assets: nil)
        await controller.prepare()
        XCTAssertNotNil(controller.error); XCTAssertNil(controller.renderer); XCTAssertNil(controller.ambient)
        XCTAssertFalse(controller.loading)
        controller.setPresented(true); XCTAssertFalse(controller.activity.canRun)
        controller.stop(); XCTAssertFalse(controller.activity.presented)
    }
    @MainActor
    func testApplyingSceneKeepsTimelineAndCachesRenderer() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let assets = root.appendingPathComponent("build/Little Ears.app/Contents/Resources/AquariumAssets")
        guard MTLCreateSystemDefaultDevice() != nil, FileManager.default.fileExists(atPath: assets.appendingPathComponent("tank.json").path) else { throw XCTSkip("Local assets unavailable") }
        let domain = "LittleEars.AquariumTests.apply.\(UUID().uuidString)", defaults = UserDefaults(suiteName: "LittleEars.AquariumTests.apply")!
        defaults.removePersistentDomain(forName: "LittleEars.AquariumTests.apply")
        defer { defaults.removePersistentDomain(forName: "LittleEars.AquariumTests.apply") }
        let controller = AquariumController(defaults: defaults, assets: assets)
        await controller.prepare()
        let renderer = try XCTUnwrap(controller.renderer)
        renderer.simulation.synchronizeClock(to: 43)
        var config = controller.configuration
        config.fishCounts = [306: 2, 314: 1, 325: 1]
        config.energySaving = true; config.blueBackdrop = true
        let applied = await controller.apply(config)
        XCTAssertTrue(applied)
        XCTAssertTrue(controller.renderer === renderer)
        XCTAssertEqual(renderer.simulation.time, 43)
        XCTAssertEqual(renderer.simulation.swimmers.count, 4)
        XCTAssertEqual(renderer.simulation.swimmers.filter { renderer.data.species[$0.species].id == 306 }.count, 2)
        XCTAssertEqual(renderer.shadowMap.width, 1024)
        XCTAssertTrue(renderer.blueBackdrop)
        let simulation = renderer.simulation
        config.ambientVolume = 0; config.ambientEnabled = true; config.showStarfish = false
        let reapplied = await controller.apply(config)
        XCTAssertTrue(reapplied); XCTAssertTrue(renderer.simulation === simulation)
        XCTAssertFalse(renderer.showStarfish); XCTAssertFalse(controller.ambient?.isPlaying ?? true)
        XCTAssertEqual(AquariumConfiguration.load(from: defaults), config.normalized())
        let host = NSHostingView(rootView: AquariumSettingsPanel(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 650)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 400, domain)
        controller.setPresented(true)
        XCTAssertFalse(controller.activity.canRun) // No visible window.
        XCTAssertFalse(renderer.running)
        controller.setPresented(false)
        await controller.prepare()
        XCTAssertTrue(controller.renderer === renderer)
        XCTAssertTrue(renderer.simulation === simulation)
        config.fishCounts = [:]
        let cleared = await controller.apply(config)
        XCTAssertTrue(cleared)
        XCTAssertTrue(renderer.simulation.swimmers.isEmpty)
        XCTAssertNotNil(try renderer.offscreen(width: 320, height: 240))
        controller.stop()
    }
    func testOptionalLocalAssetsRenderConfiguredPopulation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let assets = root.appendingPathComponent("build/Little Ears.app/Contents/Resources/AquariumAssets")
        guard MTLCreateSystemDefaultDevice() != nil, FileManager.default.fileExists(atPath: assets.appendingPathComponent("tank.json").path) else { throw XCTSkip("Local aquarium assets/Metal not available") }
        let configuration = AquariumConfiguration()
        let renderer = try TankRenderer(assets: assets, shader: AquariumResources.shader, shadowResolution: 1024, population: configuration.fishCounts)
        XCTAssertEqual(renderer.simulation.swimmers.count, 8)
        XCTAssertEqual(Set(renderer.simulation.swimmers.map { renderer.data.species[$0.species].id }), Set(configuration.fishCounts.keys))
        XCTAssertNotNil(try renderer.offscreen(width: 320, height: 240))
        XCTAssertEqual(renderer.shadowMap.width, 1024)
        try renderer.resizeShadowMap(to: 2048); XCTAssertEqual(renderer.shadowMap.width, 2048)
        // The restored, denser reef must still admit every species and the full population.
        for count in [28, 40] {
            let indices = (0..<count).map { $0 % renderer.data.species.count }
            let profiles = indices.map { FishProfile(spawnScale: renderer.data.species[$0].spawnScale!, collisionRadius: renderer.data.species[$0].collisionRadius!) }
            let simulation = try TankSimulation(collider: renderer.simulation.collider, profiles: profiles, speciesIndices: indices)
            XCTAssertEqual(simulation.swimmers.count, count)
            for _ in 0..<90 { simulation.step(1 / 60) }
            XCTAssertEqual(simulation.unresolvedContacts, 0)
        }
    }
}
