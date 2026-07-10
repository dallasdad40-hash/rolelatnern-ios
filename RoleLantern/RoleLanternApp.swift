import SwiftUI

@main
struct RoleLanternApp: App {
    @StateObject private var auth = AuthViewModel()
    @StateObject private var lock = BiometricLockManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(lock)
                .tint(Brand.teal)
                // The brand palette is light-first; forcing light mode keeps
                // input text legible on devices set to dark mode.
                .preferredColorScheme(.light)
                .overlay {
                    // Note: overlay content sits outside RootView's environment,
                    // so the lock manager must be injected here explicitly.
                    if lock.isLocked { LockScreenView().environmentObject(lock) }
                }
                .task { await auth.start() }
                .onOpenURL { url in auth.handleDeepLink(url) }
                .onChange(of: scenePhase) { phase in
                    if phase == .background { lock.lockIfEnabled() }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var auth: AuthViewModel

    var body: some View {
        switch auth.phase {
        case .loading:
            VStack(spacing: 16) {
                LanternMark(size: 110)
                Wordmark(font: .title.weight(.medium))
                ProgressView()
            }
        case .signedOut:
            AuthGateView()
        case .mfaChallenge:
            MFAChallengeView()
        case .signedIn:
            if auth.role == "candidate" {
                MainTabView()
            } else {
                NonCandidateView()
            }
        }
    }
}

/// Employers and admins stay web-first for v1 — point them at the web app.
struct NonCandidateView: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 20) {
            LanternMark(size: 88)
            Text("The iOS app is for candidates")
                .font(.title3.weight(.medium))
                .foregroundColor(Brand.navy)
            Text("Employer and admin tools live on the web for now.")
                .font(.subheadline)
                .foregroundColor(Brand.slate)
                .multilineTextAlignment(.center)
            Button("Open RoleLantern on the web") {
                openURL(AppConfig.webBaseURL)
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("Sign out") { Task { await auth.signOut() } }
                .foregroundColor(Brand.slate)
        }
        .padding(32)
    }
}

struct MainTabView: View {
    @EnvironmentObject var auth: AuthViewModel
    @StateObject private var messagesVM = MessagesViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            JobBoardView()
                .tabItem { Label("Jobs", systemImage: "briefcase") }
            SavedJobsView()
                .tabItem { Label("Saved", systemImage: "bookmark") }
            MessagesView(vm: messagesVM)
                .tabItem { Label("Messages", systemImage: "envelope") }
                .badge(messagesVM.totalUnread)
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "rectangle.grid.2x2") }
            AccountView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .task { await messagesVM.refresh(candidateId: auth.profile?.id) }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await messagesVM.refresh(candidateId: auth.profile?.id) }
            }
        }
    }
}
