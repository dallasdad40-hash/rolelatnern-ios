import Foundation
import Supabase

/// Single shared Supabase client. Session is persisted in the Keychain by the SDK.
enum Supa {
    static let client = SupabaseClient(
        supabaseURL: AppConfig.supabaseURL,
        supabaseKey: AppConfig.supabaseAnonKey
    )
}

/// Data access for the candidate app. All queries run under RLS with the signed-in user's JWT.
struct DataService {
    let client = Supa.client

    private var nowISO: String {
        ISO8601DateFormatter().string(from: Date())
    }

    // MARK: Jobs

    func fetchJobs(search: String = "", functionTag: String? = nil,
                   therapeuticArea: String? = nil, remoteOnly: Bool = false,
                   location: String = "") async throws -> [BoardJob] {
        var query = client.from("board_jobs")
            .select()
            .eq("status", value: "active")
            .or("expires_at.is.null,expires_at.gt.\(nowISO)")

        if !search.isEmpty {
            let q = search.replacingOccurrences(of: ",", with: " ")
            query = query.or("job_title.ilike.%\(q)%,company_name.ilike.%\(q)%,summary.ilike.%\(q)%")
        }
        if let functionTag {
            query = query.contains("function_tags", value: [functionTag])
        }
        if let therapeuticArea {
            query = query.contains("therapeutic_area_tags", value: [therapeuticArea])
        }
        if remoteOnly {
            query = query.eq("remote_status", value: "remote")
        }
        if !location.isEmpty {
            query = query.ilike("location_text", pattern: "%\(location)%")
        }

        let jobs: [BoardJob] = try await query
            .order("posted_date", ascending: false)
            .limit(200)
            .execute()
            .value

        // Boosted jobs first (client-side; avoids null-ordering differences).
        return jobs.sorted { a, b in
            if a.isBoosted != b.isBoosted { return a.isBoosted }
            return (a.postedDate ?? "") > (b.postedDate ?? "")
        }
    }

    func fetchJob(id: UUID) async throws -> BoardJob {
        try await client.from("board_jobs").select().eq("id", value: id).single().execute().value
    }

    // MARK: Candidate profile

