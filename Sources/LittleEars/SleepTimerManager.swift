import Foundation
import SwiftUI

@MainActor
final class SleepTimerManager: ObservableObject {
    enum Mode: Equatable {
        case off, minutes(Int), trackEnd
        var title: String {
            switch self { case .off: "关闭定时"; case .minutes(let value): "\(value) 分钟"; case .trackEnd: "当前曲目结束" }
        }
    }
    @Published private(set) var mode: Mode = .off
    @Published private(set) var remainingSeconds = 0
    private(set) var deadline: Date?
    var onExpired: (() -> Void)?
    private let now: () -> Date
    private let automatic: Bool
    private var timer: Timer?
    init(now: @escaping () -> Date = Date.init, automatic: Bool = true) { self.now = now; self.automatic = automatic }
    func start(_ mode: Mode) {
        cancel()
        guard mode != .off else { return }
        if case .minutes(let minutes) = mode {
            guard minutes > 0 else { return }
            deadline = now().addingTimeInterval(Double(minutes) * 60)
            remainingSeconds = minutes * 60
            if automatic {
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkDeadline() } }
                self.timer = timer; RunLoop.main.add(timer, forMode: .common)
            }
        }
        self.mode = mode
    }
    /// Wall time, including system sleep. Clear before notifying so delivery is one-shot.
    @discardableResult func checkDeadline() -> Bool {
        guard let deadline else { return false }
        let seconds = max(0, Int(ceil(deadline.timeIntervalSince(now()))))
        if seconds == 0 { cancel(); onExpired?(); return true }
        if remainingSeconds != seconds { remainingSeconds = seconds }
        return false
    }
    func consumeTrackEnd() -> Bool { guard mode == .trackEnd else { return false }; cancel(); return true }
    func cancelTrackEnd() { if mode == .trackEnd { cancel() } }
    func cancel() { timer?.invalidate(); timer = nil; deadline = nil; remainingSeconds = 0; mode = .off }
    var remainingLabel: String {
        let seconds = remainingSeconds
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    deinit { timer?.invalidate() }
}

struct SleepTimerButton: View {
    @ObservedObject var timer: SleepTimerManager
    let palette: Palette
    let hasTrack: Bool
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: timer.mode == .off ? "moon.zzz" : "moon.zzz.fill")
                .font(.system(size: 12)).foregroundStyle(timer.mode == .off ? palette.secondary : palette.accent)
                .frame(width: 25, height: 25).contentShape(Rectangle())
        }.buttonStyle(.plain).modifier(HoverHighlight()).help("睡眠定时")
            .accessibilityLabel("睡眠定时").accessibilityValue(timer.mode == .off ? "未启用" : timer.mode.title)
            .popover(isPresented: $showing) {
                SleepTimerPopover(timer: timer, palette: palette, hasTrack: hasTrack)
            }
    }
}
struct SleepTimerPopover: View {
    @ObservedObject var timer: SleepTimerManager
    let palette: Palette
    let hasTrack: Bool
    @Environment(\.dismiss) private var dismiss
    private let modes: [SleepTimerManager.Mode] = [.minutes(15), .minutes(30), .minutes(45), .minutes(60), .trackEnd, .off]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("睡眠定时").font(.system(size: 12, weight: .semibold))
                Spacer()
                if case .minutes = timer.mode { Text(timer.remainingLabel).monospacedDigit().font(.system(size: 12, weight: .medium)).foregroundStyle(palette.accent) }
            }.padding(.horizontal, 7).padding(.bottom, 5)
            Text(timer.mode == .trackEnd ? "当前曲目自然结束后停止" : timer.mode == .off ? "定时结束后暂停音频" : "暂停音频时，倒计时仍继续")
                .font(.system(size: 10)).foregroundStyle(palette.secondary).padding(.horizontal, 7).padding(.bottom, 6)
            Divider()
            ForEach(Array(modes.enumerated()), id: \.offset) { _, mode in
                Button {
                    timer.start(mode); dismiss()
                } label: {
                    HStack {
                        Image(systemName: "checkmark").font(.system(size: 10)).opacity(timer.mode == mode ? 1 : 0).frame(width: 14)
                        Text(mode.title).font(.system(size: 11))
                        Spacer()
                    }.padding(.horizontal, 7).frame(height: 27).contentShape(Rectangle())
                }.buttonStyle(.plain).modifier(HoverHighlight()).disabled(mode == .trackEnd && !hasTrack)
            }
        }.padding(12).frame(width: 232).foregroundStyle(palette.text).background(palette.background)
            .onAppear { timer.checkDeadline() }
    }
}
