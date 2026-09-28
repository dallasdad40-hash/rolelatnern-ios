import Foundation
import Supabase

// Calls the `candidate-app` Edge Function for features whose tables are
// server-only (invites, Privacy Center) and for the enriched application list.
// The function verifies the user's JWT and scopes every query to their profile.

struct TrackedApplication: Decodable, Identifiable, Hashable {
    let id: UUID
    let jobId: UUID
    let applicationType: String
    let status: String
    let submittedAt: String?
    let externalClickAt: String?
    let createdAt: String
    let updatedAt: String?
    let jobTitle: String?
    let companyName: String?
    let locationText: String?
    let jobStatus: String?

    enum CodingKeys: String, CodingKey {
        case id, status
        case jobId = "job_id"
        case applicationType = "application_type"
        case submittedAt = "submitted_at"
        case externalClickAt = "external_click_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case jobTitle = "job_title"
        case companyName = "company_name"
        case locationText = "location_text"
        case jobStatus = "job_status"
    }

    var isPlatform: Bool { applicationType == "platform_application" }
    var appliedDate: Date? { ISODate.parse(submittedAt ?? externalClickAt ?? createdAt) }
    var lastUpdate: Date? { ISODate.parse(updatedAt ?? createdAt) }
    var jobClosed: Bool { jobStatus != nil && jobStatus != "active" }
}

struct CandidateInvite: Decodable, Identifiable, Hashable {
    let id: UUID
    let jobId: UUID?
    let status: String
    let message: String?
    let sentAt: String?
    let respondedAt: String?
    let jobTitle: String?
    let companyName: String?
    let locationText: String?

    enum CodingKeys: String, CodingKey {
        case id, status, message
        case jobId = "job_id"
        case sentAt = "sent_at"
        case respondedAt = "responded_at"
        case jobTitle = "job_title"
        case companyName = "company_name"
        case locationText = "location_text"
    }

    var isOpen: Bool { status == "sent" || status == "viewed" }
    var sentDate: Date? { ISODate.parse(sentAt) }
}

struct PrivacySettings: Codable, Equatable {
    var discoverable: Bool
    var anonymousSearchOptin: Bool
    var identityRevealPolicy: String
    var cvLocked: Bool
    var redactContactDetails: Bool
    var redactCurrentEmployer: Bool
    var autoProtectParentSubsidiaries: Bool
    var salaryVisibility: String
    var inviteLimitPerWeek: Int

    enum CodingKeys: String, CodingKey {
        case discoverable
        case anonymousSearchOptin = "anonymous_search_optin"
        case identityRevealPolicy = "identity_reveal_policy"
        case cvLocked = "cv_locked"
        case redactContactDetails = "redact_contact_details"
        case redactCurrentEmployer = "redact_current_employer"
        case autoProtectParentSubsidiaries = "auto_protect_parent_subsidiaries"
        case salaryVisibility = "salary_visibility"
        case inviteLimitPerWeek = "invite_limit_per_week"
    }
}

struct BlockedEmployer: Decodable, Identifiable, Hashable {
    let id: UUID
    let companyNameRaw: String?
    let relationshipType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case companyNameRaw = "company_name_raw"
        case relationshipType = "relationship_type"
    }
}

struct PrivacyAuditEntry: Decodable, Identifiable, Hashable {
    let id: UUID
    let kind: String
    let detail: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, kind, detail
        case createdAt = "created_at"
    }
}

struct PrivacyCenterData: Decodable {
    let settings: PrivacySettings
    let blockedEmployers: [BlockedEmployer]
    let audit: [PrivacyAuditEntry]

    enum CodingKeys: String, CodingKey {
        case settings, audit
        case blockedEmployers = "blocked_employers"
    }
}

enum ISODate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return withFraction.date(from: value) ?? plain.date(from: value)
    }
}