    func fetchMyProfile(userId: UUID) async throws -> CandidateProfile? {
        let rows: [CandidateProfile] = try await client.from("candidate_profiles")
            .select("id,user_id,anonymous_display_id,current_title,seniority_level,years_experience,desired_location,remote_preference,active_status,deleted_at")
            .eq("user_id", value: userId)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Creates a minimal candidate profile on first launch (mirrors web onboarding defaults).
    func createProfile(userId: UUID) async throws -> CandidateProfile {
        struct NewProfile: Encodable {
            let user_id: UUID
            let anonymous_display_id: String
        }
        let anonId = "RL-" + String(UUID().uuidString.prefix(8))
        return try await client.from("candidate_profiles")
            .insert(NewProfile(user_id: userId, anonymous_display_id: anonId))
            .select("id,user_id,anonymous_display_id,current_title,seniority_level,years_experience,desired_location,remote_preference,active_status,deleted_at")
            .single()
            .execute()
            .value
    }

    func updateActiveStatus(profileId: UUID, status: String) async throws {
        try await client.from("candidate_profiles")
            .update(["active_status": status])
            .eq("id", value: profileId)
            .execute()
    }

    // MARK: Saved jobs

    func fetchSavedJobs(candidateId: UUID) async throws -> [SavedJob] {
        try await client.from("saved_jobs")
            .select("id,candidate_id,job_id,saved_at")
            .eq("candidate_id", value: candidateId)
            .order("saved_at", ascending: false)
            .execute()
            .value
    }

    func saveJob(candidateId: UUID, jobId: UUID) async throws {
        struct NewSave: Encodable { let candidate_id: UUID; let job_id: UUID }
        try await client.from("saved_jobs")
            .insert(NewSave(candidate_id: candidateId, job_id: jobId))
            .execute()
    }

    func unsaveJob(candidateId: UUID, jobId: UUID) async throws {
        try await client.from("saved_jobs")
            .delete()
            .eq("candidate_id", value: candidateId)
            .eq("job_id", value: jobId)
            .execute()
    }

    // MARK: Applications

    func fetchApplications(candidateId: UUID) async throws -> [ApplicationRecord] {
        try await client.from("applications")
            .select("id,candidate_id,job_id,application_type,status,submitted_at,created_at")
            .eq("candidate_id", value: candidateId)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// Records that the candidate opened an external apply link (application_type: external_click).
    func recordExternalClick(candidateId: UUID, jobId: UUID) async throws {
        struct Click: Encodable {
            let candidate_id: UUID
            let job_id: UUID
            let application_type: String
            let status: String
            let external_click_at: String
        }
        try await client.from("applications")
            .insert(Click(candidate_id: candidateId, job_id: jobId,
                          application_type: "external_click", status: "clicked",
                          external_click_at: nowISO))
            .execute()
    }

    /// In-app partner apply. Requires an active CV; the unique constraint blocks duplicates.
    func submitPlatformApplication(candidateId: UUID, jobId: UUID, cvFileId: UUID, coverNote: String?) async throws {
        struct NewApplication: Encodable {
            let candidate_id: UUID
            let job_id: UUID
            let application_type: String
            let status: String
            let cv_file_id: UUID
            let cover_note: String?
            let submitted_at: String
        }
        try await client.from("applications")
            .insert(NewApplication(candidate_id: candidateId, job_id: jobId,
                                   application_type: "platform_application", status: "submitted",
                                   cv_file_id: cvFileId, cover_note: coverNote, submitted_at: nowISO))
            .execute()
    }

    // MARK: CV files

    func fetchActiveCV(candidateId: UUID) async throws -> CVFile? {
        let rows: [CVFile] = try await client.from("cv_files")
            .select("id,candidate_id,file_url,file_name,file_type,parsed_status,uploaded_at,deleted_at,is_active")
            .eq("candidate_id", value: candidateId)
            .is("deleted_at", value: nil)
            .order("uploaded_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    func uploadCV(candidateId: UUID, userId: UUID, data: Data, fileName: String, contentType: String) async throws -> CVFile {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let path = "\(userId.uuidString)/\(UUID().uuidString).\(ext.isEmpty ? "pdf" : ext)"

        try await client.storage.from(AppConfig.cvBucket)
            .upload(path, data: data, options: FileOptions(contentType: contentType))

        struct NewCV: Encodable {
            let candidate_id: UUID
            let file_url: String
            let file_name: String
            let file_type: String
            let parsed_status: String
            let is_active: Bool
        }
        let cv: CVFile = try await client.from("cv_files")
            .insert(NewCV(candidate_id: candidateId, file_url: path, file_name: fileName,
                          file_type: contentType, parsed_status: "pending", is_active: true))
            .select("id,candidate_id,file_url,file_name,file_type,parsed_status,uploaded_at,deleted_at,is_active")
            .single()
            .execute()
            .value

        // Trigger server-side parse on the existing web backend (keeps encryption in one place).
        // Failure is non-fatal: the web app can parse later.
        try? await callAuthenticatedEndpoint(AppConfig.cvParseEndpoint, body: ["cv_file_id": cv.id.uuidString])
        return cv
    }

    func signedCVURL(path: String) async throws -> URL {
        try await client.storage.from(AppConfig.cvBucket).createSignedURL(path: path, expiresIn: 3600)
    }

    func softDeleteCV(id: UUID) async throws {
        struct SoftDelete: Encodable {
            let deleted_at: String
            let is_active: Bool
        }
        try await client.from("cv_files")
            .update(SoftDelete(deleted_at: nowISO, is_active: false))
            .eq("id", value: id)
            .execute()
    }

    // MARK: Evidence match

    /// Server-extracted CV text (populated by the web parse pipeline), if available.
    func fetchCVText(cvId: UUID) async throws -> String? {
        struct Row: Decodable {
            let extracted_text: String?
            let parsed_text: String?
        }
        let rows: [Row] = try await client.from("cv_files")
            .select("extracted_text,parsed_text")
            .eq("id", value: cvId)
            .limit(1)
            .execute()
            .value
        return rows.first.flatMap { $0.extracted_text ?? $0.parsed_text }
    }

    func fetchMatchReport(candidateId: UUID, jobId: UUID) async throws -> CVMatchReport? {
        let rows: [CVMatchReport] = try await client.from("cv_match_reports")
            .select("id,candidate_id,job_id,match_bucket,matched_evidence,missing_evidence,unclear_evidence,created_at")
            .eq("candidate_id", value: candidateId)
            .eq("job_id", value: jobId)
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Asks the existing backend to (re)generate the evidence match report for a job.
    func requestMatchReport(jobId: UUID) async throws {
        try await callAuthenticatedEndpoint(AppConfig.evidenceMatchEndpoint, body: ["job_id": jobId.uuidString])
    }

    // MARK: Account deletion (Apple requirement)

    /// Mirrors the web "Delete my name & CV": scrubs PII, soft-deletes CVs, hides the profile.
    func deleteAccountData(profileId: UUID, candidateId: UUID) async throws {
        let cvs: [CVFile] = try await client.from("cv_files")
            .select("id,candidate_id,file_url,file_name,file_type,parsed_status,uploaded_at,deleted_at,is_active")
            .eq("candidate_id", value: candidateId)
            .is("deleted_at", value: nil)
            .execute()
            .value
        for cv in cvs { try await softDeleteCV(id: cv.id) }

        struct Scrub: Encodable {
            let full_name: String?
            let contact_email: String?
            let contact_phone: String?
            let linkedin_url: String?
            let current_company_actual: String?
            let deleted_at: String
            let active_status: String
        }
        try await client.from("candidate_profiles")
            .update(Scrub(full_name: nil, contact_email: nil, contact_phone: nil,
                          linkedin_url: nil, current_company_actual: nil,
                          deleted_at: nowISO, active_status: "not_looking"))
            .eq("id", value: profileId)
            .execute()
    }

    // MARK: Helpers

    /// Calls an existing Next.js API route with the Supabase access token as a bearer token.
    private func callAuthenticatedEndpoint(_ url: URL, body: [String: String]) async throws {
        let session = try await client.auth.session
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }
}
