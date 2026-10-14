import SwiftUI

struct Palette {
    let dark: Bool
    let accentName: String
    var background: Color { Color(hex: dark ? 0x15171B : 0xF5F6F8) }
    var surface: Color { Color(hex: dark ? 0x22262C : 0xFFFFFF) }
    var elevated: Color { Color(hex: dark ? 0x2B3037 : 0xEDEFF3) }
    var text: Color { Color(hex: dark ? 0xF5F7FA : 0x242A32) }
    var secondary: Color { Color(hex: dark ? 0x9FA8B3 : 0x657182) }
    var border: Color { text.opacity(0.08) }
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(8).contentShape(RoundedRectangle(cornerRadius: 8))
            .background(configuration.isPressed ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}
