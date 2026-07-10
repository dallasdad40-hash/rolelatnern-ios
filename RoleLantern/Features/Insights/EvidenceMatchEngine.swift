import Foundation

/// On-device evidence match: compares CV text against a job's stated requirements.
/// Deterministic and explainable — "evidence, not black-box AI."
enum EvidenceMatchEngine {

    static func match(cvText: String, job: BoardJob, candidateId: UUID) -> CVMatchReport {
        let cv = cvText.lowercased()
        var matched: [EvidenceItem] = []
        var missing: [EvidenceItem] = []
        var unclear: [EvidenceItem] = []

        // Must-have skills
        for skill in job.mustHaveSkills ?? [] {
            if contains(cv, phrase: skill) {
                matched.append(EvidenceItem(text: "\(skill) — mentioned in your CV"))
            } else {
                missing.append(EvidenceItem(text: "\(skill) — not found in your CV"))
            }
        }

        // Nice-to-have skills
        for skill in job.niceToHaveSkills ?? [] {
            if contains(cv, phrase: skill) {
                matched.append(EvidenceItem(text: "\(skill) (nice to have) — mentioned in your CV"))
            } else {
                unclear.append(EvidenceItem(text: "\(skill) (nice to have) — add it if you have it"))
            }
        }

        // Years of experience
        if let minYears = job.yearsExperienceMin, minYears > 0 {
            if let cvYears = maxYearsMentioned(in: cv) {
                if cvYears >= minYears {
                    matched.append(EvidenceItem(text: "Experience: role asks \(minYears)+ years; your CV mentions \(cvYears)"))
                } else {
                    unclear.append(EvidenceItem(text: "Role asks \(minYears)+ years; confirm your total experience"))
                }
            } else {
                unclear.append(EvidenceItem(text: "Role asks \(minYears)+ years — state your years of experience in your CV"))
            }
        }

        // Education
        if let education = job.requiredEducation, !education.isEmpty {
            if mentionsEducation(cv, required: education) {
                matched.append(EvidenceItem(text: "Education: \(education) — found in your CV"))
            } else {
                unclear.append(EvidenceItem(text: "Education: role asks for \(education) — confirm yours"))
            }
        }

        // Therapeutic areas
        for area in job.therapeuticAreaTags {
            if contains(cv, phrase: area) {
                matched.append(EvidenceItem(text: "Therapeutic area: \(area) — experience found"))
            }
        }

        // Function tags
        for tag in job.functionTags where contains(cv, phrase: tag) {
            matched.append(EvidenceItem(text: "Function: \(tag) — experience found"))
        }

        let bucket: String
        let mustHaveCount = job.mustHaveSkills?.count ?? 0
        let mustHaveMissing = missing.count
        if mustHaveCount == 0 {
            bucket = matched.isEmpty ? "worth_reviewing" : "good_match"
        } else if mustHaveMissing == 0 {
            bucket = "strong_match"
        } else if mustHaveMissing <= mustHaveCount / 2 {
            bucket = "good_match"
        } else {
            bucket = "stretch"
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

    /// Word-boundary-ish containment so "R" doesn't match everything but "GCP" matches "GCP,".
    private static func contains(_ haystack: String, phrase: String) -> Bool {
        let needle = phrase.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return false }
        if needle.count <= 2 {
            // Very short tokens: require word boundaries to avoid false positives.
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: needle))\\b"
            return haystack.range(of: pattern, options: [.regularExpression]) != nil
        }
        return haystack.contains(needle)
    }

    /// Finds the largest "N years" / "N+ yrs" mention in the CV.
    private static func maxYearsMentioned(in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "(\\d{1,2})\\s*\\+?\\s*(?:years|year|yrs)") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let values = regex.matches(in: text, range: range).compactMap { match -> Int? in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[r])
        }
        return values.max()
    }

    private static func mentionsEducation(_ cv: String, required: String) -> Bool {
        let req = required.lowercased()
        let tiers: [[String]] = [
            ["phd", "ph.d", "doctorate", "doctoral", "md", "pharmd", "dvm"],
            ["msc", "m.sc", "master", "m.s.", "mba", "ms "],
            ["bsc", "b.sc", "bachelor", "b.s.", "ba ", "bs "],
        ]
        // If the CV mentions the required tier or anything higher, count it.
        for (index, tier) in tiers.enumerated() {
            if tier.contains(where: { req.contains($0) }) {
                let acceptable = tiers[0...index].flatMap { $0 }
                return acceptable.contains(where: { cv.contains($0) })
            }
        }
        // Unrecognized requirement string: look for any direct mention.
        return cv.contains(req)
    }
}
