import SwiftUI
import AppKit

struct Palette {
    let dark: Bool
    let accentName: String
    var background: Color { Color(hex: dark ? 0x191B1E : 0xEFF1F3) }
    var sidebar: Color { Color(hex: dark ? 0x222529 : 0xE5E8EB) }
    var surface: Color { Color(hex: dark ? 0x24272B : 0xFAFBFC) }
    var elevated: Color { Color(hex: dark ? 0x33373C : 0xDFE3E7) }
    var plot: Color { Color(hex: dark ? 0x101316 : 0xE5EBF0) }
    var text: Color { Color(hex: dark ? 0xE9ECF1 : 0x252B33) }
    var secondary: Color { Color(hex: dark ? 0xA6ABB3 : 0x68717D) }
    var tertiary: Color { secondary.opacity(0.82) }
    var border: Color { (dark ? Color.white : Color.black).opacity(dark ? 0.075 : 0.08) }
    var accent: Color {
        switch accentName {
        case "mint": Color(hex: dark ? 0x78D9BE : 0x16846A)
        case "lavender": Color(hex: dark ? 0xB5A4F4 : 0x8063C8)
        case "coral": Color(hex: dark ? 0xF3A48F : 0xB75F4C)
        default: Color(hex: dark ? 0x80C8F2 : 0x347DB2)
        }
    }
}
extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}
/// Shared material language: a quiet chassis, raised controls and inset displays.
struct MaterialSurface: ViewModifier {
    let palette: Palette
    var radius: CGFloat = 10
    var inset = false
    func body(content: Content) -> some View {
        let base = inset ? palette.plot : palette.surface
        content.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [base, inset ? base : palette.background], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Color.white.opacity(palette.dark ? (inset ? 0.055 : 0.12) : 0.85), palette.border], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
                .shadow(color: .black.opacity(palette.dark ? 0.18 : 0.06), radius: inset ? 2 : 5, x: 0, y: inset ? 1 : 3)
                .allowsHitTesting(false)
        }
    }
}
struct InstrumentButtonStyle: ButtonStyle {
    var prominent = false
    var circular = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        InstrumentButtonBody(configuration: configuration, prominent: prominent, circular: circular, compact: compact)
    }
}
private struct InstrumentButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let circular: Bool
    let compact: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var body: some View {
        let dark = scheme == .dark
        let top = prominent ? Color(hex: 0xFCFDFE) : Color(hex: dark ? 0x3B3F45 : 0xFFFFFF)
        let bottom = prominent ? Color(hex: 0xD5DBE2) : Color(hex: dark ? 0x272B30 : 0xE4E8ED)
        let radius: CGFloat = circular ? 100 : 7
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .medium))
            .padding(.horizontal, circular || compact ? 0 : 10)
            .frame(minWidth: compact ? 25 : 28, minHeight: compact ? 25 : 28)
            .foregroundStyle(prominent ? Color(hex: 0x242930) : Color(hex: dark ? 0xE9ECF1 : 0x303740))
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: configuration.isPressed ? [bottom, bottom] : [top, bottom], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(hovering && !configuration.isPressed ? 0.055 : 0)))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(LinearGradient(colors: [Color.white.opacity(dark ? 0.22 : 0.95), Color.black.opacity(dark ? 0.28 : 0.14)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .shadow(color: .black.opacity(configuration.isPressed ? 0 : dark ? 0.25 : 0.1), radius: 2, x: 0, y: 2)
                    .allowsHitTesting(false)
            }
            .opacity(enabled ? 1 : 0.42)
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .onHover { hovering = $0 }
    }
}
struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.background { RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.045) : .clear).allowsHitTesting(false) }.onHover { hovering = $0 }
    }
}
struct SelectionSurface: ViewModifier {
    let palette: Palette
    let selected: Bool
    var radius: CGFloat = 7
    func body(content: Content) -> some View {
        content.background {
            if selected {
                RoundedRectangle(cornerRadius: radius).fill(LinearGradient(colors: [palette.elevated, palette.surface], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(palette.border, lineWidth: 1))
                    .shadow(color: .black.opacity(palette.dark ? 0.15 : 0.05), radius: 2, y: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}
struct PanelStyle: ViewModifier {
    let palette: Palette
    func body(content: Content) -> some View { content.modifier(MaterialSurface(palette: palette)) }
}
struct FormatBadge: View {
    let title: String
    let palette: Palette
    var body: some View {
        Text(title).font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(palette.secondary).padding(.horizontal, 7).frame(height: 21)
            .modifier(MaterialSurface(palette: palette, radius: 5))
    }
}
struct PageHeader<Actions: View>: View {
    let title: String
    var detail: String = ""
    let palette: Palette
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1) }
            Spacer(minLength: 8)
            actions()
        }.padding(.horizontal, 20).frame(height: 48)
            .background(LinearGradient(colors: [palette.surface.opacity(0.6), palette.background.opacity(0.2)], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
    }
}
struct TrackTableRow: View {
    let palette: Palette
    let index: Int
    let title: String
    let origin: String
    let duration: Double
    let format: String
    var current = false
    var selected = false
    var draggable = false
    var dragItemID: String?
    @ViewBuilder private var leadingIcon: some View {
        if let dragItemID {
            Image(systemName: "line.3.horizontal")
                .frame(width: 15, height: 32).contentShape(Rectangle())
                .onDrag { NSItemProvider(object: dragItemID as NSString) }
                .help("拖动调整顺序").accessibilityLabel("排序手柄")
        } else {
            Image(systemName: current ? "speaker.wave.2.fill" : draggable ? "line.3.horizontal" : "music.note").frame(width: 15)
        }
    }
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 10) {
                leadingIcon.font(.system(size: 10)).foregroundStyle(current ? palette.accent : palette.tertiary)
                Text(String(format: "%02d", index + 1)).font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.tertiary).frame(width: 25, alignment: .trailing)
                Text(title).font(.system(size: 12, weight: current ? .medium : .regular)).lineLimit(1).frame(width: max(20, proxy.size.width - max(90, min(180, proxy.size.width * 0.23)) - 202), alignment: .leading)
                Text(origin).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1).frame(width: max(90, min(180, proxy.size.width * 0.23)), alignment: .leading)
                Text(timeLabel(duration)).font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.secondary).frame(width: 52, alignment: .trailing)
                Text(format).font(.system(size: 9, weight: .medium)).foregroundStyle(palette.tertiary).frame(width: 40, alignment: .trailing)
            }.padding(.horizontal, 10).frame(height: 32)
                .background(selected ? palette.accent.opacity(0.12) : index.isMultiple(of: 2) ? palette.surface.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .bottom) { Rectangle().fill(palette.border.opacity(0.45)).frame(height: 0.5).padding(.horizontal, 10).allowsHitTesting(false) }
        }.frame(height: 32).contentShape(Rectangle()).modifier(HoverHighlight())
    }
}
struct TableColumnHeader: View {
    let palette: Palette
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 10) {
                Color.clear.frame(width: 15)
                Text("#").frame(width: 25, alignment: .trailing)
                Text("名称").frame(width: max(20, proxy.size.width - max(90, min(180, proxy.size.width * 0.23)) - 202), alignment: .leading)
                Text("目录").frame(width: max(90, min(180, proxy.size.width * 0.23)), alignment: .leading)
                Text("时长").frame(width: 52, alignment: .trailing)
                Text("格式").frame(width: 40, alignment: .trailing)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(palette.secondary).padding(.horizontal, 10).frame(height: 26)
        }.frame(height: 26).overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
    }
}

