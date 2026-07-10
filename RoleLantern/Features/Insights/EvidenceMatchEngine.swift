import Foundation

/// On-device evidence match: compares CV text against a job's requirements.
/// Requirements come from the job's structured fields AND are mined from the
/// job description text, so sparse postings still get an honest assessment.
/// Output is factual ("stated requirement X was not found in your CV"), never
/// a judgment about the person.
enum EvidenceMatchEngine {

    /// Life-science domain vocabulary used to mine requirements from job text.
    private static let domainVocabulary: [String] = [
        // Statistical / data
        "SAS", "R programming", "Python", "SQL", "statistical programming", "biostatistics",
        "CDISC", "SDTM", "ADaM", "TLFs", "define.xml",
        // Clinical
        "clinical trial", "clinical development", "clinical operations", "clinical pharmacology",
        "pharmacokinetics", "pharmacodynamics", "PK/PD", "protocol development", "CRO management",
        "site management", "patient recruitment", "medical monitoring", "clinical data management",
        "EDC", "eTMF", "ICH-GCP", "GCP",
        // Regulatory
        "regulatory affairs", "regulatory submissions", "IND", "NDA", "BLA", "MAA",
        "510(k)", "PMA", "CE mark", "FDA", "EMA", "regulatory strategy",
        // Quality
        "quality assurance", "quality control", "GMP", "GLP", "GxP", "CAPA",
        "audits", "validation", "ISO 13485", "quality systems",
        // Science / lab
        "assay development", "NGS", "PCR", "flow cytometry", "cell culture", "immunoassay",
        "analytical chemistry", "HPLC", "mass spectrometry", "bioanalytical", "formulation",
        "process development", "CMC", "drug substance", "drug product",
        // Medical affairs / commercial
        "medical affairs", "medical writing", "publication", "KOL", "thought leader",
        "market access", "HEOR", "pharmacovigilance", "drug safety", "MedDRA", "signal detection",
        // Therapeutic areas
        "oncology", "immunology", "neurology", "cardiology", "rare disease", "genomics",
        "cell therapy", "gene therapy", "vaccines", "infectious disease",
        // Device / diagnostics
        "medical device", "diagnostics", "IVD", "design controls", "risk management",
        // General senior skills
        "cross-functional", "vendor management", "budget", "people management", "line management",
    ]

    private static let seniorityNoise: Set<String> = [
        "senior", "sr", "jr", "junior", "associate", "assistant", "principal", "staff",
        "lead", "head", "director", "manager", "executive", "chief", "vp", "vice",
        "president", "officer", "specialist", "coordinator", "i", "ii", "iii", "iv",
        "of", "and", "the", "in", "for", "to", "a", "an", "with", "on", "at", "national",
    ]

