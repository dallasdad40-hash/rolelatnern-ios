import SwiftUI
import PDFKit

struct JobDetailView: View {
    let job: BoardJob
    @ObservedObject var jobsVM: JobsViewModel
    @EnvironmentObject var auth: AuthViewModel

    @State private var matchReport: CVMatchReport?
    @State private var matchLoading = false
    @State private var showExternalApply = false
    @State private var showApplySheet = false
    @State private var statusMessage: String?

    private let data = DataService()

    private var isApplied: Bool { jobsVM.appliedJobIds.contains(job.id) }
    private var isSaved: Bool { jobsVM.savedJobIds.contains(job.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                trustPanel
                if let summary = job.summary, !summary.isEmpty {
                    section("About this role") {
                        Text(summary).font(.subheadline).foregroundColor(Brand.navy)
                    }
                }
                requirements
                evidenceMatch
            }
            .padding(20)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        if let profile = auth.profile {
                            await jobsVM.toggleSave(candidateId: profile.id, jobId: job.id)
                        }
                    }
                } label: {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { applyBar }
        .sheet(isPresented: $showExternalApply, onDismiss: {
            Task {
                if let profile = auth.profile {
                    try? await data.recordExternalClick(candidateId: profile.id, jobId: job.id)
                }
            }
        }) {
            if let url = URL(string: job.applyUrl) {
                SafariView(url: url).ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showApplySheet) {
            PartnerApplySheet(job: job) { applied in
                if applied {
                    jobsVM.appliedJobIds.insert(job.id)
                    statusMessage = "Application submitted."
                }
            }
        }
        .alert("Update", isPresented: .init(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(statusMessage ?? "")
        }
        .task { await loadMatch() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if job.isBoosted { BoostedBadge() }
                FreshnessBadge(status: job.jobFreshnessStatus)
            }
            Text(job.jobTitle)
                .font(.title2.weight(.medium))
                .foregroundColor(Brand.navy)
            Text(job.companyName)
                .font(.headline)
                .foregroundColor(Brand.teal)
            HStack(spacing: 10) {
                if let location = job.locationText, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                }
                Label(job.remoteStatus.replacingOccurrences(of: "_", with: " ").capitalized,
                      systemImage: "laptopcomputer")
                if let type = job.employmentType {
                    Label(type.capitalized, systemImage: "clock")
                }
            }
            .font(.caption)
            .foregroundColor(Brand.slate)

            if let min = job.salaryMin, let max = job.salaryMax {
                Text("\(job.currency ?? "USD") \(min.formatted()) – \(max.formatted())")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Brand.navy)
            }
        }
    }

    /// Freshness / trust panel — "real jobs, honest links."
    private var trustPanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.checkered")
                .foregroundColor(Brand.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("From an approved source")
                    .font(.caption.weight(.medium))
                    .foregroundColor(Brand.navy)
                if let checked = job.lastCheckedAt {
                    Text("Link checked \(checked.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundColor(Brand.slate)
                } else {
                    Text("Dead links are pruned automatically")
                        .font(.caption2)
                        .foregroundColor(Brand.slate)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Brand.teal.opacity(0.08))
        .cornerRadius(12)
    }

    private var requirements: some View {
        section("Key requirements") {
            VStack(alignment: .leading, spacing: 10) {
                if let years = job.yearsExperienceMin {
                    Label("\(years)+ years of experience", systemImage: "briefcase")
                }
                if let education = job.requiredEducation, !education.isEmpty {
                    Label(education, systemImage: "graduationcap")
                }
                if let level = job.jobLevel, !level.isEmpty {
                    Label(level.capitalized, systemImage: "chart.bar")
                }
                if let must = job.mustHaveSkills, !must.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Must-have skills").font(.caption.weight(.medium)).foregroundColor(Brand.slate)
                        FlowTags(tags: must, color: Brand.navy)
                    }
                }
                if let nice = job.niceToHaveSkills, !nice.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nice to have").font(.caption.weight(.medium)).foregroundColor(Brand.slate)
                        FlowTags(tags: nice, color: Brand.slate)
                    }
                }
                if !job.therapeuticAreaTags.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Therapeutic areas").font(.caption.weight(.medium)).foregroundColor(Brand.slate)
                        FlowTags(tags: job.therapeuticAreaTags, color: Brand.teal)
                    }
                }
            }
            .font(.subheadline)
            .foregroundColor(Brand.navy)
        }
    }

    /// Evidence match panel — explainable "why this role fits."
    private var evidenceMatch: some View {
        section("Evidence match") {
            if matchLoading {
                ProgressView("Checking your CV against this role…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else if let report = matchReport {
                VStack(alignment: .leading, spacing: 12) {
                    MatchVerdictHeader(report: report)
                    EvidenceList(title: "Why you match", items: report.matchedEvidence,
                                 icon: "checkmark.circle.fill", color: Brand.teal)
                    EvidenceList(title: "This job requires — and your CV doesn't show", items: report.missingEvidence,
                                 icon: "xmark.circle", color: .red.opacity(0.8))
                    EvidenceList(title: "Confirm this", items: report.unclearEvidence,
                                 icon: "questionmark.circle", color: Brand.gold)
                    Text("Based only on the text of your CV and this posting. If you have these skills, add them to your CV and re-run the match.")
                        .font(.caption2)
                        .foregroundColor(Brand.slate)
                    Button("Re-run match") { Task { await runMatch() } }
                        .font(.footnote)
                        .foregroundColor(Brand.teal)
                }
            } else {
                VStack(spacing: 10) {
                    Text("Run an evidence match to see why this role fits your CV — checked right on your device, no black-box scores.")
                        .font(.subheadline)
                        .foregroundColor(Brand.slate)
                    Button("Run evidence match") {
                        Task { await runMatch() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var applyBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if isApplied {
                    Label("Applied ✓", systemImage: "checkmark.circle.fill")
                        .font(.body.weight(.medium))
                        .foregroundColor(Brand.teal)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                } else if job.isPartnerApply {
                    Button("Apply on RoleLantern") { showApplySheet = true }
                        .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button {
                        showExternalApply = true
                    } label: {
                        Label("Apply on company site", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundColor(Brand.navy)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Brand.surface.opacity(0.6))
        .cornerRadius(14)
    }

    private func loadMatch() async {
        guard let profile = auth.profile else { return }
        matchReport = try? await data.fetchMatchReport(candidateId: profile.id, jobId: job.id)
    }

    /// Runs entirely on-device: reads the CV text (server-parsed if available,
    /// otherwise extracted locally from the PDF) and compares it to the job.
    private func runMatch() async {
        guard let profile = auth.profile else { return }
        matchLoading = true
        defer { matchLoading = false }

        guard let cv = try? await data.fetchActiveCV(candidateId: profile.id) else {
            statusMessage = "Upload a CV first (Dashboard tab), then run the match."
            return
        }

        var cvText = (try? await data.fetchCVText(cvId: cv.id)) ?? nil

        // No server-parsed text yet? Extract locally from the PDF.
        if cvText == nil || cvText?.isEmpty == true {
            if (cv.fileType ?? "").contains("pdf") || (cv.fileName ?? "").lowercased().hasSuffix(".pdf") {
                if let url = try? await data.signedCVURL(path: cv.fileUrl),
                   let (fileData, _) = try? await URLSession.shared.data(from: url),
                   let pdf = PDFDocument(data: fileData) {
                    cvText = pdf.string
                }
            }
        }

        guard let text = cvText, !text.isEmpty else {
            statusMessage = "Couldn't read your CV's text yet. PDFs work best — try re-uploading as PDF."
            return
        }

        matchReport = EvidenceMatchEngine.match(cvText: text, job: job, candidateId: profile.id)
    }
}

/// Honest, factual verdict header for the evidence match.
struct MatchVerdictHeader: View {
    let report: CVMatchReport

    private var verdict: (label: String, detail: String, color: Color) {
        let missingCount = report.missingEvidence.count
        switch report.matchBucket {
        case "strong_match":
            return ("Strong match", "Your CV shows evidence for everything this posting asks for.", Brand.teal)
        case "good_match":
            return ("Good match", "Your CV covers most of what this posting asks for.", Brand.teal)
        case "possible_stretch":
            return ("Possible stretch", "This posting asks for \(missingCount) thing\(missingCount == 1 ? "" : "s") we couldn't find in your CV — see below.", Brand.gold)
        case "likely_not_a_fit":
            return ("Likely not a fit", "Most of what this posting asks for isn't evident in your CV. The gaps are listed below so you can judge for yourself.", Color.red.opacity(0.85))
        default:
            return ("Not enough to assess", "This posting doesn't state enough checkable requirements for a meaningful comparison.", Brand.slate)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(verdict.color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(verdict.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(verdict.color)
                Text(verdict.detail)
                    .font(.caption)
                    .foregroundColor(Brand.navy)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(verdict.color.opacity(0.08))
        .cornerRadius(10)
    }
}

struct EvidenceList: View {
    let title: String
    let items: [EvidenceItem]
    let icon: String
    let color: Color

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption.weight(.medium)).foregroundColor(Brand.slate)
                ForEach(items.filter { !$0.text.isEmpty }) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon).foregroundColor(color).font(.caption)
                        Text(item.text).font(.subheadline).foregroundColor(Brand.navy)
                    }
                }
            }
        }
    }
}

/// Simple wrapping tag layout.
struct FlowTags: View {
    let tags: [String]
    var color: Color = Brand.teal

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { TagChip(text: $0, color: color) }
        }
    }
}

/// Partner apply: requires an active CV, blocks duplicates via the unique constraint.
struct PartnerApplySheet: View {
    let job: BoardJob
    let onFinish: (Bool) -> Void

    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var cv: CVFile?
    @State private var coverNote = ""
    @State private var busy = false
    @State private var loadingCV = true
    @State private var errorText: String?

    private let data = DataService()

    var body: some View {
        NavigationStack {
            Form {
                Section("Role") {
                    Text(job.jobTitle).font(.body.weight(.medium))
                    Text(job.companyName).foregroundColor(Brand.slate)
                }
                Section("Your CV") {
                    if loadingCV {
                        ProgressView()
                    } else if let cv {
                        Label(cv.fileName ?? "CV on file", systemImage: "doc.fill")
                            .foregroundColor(Brand.navy)
                    } else {
                        Text("You need a CV to apply. Upload one from the Dashboard tab first.")
                            .foregroundColor(.red)
                    }
                }
                Section("Cover note (optional)") {
                    TextEditor(text: $coverNote).frame(minHeight: 100)
                }
                if let errorText {
                    Section { Text(errorText).foregroundColor(.red) }
                }
            }
            .navigationTitle("Apply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Sending…" : "Submit") { Task { await submit() } }
                        .disabled(cv == nil || busy)
                }
            }
            .task {
                if let profile = auth.profile {
                    cv = try? await data.fetchActiveCV(candidateId: profile.id)
                }
                loadingCV = false
            }
        }
    }

    private func submit() async {
        guard let profile = auth.profile, let cv else { return }
        busy = true
        defer { busy = false }
        do {
            try await data.submitPlatformApplication(
                candidateId: profile.id, jobId: job.id, cvFileId: cv.id,
                coverNote: coverNote.isEmpty ? nil : coverNote
            )
            onFinish(true)
            dismiss()
        } catch {
            // Unique constraint violation = already applied.
            if error.localizedDescription.lowercased().contains("duplicate")
                || error.localizedDescription.contains("23505") {
                onFinish(true)
                dismiss()
            } else {
                errorText = "Could not submit: \(error.localizedDescription)"
            }
        }
    }
}