/// Keep AppKit's slider tracking, keyboard and accessibility behavior; only replace its drawing.
struct MaterialSlider: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    @Binding var value: Double
    let range: ClosedRange<Double>
    let palette: Palette
    var onEditingChanged: (Bool) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> InstrumentSlider {
        let slider = InstrumentSlider()
        slider.cell = InstrumentSliderCell()
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.editing = { context.coordinator.parent.onEditingChanged($0) }
        return slider
    }
    func updateNSView(_ slider: InstrumentSlider, context: Context) {
        context.coordinator.parent = self
        slider.isEnabled = enabled
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        slider.doubleValue = min(range.upperBound, max(range.lowerBound, value))
        if let cell = slider.cell as? InstrumentSliderCell { cell.palette = palette }
        slider.needsDisplay = true
    }
    final class Coordinator: NSObject {
        var parent: MaterialSlider
        init(_ parent: MaterialSlider) { self.parent = parent }
        @objc func changed(_ sender: InstrumentSlider) {
            parent.value = sender.doubleValue
            if !sender.tracking { parent.onEditingChanged(false) }
        }
    }
}
final class InstrumentSlider: NSSlider {
    override var acceptsFirstResponder: Bool { isEnabled }
    var editing: ((Bool) -> Void)?
    var tracking = false
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        tracking = true; editing?(true)
        super.mouseDown(with: event)
        tracking = false; editing?(false)
    }
}
final class InstrumentSliderCell: NSSliderCell {
    var palette = Palette(dark: false, accentName: "blue")
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor(palette.dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let fraction = maxValue > minValue ? max(0, min(1, (doubleValue - minValue) / (maxValue - minValue))) : 0
        let filled = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        NSColor(palette.accent.opacity(isEnabled ? 0.8 : 0.3)).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }
    override func drawKnob(_ knobRect: NSRect) {
        let rect = NSRect(x: knobRect.midX - 6, y: knobRect.midY - 6, width: 12, height: 12)
        let path = NSBezierPath(ovalIn: rect)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.2); shadow.shadowBlurRadius = 2; shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.set()
        NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.5).setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: .white.withAlphaComponent(isEnabled ? 1 : 0.35), ending: NSColor(calibratedWhite: 0.83, alpha: isEnabled ? 1 : 0.35))?.draw(in: path, angle: 90)
        NSColor.black.withAlphaComponent(0.12).setStroke(); path.lineWidth = 0.5; path.stroke()
    }
}

