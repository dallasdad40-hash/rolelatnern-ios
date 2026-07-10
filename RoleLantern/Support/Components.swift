import SwiftUI
import SafariServices

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
        case "stale", "unverified":
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
