import SwiftUI

enum WBColor {
    static let bg = Color(hex: 0xF8F8F1)
    static let white = Color(hex: 0xFFFFFF)
    static let ink = Color(hex: 0x263D34)
    static let ink2 = Color(hex: 0x577067)
    static let green = Color(hex: 0x41785E)
    static let green2 = Color(hex: 0x21543D)
    static let sage = Color(hex: 0xDCECDF)
    static let border = Color(hex: 0xE6EBE3)
    static let coral = Color(hex: 0xF1A187)
    static let amber = Color(hex: 0xFFF1D9)
    static let muted = Color(hex: 0xF3F5EF)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    init(hexString: String) {
        var value: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&value)
        self.init(hex: UInt32(value))
    }
}

struct WBCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WBColor.white)
            .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .stroke(WBColor.border, lineWidth: 1)
            )
    }
}

extension View {
    func wbCard() -> some View {
        modifier(WBCard())
    }
}

struct WBPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .foregroundStyle(WBColor.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(WBColor.green2.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

struct WBSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .foregroundStyle(WBColor.green2)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(WBColor.sage.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

struct WBScreen<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .padding(.horizontal, 19)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WBColor.bg)
        .foregroundStyle(WBColor.ink)
    }
}