/// Uses the native split view's saved divider position; never adds a hit-test overlay.
struct SplitViewAutosave: NSViewRepresentable {
    var enabled: Bool
    func makeNSView(context: Context) -> Marker { Marker(enabled: enabled) }
    func updateNSView(_ view: Marker, context: Context) { view.enabled = enabled; view.configure() }
    final class Marker: NSView {
        var enabled: Bool
        private weak var configuredSplit: NSSplitView?
        init(enabled: Bool) { self.enabled = enabled; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.configure() }
        }
        func configure() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let split = view as? NSSplitView {
                    guard configuredSplit !== split, split.bounds.width > 0 else { return }
                    configuredSplit = split
                    split.setPosition(196, ofDividerAt: 0)
                    if enabled && split.autosaveName == nil { split.autosaveName = "LittleEars.MainSidebar" }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

/// Window-scoped transport shortcuts; text editing and sliders keep their native keys.
struct PlaybackKeyboardShortcuts: NSViewRepresentable {
    enum Command: Equatable {
        case togglePlayback, previous, next, volumeUp, volumeDown
        var allowsRepeat: Bool { self == .volumeUp || self == .volumeDown }
    }
    var playingPage: Bool
    var action: (Command) -> Void
    func makeNSView(context: Context) -> MonitorView { MonitorView(playingPage: playingPage, action: action) }
    func updateNSView(_ view: MonitorView, context: Context) { view.playingPage = playingPage; view.action = action }
    static func command(for event: NSEvent, responder: NSResponder?, hasSheet: Bool, playingPage: Bool = false) -> Command? {
        guard !hasSheet, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        let command: Command
        switch event.keyCode {
        case 49: command = .togglePlayback
        case 123: command = .previous
        case 124: command = .next
        case 125: command = .volumeDown
        case 126: command = .volumeUp
        default: return nil
        }
        guard command == .togglePlayback || playingPage else { return nil }
        // A field editor keeps cursor keys; space on a focused button still activates it.
        var view = responder as? NSView
        while let current = view {
            if current is NSTextView || current is NSTextField || current is NSPopUpButton { return nil }
            if command == .togglePlayback && current is NSButton { return nil }
            if command != .togglePlayback && (current is NSSlider || current is NSTableView || current is NSOutlineView || current is NSCollectionView) { return nil }
            view = current.superview
        }
        return command
    }
    static func shouldHandle(_ event: NSEvent, responder: NSResponder?, hasSheet: Bool) -> Bool {
        command(for: event, responder: responder, hasSheet: hasSheet) != nil
    }
    final class MonitorView: NSView {
        var playingPage: Bool
        var action: (Command) -> Void
        private var monitor: Any?
        init(playingPage: Bool, action: @escaping (Command) -> Void) { self.playingPage = playingPage; self.action = action; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { removeMonitor(); return }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow, event.window === window,
                      let command = PlaybackKeyboardShortcuts.command(for: event, responder: window.firstResponder, hasSheet: window.attachedSheet != nil, playingPage: self.playingPage) else { return event }
                if !event.isARepeat || command.allowsRepeat { self.action(command) }
                return nil
            }
        }
        private func removeMonitor() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
