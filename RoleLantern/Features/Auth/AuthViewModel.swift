import Foundation
import SwiftUI
import CryptoKit
import AuthenticationServices
import Supabase

@MainActor
final class AuthViewModel: ObservableObject {
    enum Phase {
        case loading
        case signedOut
        case mfaChallenge          // password accepted, TOTP code required (AAL2)
        case signedIn
    }

    @Published var phase: Phase = .loading
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published var role: String = "candidate"
    @Published var profile: CandidateProfile?

    private let client = Supa.client
    private let data = DataService()
    private var currentNonce: String?

    var userId: UUID? { client.auth.currentUser?.id }
    var userEmail: String? { client.auth.currentUser?.email }

    // MARK: Session lifecycle

    func start() async {
        for await state in client.auth.authStateChanges {
            switch state.event {
            case .initialSession, .signedIn, .tokenRefreshed, .mfaChallengeVerified, .userUpdated:
                if state.session != nil {
                    await resolveSignedInState()
                } else {
                    phase = .signedOut
                }
            case .signedOut, .userDeleted:
                profile = nil
                phase = .signedOut
            default:
                break
            }
        }
    }

    private func resolveSignedInState() async {
        // Enforce the AAL2 step-up when the user has TOTP enrolled.
        if let aal = try? await client.auth.mfa.getAuthenticatorAssuranceLevel(),
           aal.currentLevel == "aal1", aal.nextLevel == "aal2" {
            phase = .mfaChallenge
            return
        }
        role = client.auth.currentUser?.appMetadata["role"]?.stringValue ?? "candidate"
        if role == "candidate" {
            await loadOrCreateProfile()
        }
        phase = .signedIn
    }

    func loadOrCreateProfile() async {
        guard let userId else { return }
        do {
            if let existing = try await data.fetchMyProfile(userId: userId) {
                profile = existing
            } else {
                profile = try await data.createProfile(userId: userId)
            }
        } catch {
            errorMessage = "Could not load your profile. Pull to refresh or complete onboarding on the web."
        }
    }

    func handleDeepLink(_ url: URL) {
        Task {
            do {
                _ = try await client.auth.session(from: url)
            } catch {
                errorMessage = "Sign-in link could not be verified. Please try again."
            }
        }
    }

    // MARK: Email + password

    func signIn(email: String, password: String) async {
        do {
            _ = try await client.auth.signIn(email: email, password: password)
        } catch {
            errorMessage = friendly(error)
        }
    }

    func signUp(email: String, password: String) async {
        do {
            let result = try await client.auth.signUp(email: email, password: password, redirectTo: AppConfig.authRedirectURL)
            if result.session == nil {
                infoMessage = "Check your inbox to confirm your email, then sign in."
            }
        } catch {
            errorMessage = friendly(error)
        }
    }

    func sendMagicLink(email: String) async {
        do {
            try await client.auth.signInWithOTP(email: email, redirectTo: AppConfig.authRedirectURL)
            infoMessage = "Magic link sent — open it on this device to sign in."
        } catch {
            errorMessage = friendly(error)
        }
    }

    func sendPasswordReset(email: String) async {
        do {
            try await client.auth.resetPasswordForEmail(email, redirectTo: AppConfig.authRedirectURL)
            infoMessage = "Password reset email sent."
        } catch {
            errorMessage = friendly(error)
        }
    }

    // MARK: Google OAuth (ASWebAuthenticationSession under the hood)

    func signInWithGoogle() async {
        do {
            _ = try await client.auth.signInWithOAuth(provider: .google, redirectTo: AppConfig.authRedirectURL)
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
            errorMessage = friendly(error)
        }
    }

    // MARK: Sign in with Apple (native)

    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonce()
        currentNonce = nonce
        request.requestedScopes = [.email, .fullName]
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorMessage = friendly(error)
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                errorMessage = "Apple sign-in returned an unexpected response."
                return
            }
            do {
                _ = try await client.auth.signInWithIdToken(
                    credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
                )
            } catch {
                errorMessage = friendly(error)
            }
        }
    }

    private func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String((0..<length).map { _ in charset.randomElement()! })
    }

    // MARK: TOTP 2FA

    func verifyMFACode(_ code: String) async {
        do {
            let factors = try await client.auth.mfa.listFactors()
            guard let factor = factors.totp.first else {
                errorMessage = "No authenticator is enrolled on this account."
                return
            }
            _ = try await client.auth.mfa.challengeAndVerify(
                params: MFAChallengeAndVerifyParams(factorId: factor.id, code: code)
            )
            await resolveSignedInState()
        } catch {
            errorMessage = "That code didn't work. Check your authenticator app and try again."
        }
    }

    // MARK: Account

    func updatePassword(_ newPassword: String) async {
        do {
            _ = try await client.auth.update(user: UserAttributes(password: newPassword))
            infoMessage = "Password updated."
        } catch {
            errorMessage = friendly(error)
        }
    }

    func signOut(everywhere: Bool = false) async {
        try? await client.auth.signOut(scope: everywhere ? .global : .local)
    }

    /// Apple-required in-app deletion: scrub name + CV, then sign out everywhere.
    func deleteAccount() async {
        guard let profile else { return }
        do {
            try await data.deleteAccountData(profileId: profile.id, candidateId: profile.id)
            try? await client.auth.signOut(scope: .global)
        } catch {
            errorMessage = "Deletion failed. Please try again or contact support@rolelantern.com."
        }
    }

    private func friendly(_ error: Error) -> String {
        if let authError = error as? AuthError {
            return authError.localizedDescription
        }
        return error.localizedDescription
    }
}
