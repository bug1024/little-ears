import Foundation
import AVFoundation
import Accelerate
import SwiftUI

struct SpectrumFrame: Sendable {
    var levels: [Float]
    var peaks: [Float]
    var sampleRate: Double
    static let empty = SpectrumFrame(levels: Array(repeating: 0, count: 64), peaks: Array(repeating: 0, count: 64), sampleRate: 44100)
}
@MainActor
final class SpectrumDisplay: ObservableObject {
    @Published var frame = SpectrumFrame.empty
}

/// All FFT state belongs to the analysis queue, never the audio render thread.
final class SpectrumProcessor {
    static let size = 4096
    static let bands = 64
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: size)
    private var windowed = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size / 2)
    private var imaginary = [Float](repeating: 0, count: size / 2)
    private var power = [Float](repeating: 0, count: size / 2)
    private var levels = [Float](repeating: 0, count: bands)
    private var peaks = [Float](repeating: 0, count: bands)
    init() {
        setup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    }
    deinit { vDSP_destroy_fftsetup(setup) }
    func reset() { levels = Array(repeating: 0, count: Self.bands); peaks = levels }
    static func frequencyRange(band: Int, sampleRate: Double) -> ClosedRange<Double> {
        let upper = min(16000, sampleRate / 2)
        let ratio = upper / 30
        return (30 * pow(ratio, Double(band) / Double(bands)))...(30 * pow(ratio, Double(band + 1) / Double(bands)))
    }
    func process(_ samples: [Float], sampleRate: Double) -> SpectrumFrame {
        guard samples.count == Self.size, sampleRate.isFinite, sampleRate > 100 else { return .empty }
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(Self.size))
        real.withUnsafeMutableBufferPointer { r in
            imaginary.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, 12, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(Self.size / 2))
            }
        }
        for band in 0..<Self.bands {
            let range = Self.frequencyRange(band: band, sampleRate: sampleRate)
            let lower = max(1, min(Self.size / 2 - 1, Int(range.lowerBound * Double(Self.size) / sampleRate)))
            let upper = max(lower + 1, min(Self.size / 2, Int(ceil(range.upperBound * Double(Self.size) / sampleRate))))
            let strongest = power[lower..<upper].max() ?? 0
            // vDSP's real FFT is scaled by 2; undo that scaling and the Hann coherent gain.
            let amplitude = sqrt(max(0, strongest)) / Float(Self.size / 2)
            let decibels = amplitude > 0 ? 20 * log10(amplitude) : -80
            let target = decibels.isFinite ? max(0, min(1, (decibels + 80) / 80)) : 0
            let coefficient: Float = target > levels[band] ? 0.62 : 0.14
            levels[band] += (target - levels[band]) * coefficient
            peaks[band] = max(levels[band], peaks[band] - 0.012)
        }
        return SpectrumFrame(levels: levels, peaks: peaks, sampleRate: sampleRate)
    }
}

