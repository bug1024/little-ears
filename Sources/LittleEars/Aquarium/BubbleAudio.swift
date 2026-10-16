import AVFoundation
import Combine

/// One loop player per scene controller, independent of SwiftUI/Metal view recreation.
final class BubbleAudioController: ObservableObject {
    @Published var enabled = true { didSet { reconcile() } }
    @Published var volume: Double = 0.16 {
        didSet { player?.setVolume(Float(min(1, max(0, volume))), fadeDuration: 0.1) }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var error: String?
    private var player: AVAudioPlayer?
    private var externalActivity = false

    init(url: URL) {
        do {
            let audio = try AVAudioPlayer(contentsOf: url)
            audio.numberOfLoops = -1
            audio.volume = Float(volume)
            guard audio.prepareToPlay() else { throw NSError(domain: "AquariumAudio", code: 1) }
            player = audio
        } catch {
            self.error = "无法加载气泡声音：\(error.localizedDescription)"
        }
    }

    func setExternalActivity(_ active: Bool) { externalActivity = active; reconcile() }

    private func reconcile() {
        guard let player else { return }
        let shouldPlay = enabled && externalActivity
        if shouldPlay && !player.isPlaying {
            player.volume = 0
            if player.play() {
                player.setVolume(Float(min(1, max(0, volume))), fadeDuration: 0.35)
            } else {
                error = "气泡声音播放失败"
            }
        } else if !shouldPlay && player.isPlaying {
            // Pause preserves the loop position when the window becomes visible.
            player.pause()
        }
        isPlaying = player.isPlaying
    }

    func stop() { externalActivity = false; player?.stop(); isPlaying = false }
    deinit {
        player?.stop()
    }
}