/// Error text returned by the function (e.g. "Upload a CV first…").
struct CandidateAPIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct FunctionErrorBody: Decodable { let error: String? }

struct CandidateAPI {
    private let client = Supa.client

    private func call<T: Decodable, B: Encodable>(_ body: B) async throws -> T {
        do {
            return try await client.functions.invoke(
                "candidate-app",
                options: FunctionInvokeOptions(body: body)
            )
        } catch let FunctionsError.httpError(_, data) {
            let message = (try? JSONDecoder().decode(FunctionErrorBody.self, from: data))?.error
            throw CandidateAPIError(message: message ?? "Something went wrong. Please try again.")
        }
    }

    private struct Action: Encodable { let action: String }

    // MARK: Applications

    func applications() async throws -> [TrackedApplication] {
        struct R: Decodable { let applications: [TrackedApplication] }
        let r: R = try await call(Action(action: "applications"))
        return r.applications
    }

    // MARK: Apply

    func apply(jobId: UUID, coverNote: String?) async throws {
        struct B: Encodable { let action = "apply"; let job_id: String; let cover_note: String? }
        struct R: Decodable { let ok: Bool? }
        let _: R = try await call(B(job_id: jobId.uuidString, cover_note: coverNote))
    }

    func recordExternalClick(jobId: UUID) async throws {
        struct B: Encodable { let action = "external_click"; let job_id: String }
        struct R: Decodable { let ok: Bool? }
        let _: R = try await call(B(job_id: jobId.uuidString))
    }

    /// Permanently deletes the account: CV files, all RoleLantern data, and the sign-in itself.
    func deleteAccount() async throws {
        struct B: Encodable { let action = "delete_account"; let confirm = "DELETE" }
        struct R: Decodable { let ok: Bool? }
        let _: R = try await call(B())
    }

    // MARK: Invites

    func invites() async throws -> [CandidateInvite] {
        struct R: Decodable { let invites: [CandidateInvite] }
        let r: R = try await call(Action(action: "invites"))
        return r.invites
    }

    func respond(to invite: CandidateInvite, accept: Bool) async throws {
        struct B: Encodable { let action = "invite_respond"; let invite_id: String; let decision: String }
        struct R: Decodable { let ok: Bool? }
        let _: R = try await call(B(invite_id: invite.id.uuidString, decision: accept ? "accept" : "decline"))
    }

    // MARK: Remove from my lists (candidate view only)

    func setApplicationHidden(_ id: UUID, hidden: Bool) async throws {
        struct B: Encodable { let action: String; let id: String }
        struct R: Decodable { let ok: Bool? }
        let _: R = try await call(B(action: hidden ? "hide_application" : "unhide_application", id: id.uuidString))
    }

    /// Hiding an unanswered invite also declines it on the server.
    func setInviteHidden(_ id: UUID, hidden: Bool) async throws {
        struct B: Encodable { let action: String; let id: String }
        struct R: Decodable { let ok: Bool? }
        let _: R = try await call(B(action: hidden ? "hide_invite" : "unhide_invite", id: id.uuidString))
    }

    // MARK: Privacy Center

    func privacy() async throws -> PrivacyCenterData {
        try await call(Action(action: "privacy_get"))
    }

    func updatePrivacy(_ settings: PrivacySettings) async throws {
        struct B: Encodable { let action = "privacy_update"; let settings: PrivacySettings }
        struct R: Decodable { let ok: Bool? }
        let _: R = try await call(B(settings: settings))
    }

    func blockEmployer(named name: String) async throws {
        struct B: Encodable { let action = "block_employer"; let company_name: String }
        struct R: Decodable { let ok: Bool? }
        let _: R = try await call(B(company_name: name))
    }

    func unblock(_ employer: BlockedEmployer) async throws {
        struct B: Encodable { let action = "unblock_employer"; let id: String }
        struct R: Decodable { let ok: Bool? }
        let _: R = try await call(B(id: employer.id.uuidString))
    }
}
