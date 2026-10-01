import Foundation
import Supabase

// Client for the website's mobile API (https://rolelantern.com/api/mobile/*).
// Every route runs the website's own server actions, so ownership, firewall,
// consent, visibility and rate-limit rules are exactly the same as on the web.
// Auth: the signed-in user's Supabase access token as a Bearer header. No secrets.

extension Notification.Name {
    /// Posted when the API says the account needs its two-step code (token is not aal2).
    static let mobileAPIMFARequired = Notification.Name("mobileAPIMFARequired")
    /// Posted when the session can't be refreshed and the user must sign in again.
    static let mobileAPIAuthRequired = Notification.Name("mobileAPIAuthRequired")
}

struct MobileAPIError: LocalizedError {
    let status: Int
    let code: String?
    let message: String

    var errorDescription: String? {
        switch code {
        case "auth_required": return "Your session ended. Please sign in again."
        case "mfa_required": return "Enter your authenticator code to continue."
        case "rate_limited": return message.isEmpty ? "Too many requests. Please wait a moment and try again." : message
        case "wrong_role", "no_role": return "This account can't use the RoleLantern candidate app."
        default: return message.isEmpty ? "Something went wrong. Please try again." : message
        }
    }
}

struct MobileAPI {
    static let base = AppConfig.webBaseURL.appendingPathComponent("api/mobile")

    private struct Envelope<T: Decodable>: Decodable {
        let ok: Bool
        let data: T?
        let error: String?
        let code: String?
    }
    private struct ErrorEnvelope: Decodable {
        let error: String?
        let code: String?
    }
    struct Empty: Decodable {}

    /// Calls `path` (relative to /api/mobile/) and returns the decoded `data`.
    func request<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Encodable? = nil,
        as type: T.Type = T.self
    ) async throws -> T {
        do {
            return try await send(method, path, query: query, body: body, forceRefresh: false)
        } catch let e as MobileAPIError where e.code == "auth_required" {
            // Access token may have just expired: refresh once and retry.
            do {
                return try await send(method, path, query: query, body: body, forceRefresh: true)
            } catch let again as MobileAPIError where again.code == "auth_required" {
                NotificationCenter.default.post(name: .mobileAPIAuthRequired, object: nil)
                throw again
            }
        }
    }

    private func send<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: Encodable?,
        forceRefresh: Bool
    ) async throws -> T {
        let session = forceRefresh
            ? try await Supa.client.auth.refreshSession()
            : try await Supa.client.auth.session

        var comps = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if (200..<300).contains(status) {
            let env = try JSONDecoder().decode(Envelope<T>.self, from: data)
            if env.ok, let payload = env.data { return payload }
            throw MobileAPIError(status: status, code: env.code, message: env.error ?? "")
        }

        let err = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        let apiError = MobileAPIError(status: status, code: err?.code, message: err?.error ?? "")
        if apiError.code == "mfa_required" {
            NotificationCenter.default.post(name: .mobileAPIMFARequired, object: nil)
        }
        throw apiError
    }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

// MARK: - Privacy (profile visibility, matches the website)

struct MobilePrivacy: Decodable, Equatable {
    var profileVisibility: String
    var jobAlertsEnabled: Bool?
    var agencyOutreachOptIn: Bool?
    var protectedEmployers: [ProtectedEmployer]?

    struct ProtectedEmployer: Decodable, Equatable, Identifiable {
        let id: UUID
        let name: String?
        let domain: String?
        let relationshipType: String?
        let status: String?
    }
}

extension MobileAPI {
    func privacy() async throws -> MobilePrivacy {
        try await request("GET", "privacy")
    }

    struct PrivacyPatch: Encodable {
        var profileVisibility: String?
        var jobAlertsEnabled: Bool?
        var agencyOutreachOptIn: Bool?
    }

    @discardableResult
    func updatePrivacy(_ patch: PrivacyPatch) async throws -> MobilePrivacy {
        try await request("PATCH", "privacy", body: patch)
    }
}
