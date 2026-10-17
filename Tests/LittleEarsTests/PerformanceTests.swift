import XCTest
import MetalKit
import Darwin
@testable import LittleEars

/// Explicitly enabled component benchmarks, separate from on-screen app measurements.
final class PerformanceTests: XCTestCase {
    private static func waitForGPU(_ command: MTLCommandBuffer) { command.waitUntilCompleted() }

    func testOptionalAquariumGPUCapacity() async throws {
        guard let output = ProcessInfo.processInfo.environment["LITTLE_EARS_PERFORMANCE_OUTPUT"] else {
            throw XCTSkip("Set LITTLE_EARS_PERFORMANCE_OUTPUT to run opt-in GPU benchmarks")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let assets = root.appendingPathComponent("build/Little Ears.app/Contents/Resources/AquariumAssets")
        guard MTLCreateSystemDefaultDevice() != nil, FileManager.default.fileExists(atPath: assets.appendingPathComponent("tank.json").path) else { throw XCTSkip("Local Metal assets unavailable") }
        let maxFish = Dictionary(uniqueKeysWithValues: (300...313).map { ($0, $0 == 313 ? 1 : 3) })
        let allFish = Dictionary(uniqueKeysWithValues: (300...327).map { ($0, 1) })
        let standard = AquariumConfiguration().fishCounts
        var results: [[String: Any]] = []
        for (name, population, jellies, width, height, shadow, fps) in [
            ("default_window", standard, 3, 1204, 778, 2048, 30),
            ("default_fullscreen", standard, 3, 2560, 1607, 2048, 30),
            ("all_species_fullscreen", allFish, 3, 2560, 1607, 2048, 30),
            ("max_population_fullscreen", maxFish, 5, 2560, 1607, 2048, 30),
            ("max_population_power_saving", maxFish, 5, 1280, 804, 1024, 24),
            ("no_fish_fullscreen", [:], 0, 2560, 1607, 2048, 30)
        ] {
            let initialized = ProcessInfo.processInfo.systemUptime
            let renderer = try TankRenderer(assets: assets, shader: AquariumResources.shader, shadowResolution: shadow, population: population)
            renderer.moonJellyCount = jellies
            let initializationMS = (ProcessInfo.processInfo.systemUptime - initialized) * 1000
            func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
                d.storageMode = .private; d.usage = .renderTarget
                return try XCTUnwrap(renderer.device.makeTexture(descriptor: d))
            }
            let color = try texture(.bgra8Unorm_srgb), depth = try texture(.depth32Float)
            var cpuMS: [Double] = [], gpuMS: [Double] = []
            var errors = 0
            for i in 0..<150 {
                let start = ProcessInfo.processInfo.systemUptime
                renderer.simulation.step(Float(1.0 / Double(fps * 2)))
                renderer.simulation.step(Float(1.0 / Double(fps * 2)))
                let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
                renderer.encodeShadows(command)
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = color
                pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
                pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.storeAction = .dontCare; pass.depthAttachment.clearDepth = 1
                let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
                renderer.encode(encoder, width: width, height: height); encoder.endEncoding()
                command.commit()
                let cpuTime = (ProcessInfo.processInfo.systemUptime - start) * 1000
                Self.waitForGPU(command)
                if command.error != nil { errors += 1 }
                if i >= 30 {
                    cpuMS.append(cpuTime)
                    gpuMS.append(max(0, command.gpuEndTime - command.gpuStartTime) * 1000)
                }
                let remaining = 1.0 / Double(fps) - (ProcessInfo.processInfo.systemUptime - start)
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            }
            func p95(_ values: [Double]) -> Double { values.sorted()[Int(Double(values.count - 1) * 0.95)] }
            results.append(["scenario": name, "fish": population.values.reduce(0, +), "jellies": jellies,
                            "width": width, "height": height, "shadow": shadow, "target_fps": fps,
                            "frames": cpuMS.count, "initialization_ms": initializationMS,
                            "cpu_encode_ms_mean": cpuMS.reduce(0, +) / Double(cpuMS.count),
                            "cpu_encode_ms_p95": p95(cpuMS), "gpu_ms_mean": gpuMS.reduce(0, +) / Double(gpuMS.count),
                            "gpu_ms_p95": p95(gpuMS), "metal_errors": errors])
            XCTAssertEqual(errors, 0)
        }
        let target = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: target.appendingPathComponent("gpu-components.json"))
    }
    @MainActor
    func testOptionalAudioAndLibraryResources() async throws {
        guard let output = ProcessInfo.processInfo.environment["LITTLE_EARS_PERFORMANCE_OUTPUT"] else {
            throw XCTSkip("Set LITTLE_EARS_PERFORMANCE_OUTPUT to run resource benchmarks")
        }
        let target = URL(fileURLWithPath: output)
        let source = target.appendingPathComponent("source-snapshot.sqlite")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("A read-only database snapshot is required") }
        let db = try LibraryDatabase(path: ":memory:", copyingHistoryFrom: source.path)
        let (sources, tracks) = try await db.loadLibrary()
        let roots = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.path) })
        var results: [String: Any] = [:]
        let lyrics = LyricsLibrary()
        var start = ProcessInfo.processInfo.systemUptime
        try await lyrics.configure(db)
        results["lyrics_load_parse_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
        results["lyrics_records"] = lyrics.records.count
        start = ProcessInfo.processInfo.systemUptime
        await lyrics.importFiles(sources.map { URL(fileURLWithPath: $0.path) }, tracks: tracks, roots: roots)
        results["lyrics_batch_default_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
        results["lyrics_batch_default_summary"] = lyrics.message ?? ""
        start = ProcessInfo.processInfo.systemUptime
        await lyrics.importFiles(sources.map { URL(fileURLWithPath: $0.path) }, tracks: tracks, roots: roots, overwriteExisting: true)
        results["lyrics_batch_overwrite_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
        results["lyrics_batch_overwrite_summary"] = lyrics.message ?? ""
        var queryMS: [Double] = []
        for _ in 0..<30 {
            let t = ProcessInfo.processInfo.systemUptime
            _ = try await db.stats()
            _ = try await db.yearlyListeningStats(startDay: "2026-01-01", endDayExclusive: "2027-01-01")
            if let track = tracks.first { _ = try await db.trackStatistics(track.id, startDay: nil, endDay: "2026-12-31") }
            queryMS.append((ProcessInfo.processInfo.systemUptime - t) * 1000)
        }
        results["three_statistics_queries_ms_median"] = queryMS.sorted()[15]
        results["three_statistics_queries_ms_p95"] = queryMS.sorted()[27]
        func footprint() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : -1
        }
        let playable = ["FLAC", "MP3"].compactMap { format in tracks.first { $0.format.uppercased() == format } }
        XCTAssertEqual(playable.count, 2, "Real FLAC and MP3 fixtures are required for this audit")
        let engine = PlaybackEngine(); engine.volume = 0
        var samples: [[String: Any]] = []
        var loadsMS: [Double] = []
        for i in 0..<80 {
            let track = playable[i % playable.count]
            let root = try XCTUnwrap(roots[track.sourceID])
            let url = URL(fileURLWithPath: root).appendingPathComponent(track.relativePath)
            let t = ProcessInfo.processInfo.systemUptime
            try engine.load(url, position: min(20, track.duration / 2)); try engine.play()
            loadsMS.append((ProcessInfo.processInfo.systemUptime - t) * 1000)
            try await Task.sleep(for: .milliseconds(250))
            let before = engine.position
            try engine.seek(min(35, track.duration / 2))
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(engine.running); XCTAssertGreaterThan(engine.position, before)
            engine.pause(); engine.stop()
            if i % 10 == 9 { samples.append(["cycles": i + 1, "footprint_mib": footprint()]) }
        }
        results["audio_cycles"] = 80
        results["audio_load_play_ms_median"] = loadsMS.sorted()[40]
        results["audio_load_play_ms_p95"] = loadsMS.sorted()[75]
        results["audio_memory_samples"] = samples
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: target.appendingPathComponent("library-audio-components.json"))
    }

    @MainActor
    func testOptionalFreshLyricsImport() async throws {
        guard let output = ProcessInfo.processInfo.environment["LITTLE_EARS_PERFORMANCE_OUTPUT"] else {
            throw XCTSkip("Set LITTLE_EARS_PERFORMANCE_OUTPUT to run resource benchmarks")
        }
        let target = URL(fileURLWithPath: output)
        let snapshot = try LibraryDatabase(path: ":memory:", copyingHistoryFrom: target.appendingPathComponent("source-snapshot.sqlite").path)
        let (sources, tracks) = try await snapshot.loadLibrary()
        let fresh = try LibraryDatabase(path: ":memory:")
        for source in sources {
            try await fresh.saveSource(source)
            try await fresh.scanResult(sourceID: source.id, scanned: tracks.filter { $0.sourceID == source.id })
        }
        let library = LyricsLibrary(); try await library.configure(fresh)
        let start = ProcessInfo.processInfo.systemUptime
        await library.importFiles(sources.map { URL(fileURLWithPath: $0.path) }, tracks: tracks, roots: Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.path) }))
        let result: [String: Any] = ["milliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                                    "records": library.records.count, "summary": library.message ?? ""]
        XCTAssertGreaterThan(library.records.count, 0)
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: target.appendingPathComponent("lyrics-fresh-import.json"))
    }

    @MainActor
    func testOptionalCatalogScale() async throws {
        guard let output = ProcessInfo.processInfo.environment["LITTLE_EARS_PERFORMANCE_OUTPUT"] else {
            throw XCTSkip("Set LITTLE_EARS_PERFORMANCE_OUTPUT to run catalog benchmarks")
        }
        let target = URL(fileURLWithPath: output)
        let snapshot = try LibraryDatabase(path: ":memory:", copyingHistoryFrom: target.appendingPathComponent("source-snapshot.sqlite").path)
        let (_, sourceTracks) = try await snapshot.loadLibrary()
        guard !sourceTracks.isEmpty else { throw XCTSkip("A real library snapshot is required") }
        let domain = "LittleEars.PerformanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = AppModel(databasePath: ":memory:", remoteControls: false, preferences: defaults)
        while !model.ready && model.errorMessage == nil { try await Task.sleep(for: .milliseconds(20)) }
        var results: [[String: Any]] = []
        for size in [sourceTracks.count, 1000, 5000, 10000] {
            model.search = ""
            // Replicated real metadata stresses sorting/cache only; no fake files are read.
            model.tracks = (0..<size).map { i in
                let original = sourceTracks[i % sourceTracks.count]
                return Track(id: "scale-\(i)", sourceID: original.sourceID, relativePath: original.relativePath,
                             identity: "scale-\(i)", title: original.title, duration: original.duration,
                             format: original.format, fileSize: original.fileSize, available: original.available)
            }
            var start = ProcessInfo.processInfo.systemUptime
            let count = model.visibleTracks.count
            let coldMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let rebuilds = model.visibleTracksRebuildCount
            start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<100 { XCTAssertEqual(model.visibleTracks.count, count) }
            let cachedMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            XCTAssertEqual(model.visibleTracksRebuildCount, rebuilds)
            start = ProcessInfo.processInfo.systemUptime
            model.search = "晴天"
            let searchCount = model.visibleTracks.count
            let searchMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            results.append(["tracks": size, "cold_sort_ms": coldMS, "cached_100_reads_ms": cachedMS,
                            "search_ms": searchMS, "search_results": searchCount])
        }
        await model.shutdown()
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: target.appendingPathComponent("catalog-scale.json"))
    }

}
