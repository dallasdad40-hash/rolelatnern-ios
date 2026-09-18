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

    /// Slim column set for list screens — the board now has 14k+ active jobs,
    /// so heavy columns (full_description, structured_facts) load on detail only.
    private static let listColumns = "id,job_title,company_name,location_text,remote_status,is_remote_effective,employment_type,salary_min,salary_max,currency,posted_date,summary,apply_url,job_type,status,therapeutic_area_tags,function_tags,job_level,required_education,years_experience_min,must_have_skills,nice_to_have_skills,job_freshness_status,freshness_rank,loc_lat,loc_lng,last_checked_at,boosted_until,expires_at"

    func fetchJobs(search: String = "", functionTag: String? = nil,
                   therapeuticArea: String? = nil, remoteOnly: Bool = false,
                   location: String = "",
                   country: String? = nil, state: String? = nil,
                   nearLat: Double? = nil, nearLng: Double? = nil,
                   radiusMiles: Double = 50) async throws -> [BoardJob] {
        var query = client.from("board_jobs")
            .select(Self.listColumns)
            .eq("status", value: "active")
            .or("expires_at.is.null,expires_at.gt.\(nowISO)")

        if !search.isEmpty {
            // Full-text search over the server-maintained index (37k+ jobs).
            query = query.textSearch("search_tsv", query: search, config: "simple", type: .websearch)
        }
        if let functionTag {
            query = query.contains("function_tags", value: [functionTag])
        }
        if let therapeuticArea {
            query = query.contains("therapeutic_area_tags", value: [therapeuticArea])
        }
        if remoteOnly {
            // The ingestion pipeline's canonical remote flag.
            query = query.eq("is_remote_effective", value: true)
        }
        if !location.isEmpty {
            query = query.ilike("location_text", pattern: "%\(location)%")
        }
        if let country {
            query = query.eq("loc_country", value: country)
        }
        if let state {
            query = query.eq("loc_state", value: state)
        }
        if let nearLat, let nearLng {
            let dLat = radiusMiles / 69.0
            let dLng = radiusMiles / (69.0 * max(0.2, cos(nearLat * .pi / 180)))
            query = query
                .gte("loc_lat", value: nearLat - dLat)
                .lte("loc_lat", value: nearLat + dLat)
                .gte("loc_lng", value: nearLng - dLng)
                .lte("loc_lng", value: nearLng + dLng)
        }

        let jobs: [BoardJob] = try await query
            .order("freshness_rank", ascending: true)
            .order("posted_date", ascending: false)
            .limit(200)
            .execute()
            .value

        func sqDistance(_ job: BoardJob, _ lat: Double, _ lng: Double) -> Double {
            guard let jLat = job.locLat, let jLng = job.locLng else { return .greatestFiniteMagnitude }
            let dy = (jLat - lat) * 69.0
            let dx = (jLng - lng) * 69.0 * cos(lat * .pi / 180)
            return dy * dy + dx * dx
        }

        // Boosted first; then nearest (when locating), else freshest, then newest.
        return jobs.sorted { a, b in
            if a.isBoosted != b.isBoosted { return a.isBoosted }
            if let nearLat, let nearLng {
                return sqDistance(a, nearLat, nearLng) < sqDistance(b, nearLat, nearLng)
            }
            let rankA = a.freshnessRank ?? 99
            let rankB = b.freshnessRank ?? 99
            if rankA != rankB { return rankA < rankB }
            return (a.postedDate ?? "") > (b.postedDate ?? "")
        }
    }

    func fetchJob(id: UUID) async throws -> BoardJob {
        try await client.from("board_jobs").select().eq("id", value: id).single().execute().value
    }

    // MARK: Filter options (complete lists via helper views)

    struct FilterTag: Decodable {
        let kind: String
        let value: String
    }

    struct JobLocation: Decodable {
        let locCountry: String
        let locState: String?
        let jobCount: Int

        enum CodingKeys: String, CodingKey {
            case locCountry = "loc_country"
            case locState = "loc_state"
            case jobCount = "job_count"
        }
    }

    func fetchFilterTags() async throws -> [FilterTag] {
        try await client.from("job_filter_tags").select().execute().value
    }

    func fetchJobLocations() async throws -> [JobLocation] {
        try await client.from("job_locations").select().execute().value
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
        struct StatusUpdate: Encodable {
            let active_status: String
            let last_confirmed_at: String
        }
        let response = try await client.from("candidate_profiles")
            .update(StatusUpdate(active_status: status, last_confirmed_at: nowISO))
            .eq("id", value: profileId)
            .select("id")
            .execute()
        // PostgREST reports success even when RLS filtered the row out — detect it.
        if response.data.isEmpty || String(data: response.data, encoding: .utf8) == "[]" {
            throw NSError(domain: "RoleLantern", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The change was not saved (no matching profile row — possibly a permissions issue)."
            ])
        }
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

    /// Structured CV extraction from the web pipeline (skills, education, years…).
    func fetchParsedCV(cvId: UUID) async throws -> ParsedCVData? {
        let rows: [ParsedCVData] = try await client.from("parsed_cv_data")
            .select("skills,therapeutic_areas,job_titles,employers,certifications,systems,trial_phases,education,years_of_experience")
            .eq("cv_file_id", value: cvId)
            .order("updated_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first
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

    // MARK: Messaging (bodies are encrypted server-side; app shows threads + unread counts)

    func fetchThreads(candidateId: UUID) async throws -> [MessageThread] {
        try await client.from("message_threads")
            .select("id,candidate_id,company_id,job_id,created_at,last_message_at,last_message_preview")
            .eq("candidate_id", value: candidateId)
            .order("last_message_at", ascending: false)
            .execute()
            .value
    }

    /// Unread employer messages per thread.
    func fetchUnreadCounts(threadIds: [UUID]) async throws -> [UUID: Int] {
        guard !threadIds.isEmpty else { return [:] }
        let rows: [MessageMeta] = try await client.from("messages")
            .select("id,thread_id,sender_role,read_at_candidate")
            .in("thread_id", values: threadIds)
            .eq("sender_role", value: "employer")
            .is("read_at_candidate", value: nil)
            .execute()
            .value
        return Dictionary(grouping: rows, by: \.threadId).mapValues(\.count)
    }

    /// Decrypted conversation for a thread, via the candidate-messages edge function.
    func fetchMessages(threadId: UUID) async throws -> [DecryptedMessage] {
        struct Payload: Encodable { let action = "list"; let thread_id: String }
        struct Wrapper: Decodable { let messages: [DecryptedMessage] }
        let wrapper: Wrapper = try await client.functions.invoke(
            "candidate-messages",
            options: FunctionInvokeOptions(body: Payload(thread_id: threadId.uuidString))
        )
        return wrapper.messages
    }

    /// Sends a candidate message; the edge function encrypts it with the shared key.
    func sendMessage(threadId: UUID, text: String) async throws {
        struct Payload: Encodable { let action = "send"; let thread_id: String; let text: String }
        struct Wrapper: Decodable { let ok: Bool? }
        let _: Wrapper = try await client.functions.invoke(
            "candidate-messages",
            options: FunctionInvokeOptions(body: Payload(thread_id: threadId.uuidString, text: text))
        )
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
