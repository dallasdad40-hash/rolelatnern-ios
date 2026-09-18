import Foundation

// MARK: - Jobs

struct BoardJob: Codable, Identifiable, Hashable {
    let id: UUID
    let jobTitle: String
    let companyName: String
    let locationText: String?
    let remoteStatus: String
    let summary: String?
    let fullDescription: String?
    let fullDescriptionAllowed: Bool?
    let applyUrl: String
    let jobType: String                 // external_apply | partner_apply
    let status: String
    let therapeuticAreaTags: [String]
    let functionTags: [String]
    let jobLevel: String?
    let requiredEducation: String?
    let yearsExperienceMin: Int?
    let mustHaveSkills: [String]?
    let niceToHaveSkills: [String]?
    let jobFreshnessStatus: String
    let freshnessRank: Int?
    let locLat: Double?
    let locLng: Double?
    let isRemoteEffective: Bool?
    let lastCheckedAt: Date?
    let boostedUntil: Date?
    let expiresAt: Date?
    let postedDate: String?
    let salaryMin: Int?
    let salaryMax: Int?
    let currency: String?
    let employmentType: String?
    /// AI-classified requirements/responsibilities from the web ingestion pipeline.
    let structuredFacts: StructuredFacts?

    enum CodingKeys: String, CodingKey {
        case id
        case jobTitle = "job_title"
        case companyName = "company_name"
        case locationText = "location_text"
        case remoteStatus = "remote_status"
        case summary
        case fullDescription = "full_description"
        case fullDescriptionAllowed = "full_description_allowed"
        case applyUrl = "apply_url"
        case jobType = "job_type"
        case status
        case therapeuticAreaTags = "therapeutic_area_tags"
        case functionTags = "function_tags"
        case jobLevel = "job_level"
        case requiredEducation = "required_education"
        case yearsExperienceMin = "years_experience_min"
        case mustHaveSkills = "must_have_skills"
        case niceToHaveSkills = "nice_to_have_skills"
        case jobFreshnessStatus = "job_freshness_status"
        case freshnessRank = "freshness_rank"
        case locLat = "loc_lat"
        case locLng = "loc_lng"
        case isRemoteEffective = "is_remote_effective"
        case lastCheckedAt = "last_checked_at"
        case boostedUntil = "boosted_until"
        case expiresAt = "expires_at"
        case postedDate = "posted_date"
        case salaryMin = "salary_min"
        case salaryMax = "salary_max"
        case currency
        case employmentType = "employment_type"
        case structuredFacts = "structured_facts"
    }

    var isBoosted: Bool {
        if let boostedUntil { return boostedUntil > Date() }
        return false
    }
    var isPartnerApply: Bool { jobType == "partner_apply" }

    /// Human label for work mode; nil when the source data is unknown.
    var workModeLabel: String? {
        if isRemoteEffective == true { return "Remote" }
        let status = remoteStatus.lowercased()
        if status == "unknown" || status.isEmpty { return nil }
        return remoteStatus.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct StructuredFacts: Codable, Hashable {
    let requirements: [String]?
    let responsibilities: [String]?
    let compensation: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requirements = try? container.decodeIfPresent([String].self, forKey: .requirements)
        responsibilities = try? container.decodeIfPresent([String].self, forKey: .responsibilities)
        compensation = try? container.decodeIfPresent(String.self, forKey: .compensation)
    }

    enum CodingKeys: String, CodingKey {
        case requirements, responsibilities, compensation
    }
}

// MARK: - Candidate

struct CandidateProfile: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    let anonymousDisplayId: String
    var currentTitle: String?
    var seniorityLevel: String?
    var yearsExperience: Int?
    var desiredLocation: String?
    var remotePreference: String?
    var activeStatus: String?           // active | passive | not_looking
    var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case anonymousDisplayId = "anonymous_display_id"
        case currentTitle = "current_title"
        case seniorityLevel = "seniority_level"
        case yearsExperience = "years_experience"
        case desiredLocation = "desired_location"
        case remotePreference = "remote_preference"
        case activeStatus = "active_status"
        case deletedAt = "deleted_at"
    }
}

struct CVFile: Codable, Identifiable {
    let id: UUID
    let candidateId: UUID
    let fileUrl: String
    let fileName: String?
    let fileType: String?
    let parsedStatus: String
    let uploadedAt: Date
    let deletedAt: Date?
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case candidateId = "candidate_id"
        case fileUrl = "file_url"
        case fileName = "file_name"
        case fileType = "file_type"
        case parsedStatus = "parsed_status"
        case uploadedAt = "uploaded_at"
        case deletedAt = "deleted_at"
        case isActive = "is_active"
    }
}

struct SavedJob: Codable, Identifiable {
    let id: UUID
    let candidateId: UUID
    let jobId: UUID
    let savedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case candidateId = "candidate_id"
        case jobId = "job_id"
        case savedAt = "saved_at"
    }
}

