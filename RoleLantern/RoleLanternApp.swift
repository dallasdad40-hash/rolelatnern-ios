import SwiftUI

@main
struct RoleLanternApp: App {
    @UIApplicationDelegateAdaptor(PushManager.self) private var pushDelegate
    @StateObject private var auth = AuthViewModel()
    @StateObject private var router = AppRouter.shared
    @StateObject private var lock = BiometricLockManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(lock)
                .environmentObject(router)
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
                .onOpenURL { url in
                    if !router.handle(url: url) { auth.handleDeepLink(url) }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .background {
                        lock.lockIfEnabled()
                    } else if phase == .active, lock.isLocked {
                        // Prompt only once the app is fully active — reliable first try.
                        Task { await lock.unlock() }
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var auth: AuthViewModel

    var body: some View {
        content
            .sheet(isPresented: .init(
                get: { auth.resetStage == .newPassword },
                set: { if !$0 { auth.resetStage = nil } }
            )) {
                SetNewPasswordSheet()
            }
    }

    @ViewBuilder
    private var content: some View {
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
    @EnvironmentObject var router: AppRouter
    @StateObject private var messagesVM = MessagesViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $router.tab) {
            JobBoardView()
                .tabItem { Label("Jobs", systemImage: "briefcase") }
                .tag(AppRouter.Tab.jobs)
            MyJobsView()
                .tabItem { Label("My Jobs", systemImage: "bookmark") }
                .tag(AppRouter.Tab.myJobs)
            MessagesView(vm: messagesVM)
                .tabItem { Label("Messages", systemImage: "envelope") }
                .badge(messagesVM.totalUnread)
                .tag(AppRouter.Tab.messages)
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "rectangle.grid.2x2") }
                .tag(AppRouter.Tab.dashboard)
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(AppRouter.Tab.profile)
        }
        .task {
            await messagesVM.refresh(candidateId: auth.profile?.id)
            await PushManager.requestPermissionAndRegister()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await messagesVM.refresh(candidateId: auth.profile?.id) }
            }
        }
    }
}
