import SwiftUI
import SafariServices

/// Company monogram avatar, matching the website's job cards: a colored
/// circle with the company initial. Color is stable per company name.
struct CompanyAvatar: View {
    let name: String
    var size: CGFloat = 44

    private static let palette: [Color] = [
        Brand.teal, Brand.navy, Color(hex: 0xD85A30), Color(hex: 0x534AB7),
        Color(hex: 0x185FA5), Color(hex: 0x993556), Color(hex: 0x3B6D11), Color(hex: 0xBA7517),
    ]

    private var color: Color {
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Self.palette[sum % Self.palette.count]
    }

    private var initial: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.14))
            Text(initial)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundColor(color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct TagChip: View {
    let text: String
    var color: Color = Brand.teal

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12))
            .foregroundColor(color == Brand.teal ? Brand.teal : color)
            .cornerRadius(8)
    }
}

/// "Verified active" trust badge driven by job_freshness_status.
struct FreshnessBadge: View {
    let status: String

    var body: some View {
        switch status {
        case "verified_active", "active", "fresh":
            Label("Verified active", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.medium))
                .foregroundColor(Brand.teal)
        case "recently_checked":
            Label("Recently checked", systemImage: "checkmark.seal")
                .font(.caption.weight(.medium))
                .foregroundColor(Brand.teal)
        case "needs_recheck", "stale", "unverified":
            Label("Freshness unconfirmed", systemImage: "clock")
                .font(.caption)
                .foregroundColor(Brand.slate)
        default:
            EmptyView()
        }
    }
}

struct BoostedBadge: View {
    var body: some View {
        Label("Featured", systemImage: "flame.fill")
            .font(.caption.weight(.medium))
            .foregroundColor(Brand.gold)
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            LanternMark(size: 72)
                .opacity(0.85)
            Text(title)
                .font(.headline)
                .foregroundColor(Brand.navy)
            Text(message)
                .font(.subheadline)
                .foregroundColor(Brand.slate)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 32)
    }
}

/// SFSafariViewController wrapper for external apply links (honest links, in-context).
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
