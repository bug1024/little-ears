import Foundation
import AVFoundation
import Accelerate
import SwiftUI

struct SpectrumFrame: Sendable {
    var levels: [Float]
    var peaks: [Float]
    var sampleRate: Double
    var peakReferences: [Float] = []
    var motionTime: Double = 0
    var revision = 0
    var epoch = 0
    var isReset = false
    static let empty = SpectrumFrame(levels: Array(repeating: 0, count: 64), peaks: Array(repeating: 0, count: 64), sampleRate: 44100)
}
/// Resample the full logarithmic FFT range with fractional band overlap.
/// Average in linear power, not decibels, so no source band is dropped.
enum ClassicSpectrumBands {
    static func peakOpacity(peak: Float, reference: Float) -> Double {
        guard peak.isFinite, reference.isFinite, reference > 0 else { return 0 }
        let remaining = Double(min(1, max(0, peak / reference)))
        return remaining * remaining
    }
    static func resample(_ values: [Float], count: Int = 48) -> [Float] {
        guard !values.isEmpty, count > 0 else { return [] }
        let count = min(count, values.count)
        let ratio = Double(values.count) / Double(count)
        return (0..<count).map { band in
            let lower = Double(band) * ratio, upper = Double(band + 1) * ratio
            var power = 0.0
            for index in Int(floor(lower))..<min(values.count, Int(ceil(upper))) {
                let overlap = max(0, min(upper, Double(index + 1)) - max(lower, Double(index)))
                let level = values[index].isFinite ? Double(min(1, max(0, values[index]))) : 0
                if level > 0 { power += pow(10, (level * 80 - 80) / 10) * overlap }
            }
            guard power > 0 else { return 0 }
            return Float(max(0, min(1, (10 * log10(power / ratio) + 80) / 80)))
        }
    }
}

@MainActor
final class SpectrumDisplay: ObservableObject {
    @Published var frame = SpectrumFrame.empty
}

/// All FFT state belongs to the analysis queue, never the audio render thread.
final class SpectrumProcessor {
    static let size = 4096
    static let bands = 64
    private var motionTime: Double = 0
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: size)
    private var windowed = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size / 2)
    private var imaginary = [Float](repeating: 0, count: size / 2)
    private var power = [Float](repeating: 0, count: size / 2)
    private var levels = [Float](repeating: 0, count: bands)
    private var peaks = [Float](repeating: 0, count: bands)
    private var peakReferences = [Float](repeating: 0, count: bands)
    init() {
        setup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    }
    deinit { vDSP_destroy_fftsetup(setup) }
    func reset() { levels = Array(repeating: 0, count: Self.bands); peaks = levels; peakReferences = levels; motionTime = 0 }
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
            let fallingPeak = max(0, peaks[band] - 0.012)
            if levels[band] >= fallingPeak {
                peaks[band] = levels[band]
                peakReferences[band] = levels[band]
            } else {
                peaks[band] = fallingPeak
            }
        }
        motionTime += 1.0 / 30.0
        return SpectrumFrame(levels: levels, peaks: peaks, sampleRate: sampleRate, peakReferences: peakReferences, motionTime: motionTime)
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
    private var epoch = 0
    private var callback: (@Sendable (SpectrumFrame) -> Void)?
    private let queue = DispatchQueue(label: "LittleEars.Spectrum", qos: .utility)
    private let timer: DispatchSourceTimer
    private let processor = SpectrumProcessor()
    private var processorEpoch = -1
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
        lock.lock(); written = 0; writeIndex = 0; revision += 1; epoch += 1
        var frame = SpectrumFrame.empty; frame.revision = revision; frame.epoch = epoch; frame.isReset = true
        let callback = callback; lock.unlock()
        callback?(frame)
    }
    func isCurrent(_ frame: SpectrumFrame) -> Bool {
        lock.lock(); defer { lock.unlock() }; return frame.epoch == epoch && (frame.isReset || frame.revision == revision)
    }
    func capture(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, !buffer.format.isInterleaved, buffer.frameLength > 0, lock.try() else { return }
        defer { lock.unlock() }
        guard active else { return }
        let rate = buffer.format.sampleRate
        if sampleRate != rate { written = 0; writeIndex = 0; revision += 1; epoch += 1; sampleRate = rate }
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
        lock.lock(); let allowed = !active && revision == token; let capturedEpoch = epoch; lock.unlock()
        guard allowed else { return }
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.sampleRate > 0, !file.processingFormat.isInterleaved,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(SpectrumProcessor.size)) else { return }
            let frame = AVAudioFramePosition(max(0, position) * file.processingFormat.sampleRate)
            file.framePosition = min(max(0, file.length - Int64(SpectrumProcessor.size)), frame)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(SpectrumProcessor.size))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { return }
            samples.withUnsafeMutableBufferPointer { pointer in
                vDSP_vclr(pointer.baseAddress!, 1, vDSP_Length(SpectrumProcessor.size))
                let count = Int(buffer.frameLength)
                if buffer.format.channelCount == 1 { pointer.baseAddress!.update(from: channels[0], count: count) }
                else { for index in 0..<count { pointer[index] = (channels[0][index] + channels[1][index]) * 0.5 } }
            }
            processor.reset(); processorEpoch = capturedEpoch
            var result = SpectrumFrame.empty
            // Settle this exact PCM window rather than reading a second ahead of the playhead.
            for _ in 0..<12 { result = processor.process(samples, sampleRate: file.processingFormat.sampleRate) }
            result.revision = token; result.epoch = capturedEpoch
            lock.lock(); let valid = !active && revision == token; let callback = callback; lock.unlock()
            if valid { callback?(result) }
        } catch { /* Unavailable files are handled by playback; viewing a page must not start an alert loop. */ }
    }
    private func analyze() {
        lock.lock()
        guard active, written >= SpectrumProcessor.size else { lock.unlock(); return }
        let token = revision
        let capturedEpoch = epoch
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
        if processorEpoch != capturedEpoch { processor.reset(); processorEpoch = capturedEpoch }
        var frame = processor.process(samples, sampleRate: rate)
        frame.revision = token; frame.epoch = capturedEpoch
        lock.lock(); let valid = active && revision == token; lock.unlock()
        if valid { callback?(frame) }
    }
}

