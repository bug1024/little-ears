import AVFoundation
import Foundation

@MainActor
final class PlaybackEngine {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    let spectrum = SpectrumAnalyzer()
    private var file: AVAudioFile?
    private var offset: Double = 0
    private var generation = UUID()
    private(set) var running = false
    var onEnd: (() -> Void)?
    var configurationNotificationObject: AVAudioEngine { engine }
    var duration: Double { guard let file else { return 0 }; return Double(file.length) / file.processingFormat.sampleRate }
    var volume: Float { get { node.volume } set { node.volume = newValue } }
    var position: Double {
        guard let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render), time.sampleRate > 0 else { return offset }
        return min(duration, max(0, offset + Double(time.sampleTime) / time.sampleRate))
    }
    init() {
        engine.attach(node)
        let analyzer = spectrum
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in analyzer.capture(buffer) }
    }
    func load(_ url: URL, position: Double = 0) throws {
        stop()
        file = try AVAudioFile(forReading: url)
        guard duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: file!.processingFormat)
        engine.prepare()
        try engine.start()
        schedule(at: position)
    }
    private func schedule(at seconds: Double) {
        guard let file else { return }
        generation = UUID()
        let token = generation
        offset = min(max(0, seconds), max(0, duration - 0.01))
        let start = AVAudioFramePosition(offset * file.processingFormat.sampleRate)
        let count = AVAudioFrameCount(min(Int64(UInt32.max), file.length - start))
        node.scheduleSegment(file, startingFrame: start, frameCount: count, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.running = false
                self.offset = self.duration
                self.onEnd?()
            }
        }
    }
    func play() throws {
        guard file != nil else { return }
        if !engine.isRunning { try engine.start() }
        node.play(); running = true
    }
    func pause() { node.pause(); running = false }
    func seek(_ seconds: Double) throws {
        spectrum.reset()
        let resume = running
        generation = UUID(); node.stop(); running = false
        schedule(at: seconds)
        if resume { try play() }
    }
    func stop() { spectrum.setActive(false); spectrum.reset(); generation = UUID(); node.stop(); engine.stop(); running = false; file = nil; offset = 0 }
}
