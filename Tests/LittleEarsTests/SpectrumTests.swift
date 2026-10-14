import XCTest
import AVFoundation
@testable import LittleEars

private final class SpectrumCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [SpectrumFrame] = []
    func append(_ frame: SpectrumFrame) -> Bool { lock.lock(); defer { lock.unlock() }; frames.append(frame); return frames.count == 1 }
    var latest: SpectrumFrame? { lock.lock(); defer { lock.unlock() }; return frames.last }
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
}
final class SpectrumTests: XCTestCase {
    func testFFTTracksActualToneAtDifferentSampleRates() {
        for sampleRate in [44100.0, 48000.0] {
            for frequency in [220.0, 1000.0, 6000.0] {
                let processor = SpectrumProcessor()
                let samples = (0..<SpectrumProcessor.size).map { Float(0.5 * sin(2 * .pi * frequency * Double($0) / sampleRate)) }
                var frame = SpectrumFrame.empty
                for _ in 0..<12 { frame = processor.process(samples, sampleRate: sampleRate) }
                let strongest = frame.levels.indices.max { frame.levels[$0] < frame.levels[$1] }!
                let range = SpectrumProcessor.frequencyRange(band: strongest, sampleRate: sampleRate)
                XCTAssertGreaterThanOrEqual(frequency, range.lowerBound - 15)
                XCTAssertLessThanOrEqual(frequency, range.upperBound + 15)
                XCTAssertGreaterThan(frame.levels[strongest], 0.7)
                XCTAssertTrue(frame.levels.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
                XCTAssertEqual(frame.levels.count, 64)
            }
        }
    }
    func testSilenceAndDecayDoNotCreateRandomSpectrum() {
        let processor = SpectrumProcessor()
        let silence = [Float](repeating: 0, count: SpectrumProcessor.size)
        let empty = processor.process(silence, sampleRate: 44100)
        XCTAssertTrue(empty.levels.allSatisfy { $0 == 0 })
        let angularFrequency = 2.0 * Double.pi * 1000.0 / 44100.0
        let samples = (0..<SpectrumProcessor.size).map { Float(0.5 * sin(angularFrequency * Double($0))) }
        let audible = processor.process(samples, sampleRate: 44100)
        var previous = audible.levels.max()!
        for _ in 0..<10 {
            let frame = processor.process(silence, sampleRate: 44100)
            XCTAssertLessThan(frame.levels.max()!, previous)
            XCTAssertTrue(zip(frame.peaks, frame.levels).allSatisfy { pair in pair.0 >= pair.1 })
            previous = frame.levels.max()!
        }
        processor.reset()
        XCTAssertTrue(processor.process(silence, sampleRate: 44100).peaks.allSatisfy { $0 == 0 })
    }
    func testStereoRightChannelPCMIsIncluded() async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(SpectrumProcessor.size)))
        buffer.frameLength = AVAudioFrameCount(SpectrumProcessor.size)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        let step = 2.0 * Double.pi * 1000.0 / 44100.0
        for index in 0..<SpectrumProcessor.size { channels[0][index] = 0; channels[1][index] = Float(0.5 * sin(step * Double(index))) }
        let analyzer = SpectrumAnalyzer()
        let capture = SpectrumCapture()
        let ready = expectation(description: "Right channel has a real spectrum")
        analyzer.setCallback { frame in if capture.append(frame) { ready.fulfill() } }
        analyzer.setActive(true); analyzer.capture(buffer)
        await fulfillment(of: [ready], timeout: 1)
        analyzer.setActive(false)
        let frame = try XCTUnwrap(capture.latest)
        XCTAssertGreaterThan(frame.levels.max() ?? 0, 0.4)
    }
    func testPausedSnapshotReadsRealPCMWithoutPlaying() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try CoreTests.writeWAV(url, seconds: 2)
        let analyzer = SpectrumAnalyzer()
        let capture = SpectrumCapture()
        let snapshot = expectation(description: "Paused file PCM snapshot")
        analyzer.setCallback { frame in if capture.append(frame) { snapshot.fulfill() } }
        analyzer.preview(url: url, position: 0.5)
        await fulfillment(of: [snapshot], timeout: 1)
        let frame = try XCTUnwrap(capture.latest)
        let strongest = frame.levels.indices.max { frame.levels[$0] < frame.levels[$1] }!
        let range = SpectrumProcessor.frequencyRange(band: strongest, sampleRate: frame.sampleRate)
        XCTAssertGreaterThan(frame.levels[strongest], 0.3)
        XCTAssertGreaterThanOrEqual(440.0, range.lowerBound - 15)
        XCTAssertLessThanOrEqual(440.0, range.upperBound + 15)
        XCTAssertEqual(capture.count, 1)
    }
    @MainActor
    func testLivePlaybackTapPublishesRealFFTAndStopsWhenInactive() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try CoreTests.writeWAV(url, seconds: 2)
        let engine = PlaybackEngine()
        engine.volume = 0.2
        let capture = SpectrumCapture()
        let observed = expectation(description: "Real playback PCM reaches FFT")
        engine.spectrum.setCallback { frame in
            guard frame.levels.contains(where: { $0 > 0 }) else { return }
            if capture.append(frame) { observed.fulfill() }
        }
        try engine.load(url)
        engine.spectrum.setActive(true)
        try engine.play()
        await fulfillment(of: [observed], timeout: 2)
        let frame = try XCTUnwrap(capture.latest)
        let strongest = frame.levels.indices.max { frame.levels[$0] < frame.levels[$1] }!
        let range = SpectrumProcessor.frequencyRange(band: strongest, sampleRate: frame.sampleRate)
        XCTAssertGreaterThanOrEqual(440.0, range.lowerBound - 15)
        XCTAssertLessThanOrEqual(440.0, range.upperBound + 15)
        engine.pause(); engine.spectrum.setActive(false)
        try await Task.sleep(for: .milliseconds(120))
        let count = capture.count
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(capture.count, count)
        engine.stop()
    }
}
