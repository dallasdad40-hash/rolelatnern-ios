import SwiftUI

/// The lantern brand mark: the same artwork as the app icon, with iOS-style
/// rounded corners, so the splash, lock screen and empty states match the icon.
struct LanternMark: View {
    var size: CGFloat = 96

    var body: some View {
        Image("LanternLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Lowercase wordmark: "role" in navy + "lantern" in teal.
struct Wordmark: View {
    var font: Font = .largeTitle.weight(.medium)
    var body: some View {
        (Text("role").foregroundColor(Brand.navy) + Text("lantern").foregroundColor(Brand.teal))
            .font(font)
    }
}
