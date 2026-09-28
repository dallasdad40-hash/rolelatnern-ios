import SwiftUI

/// Person icon for the top-right of each main screen. Opens the account menu.
struct ProfileMenuButton: View {
    @State private var showMenu = false

    var body: some View {
        Button {
            showMenu = true
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.title3)
                .foregroundColor(Brand.navy)
        }
        .accessibilityLabel("Account menu")
        .sheet(isPresented: $showMenu) { ProfileMenuView() }
    }
}

/// Indeed-style menu: Options, Resources, then Sign out.
struct ProfileMenuView: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showReview = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        LanternMark(size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Signed in as").font(.caption).foregroundColor(Brand.slate)
                            Text(auth.userEmail ?? "Your account")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Brand.navy)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Options") {
                    NavigationLink {
                        AccountView(embedded: true)
                    } label: {
                        MenuRow(title: "Settings", icon: "gearshape")
                    }
                    NavigationLink {
                        PrivacyCenterView()
                    } label: {
                        MenuRow(title: "Privacy Center", icon: "hand.raised")
                    }
                }

                Section("Resources") {
                    NavigationLink {
                        HelpCenterView()
                    } label: {
                        MenuRow(title: "Help Center", icon: "questionmark.circle")
                    }
                    Button {
                        showReview = true
                    } label: {
                        MenuRow(title: "Lantern AI CV Review", icon: "sparkles")
                    }
                    Button {
                        openURL(AppConfig.webBaseURL)
                    } label: {
                        MenuRow(title: "RoleLantern on the web", icon: "safari", external: true)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        dismiss()
                        Task { await auth.signOut() }
                    } label: {
                        Text("Sign out").frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .sheet(isPresented: $showReview) {
                NavigationStack { CVReviewView() }
            }
        }
    }
}

private struct MenuRow: View {
    let title: String
    let icon: String
    var external = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(Brand.teal)
                .frame(width: 24)
            Text(title)
                .font(.body.weight(.medium))
                .foregroundColor(Brand.navy)
            Spacer()
            if external {
                Image(systemName: "arrow.up.right.square").foregroundColor(Brand.slate)
            }
        }
        .padding(.vertical, 6)
    }
}