struct ApplicationRecord: Codable, Identifiable {
    let id: UUID
    let candidateId: UUID
    let jobId: UUID
    let applicationType: String         // external_click | platform_application
    let status: String
    let submittedAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case candidateId = "candidate_id"
        case jobId = "job_id"
        case applicationType = "application_type"
        case status
        case submittedAt = "submitted_at"
        case createdAt = "created_at"
    }
}

// MARK: - Parsed CV (structured extraction from the web pipeline)

/// Tolerant decoder: fields arrive from an evolving jsonb-backed pipeline.
struct ParsedCVData: Codable {
    let skills: [String]?
    let therapeuticAreas: [String]?
    let jobTitles: [String]?
    let employers: [String]?
    let certifications: [String]?
    let systems: [String]?
    let trialPhases: [String]?
    let education: String?
    let yearsOfExperience: Int?

    enum CodingKeys: String, CodingKey {
        case skills
        case therapeuticAreas = "therapeutic_areas"
        case jobTitles = "job_titles"
        case employers
        case certifications
        case systems
        case trialPhases = "trial_phases"
        case education
        case yearsOfExperience = "years_of_experience"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skills = (try? c.decodeIfPresent([String].self, forKey: .skills)) ?? nil
        therapeuticAreas = (try? c.decodeIfPresent([String].self, forKey: .therapeuticAreas)) ?? nil
        jobTitles = (try? c.decodeIfPresent([String].self, forKey: .jobTitles)) ?? nil
        employers = (try? c.decodeIfPresent([String].self, forKey: .employers)) ?? nil
        certifications = (try? c.decodeIfPresent([String].self, forKey: .certifications)) ?? nil
        systems = (try? c.decodeIfPresent([String].self, forKey: .systems)) ?? nil
        trialPhases = (try? c.decodeIfPresent([String].self, forKey: .trialPhases)) ?? nil
        education = (try? c.decodeIfPresent(String.self, forKey: .education)) ?? nil
        yearsOfExperience = (try? c.decodeIfPresent(Int.self, forKey: .yearsOfExperience)) ?? nil
    }

    /// Flattened into text so the evidence engine can match against it
    /// alongside the raw CV text.
    var asMatchText: String {
        var parts: [String] = []
        for list in [skills, therapeuticAreas, jobTitles, employers, certifications, systems, trialPhases] {
            if let list, !list.isEmpty { parts.append(list.joined(separator: ". ")) }
        }
        if let education, !education.isEmpty { parts.append(education) }
        if let years = yearsOfExperience, years > 0 { parts.append("\(years) years of experience") }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Messaging

struct MessageThread: Codable, Identifiable {
    let id: UUID
    let candidateId: UUID
    let companyId: UUID
    let jobId: UUID?
    let createdAt: Date
    let lastMessageAt: Date
    let lastMessagePreview: String?

    enum CodingKeys: String, CodingKey {
        case id
        case candidateId = "candidate_id"
        case companyId = "company_id"
        case jobId = "job_id"
        case createdAt = "created_at"
        case lastMessageAt = "last_message_at"
        case lastMessagePreview = "last_message_preview"
    }

    /// Previews are encrypted server-side; only show them if readable.
    var readablePreview: String? {
        guard let preview = lastMessagePreview, !preview.hasPrefix("enc:") else { return nil }
        return preview
    }
}

struct MessageMeta: Codable, Identifiable {
    let id: UUID
    let threadId: UUID
    let senderRole: String
    let readAtCandidate: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case threadId = "thread_id"
        case senderRole = "sender_role"
        case readAtCandidate = "read_at_candidate"
    }
}

// MARK: - Evidence match

struct CVMatchReport: Codable, Identifiable {
    let id: UUID
    let candidateId: UUID
    let jobId: UUID?
    let matchBucket: String?
    let matchedEvidence: [EvidenceItem]
    let missingEvidence: [EvidenceItem]
    let unclearEvidence: [EvidenceItem]
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case candidateId = "candidate_id"
        case jobId = "job_id"
        case matchBucket = "match_bucket"
        case matchedEvidence = "matched_evidence"
        case missingEvidence = "missing_evidence"
        case unclearEvidence = "unclear_evidence"
        case createdAt = "created_at"
    }
}

/// Evidence entries are stored as jsonb; tolerate both plain strings and objects.
struct EvidenceItem: Codable, Identifiable, Hashable {
    var id: String { text }
    let text: String

    init(text: String) { self.text = text }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            text = s
            return
        }
        let container = try decoder.container(keyedBy: DynamicKey.self)
        for key in ["text", "evidence", "requirement", "label", "title"] {
            if let v = try? container.decode(String.self, forKey: DynamicKey(stringValue: key)!) {
                text = v
                return
            }
        }
        text = ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