// Shared preferences keep the playback panel and its configuration sheet in sync.
struct SpectrumPreferences: DynamicProperty {
    @AppStorage("spectrumStyle") var style = "bars"
    @AppStorage("spectrumGain") var gain = 1.0
    @AppStorage("spectrumGlow") var glow = true
    @AppStorage("spectrumReflection") var reflection = true
    @AppStorage("spectrumPeaks") var peaks = true
    @AppStorage("spectrumLayers") var layers = 20
    var amplitude: Double { gain.isFinite ? min(1.5, max(0.6, gain)) : 1 }
    var layerCount: Int { min(28, max(12, layers)) }
    func reset() {
        style = "bars"; gain = 1; glow = true; reflection = true; peaks = true; layers = 20
    }
}

/// FFT-driven ribbon geometry. Silence collapses every strand onto the center;
/// time advances only when another PCM window is analyzed, so pause is static.
struct FluidSpectrumGeometry {
    private let levels: [Double]
    private let mean: Double
    private let energy: Double
    init(levels: [Float]) {
        self.levels = levels.map { $0.isFinite ? Double(min(1, max(0, $0))) : 0 }
        mean = self.levels.reduce(0, +) / Double(max(1, levels.count))
        energy = pow(sqrt(self.levels.reduce(0) { $0 + $1 * $1 } / Double(max(1, levels.count))), 0.65)
    }
    // Reflect frequency coordinates at the ends, avoiding a wrap seam between
    // bass and treble. Cubic interpolation also smooths narrow FFT peaks.
    private func sample(_ position: Double) -> Double {
        guard levels.count > 1 else { return levels.first ?? 0 }
        let end = Double(levels.count - 1)
        var coordinate = position.truncatingRemainder(dividingBy: end * 2)
        if coordinate < 0 { coordinate += end * 2 }
        if coordinate > end { coordinate = end * 2 - coordinate }
        return FluidSpectrumContour.interpolate(levels, at: coordinate)
    }
    func contour(strand: Double, time: Double) -> FluidSpectrumContour {
        // Each strand reads different, overlapping frequency neighborhoods.
        // Audio-frame time advects that field; there is no clock-driven sine
        // carrier or random motion shared by the entire ribbon.
        let scale = Double(max(1, levels.count - 1)) / 63
        func field(_ offset: Double) -> [Double] {
            (-2...14).map { node in
                let x = Double(node)
                let a = sample((x * 4.35 + time * 1.7 + offset * 5.2) * scale)
                let b = sample((x * 3.13 - time * 1.1 + 21.7 - offset * 8.4) * scale)
                let c = sample((x * 5.21 + time * 0.7 + 45.1 + offset * offset * 9.3) * scale)
                return (a - b) * (1.1 + offset * 0.22) + (c - mean) * (0.7 - offset * 0.2)
            }
        }
        let common = field(0), detail = field(strand)
        let raw = zip(common, detail).map { $0 * 0.72 + $1 * 0.28 }
        var smooth = raw.indices.map { i in
            raw[max(0, i - 1)] * 0.22 + raw[i] * 0.56 + raw[min(raw.count - 1, i + 1)] * 0.22
        }
        let center = smooth[2...14].reduce(0, +) / 13
        // Remove spectral tilt (bass is usually louder) without pinching the
        // endpoints to zero. Keep strands coherent while retaining local detail.
        let slope = (2...14).reduce(0.0) { $0 + Double($1 - 8) * (smooth[$1] - center) } / 182
        for i in smooth.indices {
            smooth[i] = (smooth[i] - center - slope * Double(i - 8)) * 2.8 + strand * energy * 0.13
        }
        return FluidSpectrumContour(values: smooth)
    }
    func displacement(x: Double, strand: Double, time: Double) -> Double {
        contour(strand: strand, time: time).displacement(x: x)
    }
}

