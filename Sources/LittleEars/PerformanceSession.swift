import AppKit
import Foundation
import Metal

/// Opt-in developer instrumentation. The release app does no sampling without the launch flag.
enum PerformanceSession {
    static let enabled = CommandLine.arguments.contains("--performance-session")
    private static let gpu = GPUCounters()

    private final class GPUCounters: @unchecked Sendable {
        let lock = NSLock()
        var frames = 0
        var errors = 0
        var seconds = 0.0
        var recent: [Double] = []
        func add(_ command: MTLCommandBuffer) {
            lock.lock(); defer { lock.unlock() }
            if command.status == .error { errors += 1; return }
            let duration = max(0, command.gpuEndTime - command.gpuStartTime)
            frames += 1; seconds += duration
            recent.append(duration * 1000)
            if recent.count > 240 { recent.removeFirst(recent.count - 240) }
        }
        func snapshot() -> [String: Any] {
            lock.lock(); defer { lock.unlock() }
            let sorted = recent.sorted()
            return ["completed_frames": frames, "command_errors": errors,
                    "gpu_seconds": seconds, "recent_gpu_ms_p95": sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]]
        }
    }

    static func track(command: MTLCommandBuffer) {
        command.addCompletedHandler { gpu.add($0) }
    }

    @MainActor
    static func start(directory: String, model: AppModel) async {
        while !model.ready && model.errorMessage == nil { try? await Task.sleep(for: .milliseconds(50)) }
        // Sound is muted after PCM analysis; the real decoding and render path stays active.
        model.volume = 0
        let target = URL(fileURLWithPath: directory).appendingPathComponent("runtime.json")
        var lastBeat = ProcessInfo.processInfo.systemUptime
        var lastReport = lastBeat - 2
        var beats: [Double] = []
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.systemUptime
                beats.append((now - lastBeat) * 1000); lastBeat = now
                guard now - lastReport >= 1 else { return }
                lastReport = now
                let windows = NSApp.windows.filter { $0.identifier?.rawValue == "main" || $0.title == "Little Ears" }
                let window = windows.first
                let a = model.aquarium.activity
                let sorted = beats.sorted()
                let payload: [String: Any] = [
                    "pid": ProcessInfo.processInfo.processIdentifier, "uptime": now,
                    "ready": model.ready, "tracks": model.tracks.count,
                    "lyrics": model.lyrics.records.count, "page": model.page,
                    "playing": model.isPlaying, "position": model.position,
                    "format": model.currentTrack?.format ?? "", "scanning": model.scanning,
                    "immersive": model.aquariumImmersive,
                    "window_visible": window?.isVisible ?? false,
                    "window_miniaturized": window?.isMiniaturized ?? false,
                    "window_occluded": !(window?.occlusionState.contains(.visible) ?? false),
                    "app_hidden": NSApp.isHidden,
                    "window_width_pt": window?.contentView?.bounds.width ?? 0,
                    "window_height_pt": window?.contentView?.bounds.height ?? 0,
                    "backing_scale": window?.backingScaleFactor ?? 0,
                    "aquarium_running": a.animate, "aquarium_fish": model.aquarium.configuration.totalFish,
                    "aquarium_jellies": model.aquarium.configuration.moonJellyCount,
                    "aquarium_power_saving": model.aquarium.configuration.energySaving,
                    "ambient_enabled": model.aquarium.configuration.ambientEnabled,
                    "drawable_width": model.aquarium.view?.drawableSize.width ?? 0,
                    "drawable_height": model.aquarium.view?.drawableSize.height ?? 0,
                    "gpu": gpu.snapshot(),
                    "main_loop_gap_ms_max": sorted.last ?? 0,
                    "main_loop_gap_ms_p95": sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)],
                    "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
                    "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
                    "error": model.errorMessage ?? model.aquarium.error ?? ""
                ]
                do { try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: target, options: .atomic) }
                catch { fputs("Performance telemetry write failed: \(error)\n", stderr) }
                beats.removeAll(keepingCapacity: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        // The run loop retains the timer for the lifetime of this isolated process.
    }
}
