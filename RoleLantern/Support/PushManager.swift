import SwiftUI
import UIKit
import UserNotifications
import Supabase

/// Where a tapped notification or deep link should take the user.
enum AppDestination: Equatable {
    case invites, applications, messages, privacy
}

/// Tab selection + pending destination, shared by push taps and deep links.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    enum Tab: Hashable { case jobs, myJobs, messages, dashboard }

    @Published var tab: Tab = .jobs
    @Published var pending: AppDestination?

    func open(_ destination: AppDestination) {
        switch destination {
        case .messages: tab = .messages
        case .invites, .applications, .privacy: tab = .dashboard
        }
        pending = destination
    }

    /// rolelantern://invites, rolelantern://applications, rolelantern://messages, rolelantern://privacy
    func handle(url: URL) -> Bool {
        guard url.scheme == "rolelantern" else { return false }
        switch url.host {
        case "invites": open(.invites)
        case "applications": open(.applications)
        case "messages": open(.messages)
        case "privacy": open(.privacy)
        default: return false
        }
        return true
    }
}

/// Registers for push, stores the device token for the signed-in user, and
/// routes notification taps. Notifications never carry personal details; they
/// just say something happened and open the right screen.
final class PushManager: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let tokenKey = "apnsDeviceToken"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Ask once, after sign-in. iOS only shows the system prompt the first time.
    @MainActor
    static func requestPermissionAndRegister() async {
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings()
        if current.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        Task { await Self.uploadToken(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator or missing entitlement. The app works fine without push.
    }

    static func uploadToken(_ token: String) async {
        guard Supa.client.auth.currentUser != nil else { return }
        struct Params: Encodable {
            let p_token: String
            let p_environment: String
            let p_platform = "ios"
        }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        // Server-side: reassigns the token to whoever is signed in now.
        _ = try? await Supa.client.rpc("register_push_token",
                                       params: Params(p_token: token, p_environment: environment))
            .execute()
    }

    /// Call on sign-out so this device stops receiving the previous user's alerts.
    static func removeToken() async {
        guard let token = UserDefaults.standard.string(forKey: tokenKey) else { return }
        _ = try? await Supa.client.from("device_push_tokens").delete().eq("token", value: token).execute()
    }

    // Show banners while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let link = response.notification.request.content.userInfo["link"] as? String,
              let url = URL(string: link) else { return }
        await MainActor.run { _ = AppRouter.shared.handle(url: url) }
    }
}
