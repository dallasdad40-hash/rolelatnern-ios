import SwiftUI
import Supabase

// MARK: - Model + API (calls the `cv-review` Edge Function)

struct CVReviewContent: Decodable, Hashable {
    let summary: String?
    let topStrengths: [String]?
    let areasToImprove: [String]?
    let missingKeywords: [String]?
    let roleSpecificTips: [String]?
    let suggestedBulletRewrites: [String]?
    let suggestedSummaryRewrite: String?
    let disclaimer: String?

    enum CodingKeys: String, CodingKey {
        case summary, disclaimer
        case topStrengths = "top_strengths"
        case areasToImprove = "areas_to_improve"
        case missingKeywords = "missing_keywords"
        case roleSpecificTips = "role_specific_tips"
        case suggestedBulletRewrites = "suggested_bullet_rewrites"
        case suggestedSummaryRewrite = "suggested_summary_rewrite"
    }
}

struct CVReview: Decodable, Identifiable, Hashable {
    let id: UUID
    let resumeScore: Int?
    let reviewJson: CVReviewContent
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case resumeScore = "resume_score"
        case reviewJson = "review_json"
        case createdAt = "created_at"
    }
    var date: Date? { ISODate.parse(createdAt) }
}

struct CVReviewAPI {
    private let client = Supa.client
    private struct ErrBody: Decodable { let error: String? }

    private func call<T: Decodable>(_ body: [String: String]) async throws -> T {
        do {
            return try await client.functions.invoke("cv-review", options: FunctionInvokeOptions(body: body))
        } catch let FunctionsError.httpError(_, data) {
            let msg = (try? JSONDecoder().decode(ErrBody.self, from: data))?.error
            throw CandidateAPIError(message: msg ?? "Something went wrong. Please try again.")
        }
    }

    func latest() async throws -> (CVReview?, Int) {
        struct R: Decodable { let reviews: [CVReview]; let remaining_today: Int }
        let r: R = try await call(["action": "latest"])
        return (r.reviews.first, r.remaining_today)
    }

    func review(jobId: UUID? = nil) async throws -> (CVReview, Int) {
        struct R: Decodable { let review: CVReview; let remaining_today: Int }
        var body = ["action": "review"]
        if let jobId { body["job_id"] = jobId.uuidString }
        let r: R = try await call(body)
        return (r.review, r.remaining_today)
    }
}

// MARK: - Screen

struct CVReviewView: View {
    var jobId: UUID? = nil
    var jobTitle: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var review: CVReview?
    @State private var remaining = 0
    @State private var loading = true
    @State private var running = false
    @State private var error: String?

    private let api = CVReviewAPI()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if running {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Reviewing your CV…").font(.subheadline).foregroundColor(Brand.slate)
                        Text("This takes about 20 seconds.").font(.caption).foregroundColor(Brand.slate)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                } else if let review {
                    content(review)
                } else {
                    intro
                }

                if let error {
                    Text(error).font(.subheadline).foregroundColor(.red)
                }
            }
            .padding(16)
        }
        .navigationTitle(jobTitle == nil ? "AI CV Review" : "CV Review for Job")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        }
        .task { await load() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass").font(.largeTitle).foregroundColor(Brand.teal)
            Text("Find the gaps in your CV").font(.title3.weight(.semibold)).foregroundColor(Brand.navy)
            Text(jobTitle.map { "We'll compare your CV with \($0) and show what to add or fix." }
                 ?? "Our AI reads your CV like a life-science recruiter and shows your areas of need, missing keywords, and how to fix them.")
                .font(.subheadline).foregroundColor(Brand.slate)
            runButton(title: "Review my CV")
            Label("Your CV is sent securely to our AI provider for this review only. It is not used to train AI models.",
                  systemImage: "lock.fill")
                .font(.caption).foregroundColor(Brand.slate)
        }
    }

    private func runButton(title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await run() }
            } label: {
                Label(title, systemImage: "sparkles")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(running || remaining == 0)
            Text(remaining == 0 ? "You've used today's reviews. Try again tomorrow."
                                : "\(remaining) review\(remaining == 1 ? "" : "s") left today")
                .font(.caption).foregroundColor(Brand.slate)
        }
    }

    @ViewBuilder
    private func content(_ r: CVReview) -> some View {
        let c = r.reviewJson
        HStack(alignment: .center, spacing: 16) {
            ScoreRing(score: r.resumeScore ?? 0)
            VStack(alignment: .leading, spacing: 4) {
                Text("CV score").font(.caption).foregroundColor(Brand.slate)
                if let s = c.summary { Text(s).font(.subheadline).foregroundColor(Brand.navy) }
                if let d = r.date {
                    Text("Reviewed \(d.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundColor(Brand.slate)
                }
            }
        }
        .padding(16).background(Brand.surface.opacity(0.6)).cornerRadius(14)

        section("Areas of need", icon: "exclamationmark.triangle.fill", tint: Brand.gold, items: c.areasToImprove)

        if let kws = c.missingKeywords, !kws.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header("Missing keywords", icon: "tag.fill", tint: Brand.teal)
                FlowChips(items: kws)
                Text("Add these only if they're true for you.").font(.caption).foregroundColor(Brand.slate)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface.opacity(0.6)).cornerRadius(14)
        }

        section("Strengths", icon: "checkmark.seal.fill", tint: Brand.teal, items: c.topStrengths)
        section("Bullet rewrites", icon: "pencil.line", tint: Brand.navy, items: c.suggestedBulletRewrites)
        if let s = c.suggestedSummaryRewrite, !s.isEmpty {
            section("Suggested summary", icon: "text.quote", tint: Brand.navy, items: [s])
        }
        section("Tips", icon: "lightbulb.fill", tint: Brand.gold, items: c.roleSpecificTips)

        runButton(title: "Review again")
        if let d = c.disclaimer { Text(d).font(.caption2).foregroundColor(Brand.slate) }
    }

    private func header(_ title: String, icon: String, tint: Color) -> some View {
        Label(title, systemImage: icon).font(.headline).foregroundStyle(tint, Brand.navy)
    }

    @ViewBuilder
    private func section(_ title: String, icon: String, tint: Color, items: [String]?) -> some View {
        if let items, !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header(title, icon: icon, tint: tint)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(tint).frame(width: 6, height: 6).padding(.top, 7)
                        Text(item).font(.subheadline).foregroundColor(Brand.navy)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface.opacity(0.6)).cornerRadius(14)
        }
    }

    private func load() async {
        defer { loading = false }
        do {
            let (r, left) = try await api.latest()
            remaining = left
            // Show the last general review on the general screen only.
            if jobId == nil { review = r }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func run() async {
        error = nil
        running = true
        defer { running = false }
        do {
            let (r, left) = try await api.review(jobId: jobId)
            review = r
            remaining = left
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ScoreRing: View {
    let score: Int
    private var color: Color { score >= 75 ? Brand.teal : (score >= 50 ? Brand.gold : .red) }
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: 8)
            Circle().trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)").font(.title2.weight(.bold)).foregroundColor(Brand.navy)
        }
        .frame(width: 72, height: 72)
        .accessibilityLabel("CV score \(score) out of 100")
    }
}

private struct FlowChips: View {
    let items: [String]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            chips
        }
    }
    private var chips: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { k in
                Text(k).font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Brand.teal.opacity(0.12))
                    .foregroundColor(Brand.navy)
                    .clipShape(Capsule())
                    .lineLimit(1)
            }
        }
    }
}
