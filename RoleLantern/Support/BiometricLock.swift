import Foundation
import SwiftUI
import LocalAuthentication

/// App lock using Face ID / Touch ID (with device passcode fallback).
/// The session token stays in the Keychain; this gates the UI.
@MainActor
final class BiometricLockManager: ObservableObject {
    @Published var isLocked = false
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.key) }
    }

    private static let key = "biometricLockEnabled"

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.key)
        // Cold start: begin locked if the user enabled the lock.
        isLocked = isEnabled
    }

    var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// "Face ID" / "Touch ID" / "Passcode", for labels.
    var biometryLabel: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Passcode"
        }
    }

    func lockIfEnabled() {
        if isEnabled { isLocked = true }
    }

    func unlock() async {
        guard isLocked else { return }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock RoleLantern"
            )
            if ok { isLocked = false }
        } catch {
            // User cancelled or auth failed — stay locked.
        }
    }

    /// Verifies identity once before turning the lock on.
    func enable() async {
        let context = LAContext()
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Confirm it's you to enable \(biometryLabel) unlock"
            )
            if ok { isEnabled = true }
        } catch {
            // Not enabled.
        }
    }

    func disable() {
        isEnabled = false
        isLocked = false
    }
}

/// Full-screen cover shown while the app is locked.
struct LockScreenView: View {
    @EnvironmentObject var lock: BiometricLockManager

    var body: some View {
        ZStack {
            Brand.cream.ignoresSafeArea()
            VStack(spacing: 24) {
                LanternMark(size: 100)
                Text("RoleLantern is locked")
                    .font(.title3.weight(.medium))
                    .foregroundColor(Brand.navy)
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Unlock with \(lock.biometryLabel)", systemImage: "faceid")
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 280)
            }
        }
        .task { await lock.unlock() }   // prompt immediately on appear
    }
}