struct FluidSpectrumContour {
    let values: [Double]
    static func interpolate(_ values: [Double], at coordinate: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let position = min(Double(values.count - 1), max(0, coordinate))
        let index = Int(position), t = position - Double(index)
        let a = values[max(0, index - 1)], b = values[index]
        let c = values[min(values.count - 1, index + 1)], d = values[min(values.count - 1, index + 2)]
        return 0.5 * ((2 * b) + (-a + c) * t + (2*a - 5*b + 4*c - d) * t*t + (-a + 3*b - 3*c + d) * t*t*t)
    }
    func displacement(x: Double) -> Double { Self.interpolate(values, at: x * 12 + 2) }
    func verticalFraction(x: Double, amplitude: Double) -> Double {
        // Soft compression reserves the middle 64% even at maximum gain.
        0.5 - tanh(displacement(x: x) * amplitude * 1.6) * 0.32
    }
}

struct FluidSpectrumPlot: View {
    @ObservedObject var display: SpectrumDisplay
    let palette: Palette
    let amplitude: Double
    let layers: Int
    let glow: Bool
    var body: some View {
        Canvas { context, size in
            let frame = display.frame
            let geometry = FluidSpectrumGeometry(levels: frame.levels)
            let steps = max(96, min(240, Int(size.width / 4)))
            for layer in 0..<layers {
                let strand = Double(layer) / Double(max(1, layers - 1)) * 2 - 1
                let contour = geometry.contour(strand: strand, time: frame.motionTime)
                var path = Path()
                // Continue beyond the viewport; clipping does not cap or fold the edges.
                for step in -12...(steps + 12) {
                    let x = Double(step) / Double(steps)
                    let point = CGPoint(x: x * size.width, y: contour.verticalFraction(x: x, amplitude: amplitude) * size.height)
                    if step == -12 { path.move(to: point) } else { path.addLine(to: point) }
                }
                let central = 1 - abs(strand)
                let color = palette.accent.opacity((palette.dark ? 0.30 : 0.16) + central * (palette.dark ? 0.50 : 0.40))
                if glow && layer % 4 == 0 {
                    var halo = context
                    halo.addFilter(.blur(radius: 4))
                    halo.stroke(path, with: .color(palette.accent.opacity(palette.dark ? 0.28 : 0.08)), lineWidth: 3)
                }
                context.stroke(path, with: .linearGradient(Gradient(colors: [color.opacity(0.45), color, color.opacity(0.65), color, color.opacity(0.45)]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)), lineWidth: 0.8 + central * 0.35)
            }
        }.clipped().accessibilityLabel("流体声波").accessibilityValue("由真实音频频谱驱动")
    }
}

struct SpectrumSettingsPanel: View {
    @Environment(\.dismiss) private var dismiss
    var preferences = SpectrumPreferences()
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("频谱配置").font(.title3.weight(.semibold)); Spacer() }.padding(20)
            Divider()
            Form {
                Picker("显示形式", selection: preferences.$style) {
                    Text("经典柱状图").tag("bars")
                    Text("流体声波").tag("fluid")
                }.pickerStyle(.segmented)
                LabeledContent("动态幅度") {
                    Slider(value: preferences.$gain, in: 0.6...1.5, step: 0.1).accessibilityLabel("动态幅度")
                    Text(preferences.amplitude, format: .number.precision(.fractionLength(1))).monospacedDigit().frame(width: 28)
                }
                Toggle("柔光", isOn: preferences.$glow)
                if preferences.style == "fluid" {
                    Picker("声波层数", selection: preferences.$layers) {
                        Text("简洁 · 12").tag(12); Text("标准 · 20").tag(20); Text("丰富 · 28").tag(28)
                    }
                } else {
                    Toggle("峰值标记", isOn: preferences.$peaks)
                    Toggle("底部倒影", isOn: preferences.$reflection)
                }
                Text("两种形式均响应真实音频数据。动态幅度只影响画面，不改变音量。设置即时生效并自动保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button("恢复默认") { preferences.reset() }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(16)
        }.frame(width: 480, height: 440)
    }
}