/// The render callback only performs a nonblocking PCM copy / stereo mix into a preallocated ring.
/// A missed analysis frame is discarded instead of blocking audio playback.
final class SpectrumAnalyzer: @unchecked Sendable {
    private let lock = NSLock()
    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
    private let capacity = 16384
    private var written = 0
    private var writeIndex = 0
    private var sampleRate = 44100.0
    private var active = false
    private var revision = 0
    private var callback: (@Sendable (SpectrumFrame) -> Void)?
    private let queue = DispatchQueue(label: "LittleEars.Spectrum", qos: .utility)
    private let timer: DispatchSourceTimer
    private let processor = SpectrumProcessor()
    private var processorRevision = -1
    private var samples = [Float](repeating: 0, count: SpectrumProcessor.size)
    init() {
        ring.initialize(repeating: 0, count: capacity)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.analyze() }
        timer.resume()
    }
    deinit { timer.cancel(); ring.deinitialize(count: capacity); ring.deallocate() }
    func setCallback(_ callback: @escaping @Sendable (SpectrumFrame) -> Void) { lock.lock(); self.callback = callback; lock.unlock() }
    func setActive(_ value: Bool) {
        lock.lock()
        if active != value { active = value; written = 0; revision += 1 }
        lock.unlock()
    }
    func reset() {
        lock.lock(); written = 0; writeIndex = 0; revision += 1
        let callback = callback; lock.unlock()
        callback?(.empty)
    }
    func capture(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, !buffer.format.isInterleaved, buffer.frameLength > 0, lock.try() else { return }
        defer { lock.unlock() }
        guard active else { return }
        let rate = buffer.format.sampleRate
        if sampleRate != rate { written = 0; writeIndex = 0; revision += 1; sampleRate = rate }
        let count = min(Int(buffer.frameLength), capacity)
        let sourceOffset = Int(buffer.frameLength) - count
        if buffer.format.channelCount == 1 {
            let source = channels[0].advanced(by: sourceOffset)
            let first = min(count, capacity - writeIndex)
            ring.advanced(by: writeIndex).update(from: source, count: first)
            if first < count { ring.update(from: source.advanced(by: first), count: count - first) }
        } else {
            var destination = writeIndex
            for index in sourceOffset..<(sourceOffset + count) {
                ring[destination] = (channels[0][index] + channels[1][index]) * 0.5
                destination += 1
                if destination == capacity { destination = 0 }
            }
        }
        writeIndex = (writeIndex + count) % capacity
        written = min(capacity, written + count)
    }
    func preview(url: URL, position: Double) {
        lock.lock()
        guard !active else { lock.unlock(); return }
        revision += 1
        let token = revision
        lock.unlock()
        queue.async { [weak self] in self?.renderPreview(url: url, position: position, token: token) }
    }
    private func renderPreview(url: URL, position: Double, token: Int) {
        lock.lock(); let allowed = !active && revision == token; lock.unlock()
        guard allowed else { return }
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.sampleRate > 0, !file.processingFormat.isInterleaved,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(SpectrumProcessor.size)) else { return }
            let frame = AVAudioFramePosition(max(0, position) * file.processingFormat.sampleRate)
            file.framePosition = min(max(0, file.length - Int64(SpectrumProcessor.size)), frame)
            processor.reset(); processorRevision = token
            var result = SpectrumFrame.empty
            for _ in 0..<12 {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(SpectrumProcessor.size))
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
                samples.withUnsafeMutableBufferPointer { pointer in
                    vDSP_vclr(pointer.baseAddress!, 1, vDSP_Length(SpectrumProcessor.size))
                    let count = Int(buffer.frameLength)
                    if buffer.format.channelCount == 1 { pointer.baseAddress!.update(from: channels[0], count: count) }
                    else { for index in 0..<count { pointer[index] = (channels[0][index] + channels[1][index]) * 0.5 } }
                }
                result = processor.process(samples, sampleRate: file.processingFormat.sampleRate)
                if buffer.frameLength < SpectrumProcessor.size { break }
            }
            lock.lock(); let valid = !active && revision == token; let callback = callback; lock.unlock()
            if valid { callback?(result) }
        } catch { /* Unavailable files are handled by playback; viewing a page must not start an alert loop. */ }
    }
    private func analyze() {
        lock.lock()
        guard active, written >= SpectrumProcessor.size else { lock.unlock(); return }
        let token = revision
        let rate = sampleRate
        let callback = callback
        let start = (writeIndex - SpectrumProcessor.size + capacity) % capacity
        let first = min(SpectrumProcessor.size, capacity - start)
        samples.withUnsafeMutableBufferPointer { pointer in
            pointer.baseAddress!.update(from: ring.advanced(by: start), count: first)
            if first < SpectrumProcessor.size { pointer.baseAddress!.advanced(by: first).update(from: ring, count: SpectrumProcessor.size - first) }
        }
        // Retain an overlapping window but require new PCM before publishing another frame.
        written = SpectrumProcessor.size - 1
        lock.unlock()
        if processorRevision != token { processor.reset(); processorRevision = token }
        let frame = processor.process(samples, sampleRate: rate)
        lock.lock(); let valid = active && revision == token; lock.unlock()
        if valid { callback?(frame) }
    }
}