    static func match(cvText: String, job: BoardJob, candidateId: UUID) -> CVMatchReport {
        let cv = cvText.lowercased()
        let jobText = ((job.summary ?? "") + " " + (job.fullDescription ?? "")).lowercased()

        var matched: [EvidenceItem] = []
        var missing: [EvidenceItem] = []
        var unclear: [EvidenceItem] = []
        var requirementsChecked = 0
        var requirementsMissing = 0

        var coveredTerms = Set<String>()

        func checkRequirement(_ label: String, term: String, missingText: String) {
            let key = term.lowercased()
            guard !coveredTerms.contains(key) else { return }
            coveredTerms.insert(key)
            requirementsChecked += 1
            if contains(cv, phrase: term) {
                matched.append(EvidenceItem(text: label))
            } else {
                requirementsMissing += 1
                missing.append(EvidenceItem(text: missingText))
            }
        }

        // 1. Structured must-have skills (strongest signal).
        for skill in job.mustHaveSkills ?? [] {
            checkRequirement("\(skill) — found in your CV",
                             term: skill,
                             missingText: "Required: \(skill) — not found in your CV")
        }

        // 2. Function tags are requirements, not bonuses.
        for tag in job.functionTags {
            checkRequirement("Function: \(tag) — experience found in your CV",
                             term: tag,
                             missingText: "This role is in \(tag) — your CV doesn't show \(tag) experience")
        }

        // 3. Job-title domain terms (e.g. "Statistical Programming" in the title).
        let titleTerms = meaningfulTitlePhrases(job.jobTitle)
        for phrase in titleTerms {
            checkRequirement("Title match: \(phrase) — found in your CV",
                             term: phrase,
                             missingText: "The role centers on \(phrase) — not evident in your CV")
        }

        // 4. Requirements mined from the job description text.
        for term in domainVocabulary where jobText.contains(term.lowercased()) {
            checkRequirement("\(term) — asked for in the posting and found in your CV",
                             term: term,
                             missingText: "The posting mentions \(term) — not found in your CV")
        }

        // 5. Years of experience (structured, else mined from description).
        let minYears = job.yearsExperienceMin ?? yearsRequired(in: jobText)
        if let minYears, minYears > 0 {
            requirementsChecked += 1
            if let cvYears = maxYearsMentioned(in: cv) {
                if cvYears >= minYears {
                    matched.append(EvidenceItem(text: "Experience: role asks \(minYears)+ years; your CV mentions \(cvYears)"))
                } else {
                    requirementsMissing += 1
                    missing.append(EvidenceItem(text: "Requires \(minYears)+ years; your CV's highest mention is \(cvYears)"))
                }
            } else {
                unclear.append(EvidenceItem(text: "Role asks \(minYears)+ years — state your years of experience in your CV"))
            }
        }

        // 6. Education (structured, else mined).
        let education = job.requiredEducation ?? degreeRequired(in: jobText)
        if let education, !education.isEmpty {
            requirementsChecked += 1
            if mentionsEducation(cv, required: education) {
                matched.append(EvidenceItem(text: "Education: \(education) — found in your CV"))
            } else {
                requirementsMissing += 1
                missing.append(EvidenceItem(text: "Requires \(education) — not found in your CV"))
            }
        }

        // 7. Therapeutic areas: bonus when matched, gentle flag when not.
        for area in job.therapeuticAreaTags {
            if contains(cv, phrase: area) {
                matched.append(EvidenceItem(text: "Therapeutic area: \(area) — experience found"))
            } else {
                unclear.append(EvidenceItem(text: "Therapeutic area: \(area) — confirm any exposure"))
            }
        }

        // Nice-to-haves: never count against the candidate.
        for skill in job.niceToHaveSkills ?? [] where contains(cv, phrase: skill) {
            matched.append(EvidenceItem(text: "\(skill) (nice to have) — found in your CV"))
        }

        // Honest bucket from the miss ratio across checkable requirements.
        let bucket: String
        if requirementsChecked == 0 {
            bucket = "insufficient_data"
        } else {
            let ratio = Double(requirementsMissing) / Double(requirementsChecked)
            switch ratio {
            case 0:            bucket = "strong_match"
            case ..<0.35:      bucket = "good_match"
            case ..<0.7:       bucket = "possible_stretch"
            default:           bucket = "likely_not_a_fit"
            }
        }

        return CVMatchReport(
            id: UUID(),
            candidateId: candidateId,
            jobId: job.id,
            matchBucket: bucket,
            matchedEvidence: matched,
            missingEvidence: missing,
            unclearEvidence: unclear,
            createdAt: Date()
        )
    }

    // MARK: Helpers

    private static func contains(_ haystack: String, phrase: String) -> Bool {
        let needle = phrase.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return false }
        if needle.count <= 3 {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: needle))\\b"
            return haystack.range(of: pattern, options: [.regularExpression]) != nil
        }
        return haystack.contains(needle)
    }

    /// Meaningful multi-word phrases from the job title, seniority words stripped.
    /// "Associate Director, Statistical Programming" → ["statistical programming"]
    private static func meaningfulTitlePhrases(_ title: String) -> [String] {
        let segments = title.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: ",;:/–—-()"))
        var phrases: [String] = []
        for segment in segments {
            let words = segment.split(separator: " ")
                .map(String.init)
                .filter { !seniorityNoise.contains($0) && $0.count > 2 }
            if !words.isEmpty {
                phrases.append(words.joined(separator: " "))
            }
        }
        return phrases.filter { $0.count > 3 }
    }

    private static func maxYearsMentioned(in text: String) -> Int? {
        matchesInts(pattern: "(\\d{1,2})\\s*\\+?\\s*(?:years|year|yrs)", in: text).max()
    }

    private static func yearsRequired(in jobText: String) -> Int? {
        matchesInts(pattern: "(\\d{1,2})\\s*\\+?\\s*(?:years|yrs)", in: jobText).max()
    }

    private static func matchesInts(pattern: String, in text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }
    }

    private static func degreeRequired(in jobText: String) -> String? {
        if jobText.contains("phd") || jobText.contains("ph.d") || jobText.contains("doctorate") { return "PhD (or equivalent)" }
        if jobText.contains("pharmd") { return "PharmD" }
        if jobText.contains("master") || jobText.contains("msc") || jobText.contains("m.s.") { return "Master's degree" }
        if jobText.contains("bachelor") || jobText.contains("bsc") || jobText.contains("b.s.") { return "Bachelor's degree" }
        return nil
    }

    private static func mentionsEducation(_ cv: String, required: String) -> Bool {
        let req = required.lowercased()
        let tiers: [[String]] = [
            ["phd", "ph.d", "doctorate", "doctoral", "md", "pharmd", "dvm"],
            ["msc", "m.sc", "master", "m.s.", "mba", "ms "],
            ["bsc", "b.sc", "bachelor", "b.s.", "ba ", "bs "],
        ]
        for (index, tier) in tiers.enumerated() {
            if tier.contains(where: { req.contains($0) }) {
                let acceptable = tiers[0...index].flatMap { $0 }
                return acceptable.contains(where: { cv.contains($0) })
            }
        }
        return cv.contains(req)
    }
}
