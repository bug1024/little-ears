import SwiftUI

struct Palette {
    let dark: Bool
    let accentName: String
    var background: Color { Color(hex: dark ? 0x1B1D21 : 0xF4F5F7) }
    var sidebar: Color { Color(hex: dark ? 0x202226 : 0xECEEF1) }
    var surface: Color { Color(hex: dark ? 0x23252A : 0xFFFFFF) }
    var elevated: Color { Color(hex: dark ? 0x2B2E34 : 0xE8EBEF) }
    var plot: Color { Color(hex: dark ? 0x17191D : 0xFFFFFF) }
    var text: Color { Color(hex: dark ? 0xE9ECF1 : 0x252B33) }
    var secondary: Color { Color(hex: dark ? 0x9A9FA8 : 0x737A85) }
    var tertiary: Color { secondary.opacity(0.68) }
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
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: 25, minHeight: 25).contentShape(RoundedRectangle(cornerRadius: 5))
            .background(configuration.isPressed ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .modifier(HoverHighlight())
    }
}
struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.background(hovering ? Color.primary.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 5)).onHover { hovering = $0 }
    }
}
struct PanelStyle: ViewModifier {
    let palette: Palette
    func body(content: Content) -> some View {
        content.background(palette.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.border, lineWidth: 1))
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
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 10) {
                Image(systemName: current ? "speaker.wave.2.fill" : draggable ? "line.3.horizontal" : "music.note")
                    .font(.system(size: 10)).foregroundStyle(current ? palette.accent : palette.tertiary).frame(width: 15)
                Text(String(format: "%02d", index + 1)).font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.tertiary).frame(width: 25, alignment: .trailing)
                Text(title).font(.system(size: 12, weight: current ? .medium : .regular)).lineLimit(1).frame(width: max(20, proxy.size.width - max(90, min(180, proxy.size.width * 0.23)) - 202), alignment: .leading)
                Text(origin).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1).frame(width: max(90, min(180, proxy.size.width * 0.23)), alignment: .leading)
                Text(timeLabel(duration)).font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.secondary).frame(width: 52, alignment: .trailing)
                Text(format).font(.system(size: 9, weight: .medium)).foregroundStyle(palette.tertiary).frame(width: 40, alignment: .trailing)
            }.padding(.horizontal, 10).frame(height: 32)
                .background(selected ? palette.accent.opacity(0.1) : index.isMultiple(of: 2) ? palette.surface.opacity(0.5) : .clear)
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
