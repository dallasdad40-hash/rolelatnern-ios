import SwiftUI

/// RoleLantern design system — palette and type per the brand spec.
/// Calm, trustworthy, flat, generous whitespace. Sentence case everywhere.
enum Brand {
    static let navy = Color(hex: 0x0F1B2E)      // ink / outlines
    static let teal = Color(hex: 0x18A999)      // brand
    static let gold = Color(hex: 0xF2A81C)      // flame / accent
    static let goldLight = Color(hex: 0xF1C453)
    static let cream = Color(hex: 0xFFFDF4)     // lantern body
    static let surface = Color(hex: 0xF5F7F7)   // light gray surface
    static let slate = Color(hex: 0x6B7280)     // secondary text
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var isDestructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isDestructive ? Color.red : Brand.teal)
            .foregroundColor(.white)
            .cornerRadius(12)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Brand.surface)
            .foregroundColor(Brand.navy)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.navy.opacity(0.15)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
