import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var applications: [ApplicationRecord] = []
    @State private var jobTitles: [UUID: BoardJob] = [:]
    @State private var savedCount = 0
    @State private var availability = "active"
    @State private var isLoading = true

    private let data = DataService()

    private let availabilityOptions: [(String, String)] = [
        ("active", "Actively looking"),
        ("passive", "Open to offers"),
        ("not_looking", "Not looking"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    welcome
                    availabilityCard
                    CVCard()
                    applicationsCard
                }
                .padding(20)
            }
            .navigationTitle("Dashboard")
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private var welcome: some View {
        HStack(spacing: 14) {
            LanternMark(size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome back")
                    .font(.title3.weight(.medium))
                    .foregroundColor(Brand.navy)
                if let anonId = auth.profile?.anonymousDisplayId {
                    Text("Browsing privately as \(anonId)")
                        .font(.caption)
                        .foregroundColor(Brand.slate)
                }
            }
            Spacer()
        }
    }

    private var availabilityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Availability")
                .font(.headline)
                .foregroundColor(Brand.navy)
            Picker("Availability", selection: $availability) {
                ForEach(availabilityOptions, id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: availability) { newValue in
                // Only write when the user changed it, not when load() refreshed the value.
                guard !isLoading, newValue != auth.profile?.activeStatus else { return }
                Task {
                    if let profile = auth.profile {
                        try? await data.updateActiveStatus(profileId: profile.id, status: newValue)
                        await auth.loadOrCreateProfile()
                    }
                }
            }
            Text("Employers never see your identity without your explicit consent, whatever your status.")
                .font(.caption)
                .foregroundColor(Brand.slate)
        }
        .padding(16)
        .background(Brand.surface.opacity(0.6))
        .cornerRadius(14)
    }

    private var applicationsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Applications")
                    .font(.headline)
                    .foregroundColor(Brand.navy)
                Spacer()
                Text("\(savedCount) saved")
                    .font(.caption)
                    .foregroundColor(Brand.slate)
            }

            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if applications.isEmpty {
                Text("No applications yet. Roles you apply to will show up here with status updates.")
                    .font(.subheadline)
                    .foregroundColor(Brand.slate)
            } else {
                ForEach(applications.prefix(10)) { application in
                    HStack(spacing: 10) {
                        Image(systemName: application.applicationType == "platform_application"
                              ? "paperplane.fill" : "arrow.up.right.square")
                            .foregroundColor(Brand.teal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(jobTitles[application.jobId]?.jobTitle ?? "Role")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Brand.navy)
                                .lineLimit(1)
                            Text(jobTitles[application.jobId]?.companyName ?? "")
                                .font(.caption)
                                .foregroundColor(Brand.slate)
                        }
                        Spacer()
                        TagChip(text: statusLabel(application), color: Brand.gold)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .background(Brand.surface.opacity(0.6))
        .cornerRadius(14)
    }

    private func statusLabel(_ application: ApplicationRecord) -> String {
        if application.applicationType == "external_click" { return "Viewed externally" }
        return application.status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func load() async {
        guard let profile = auth.profile else {
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        availability = profile.activeStatus ?? "active"
        applications = (try? await data.fetchApplications(candidateId: profile.id)) ?? []
        savedCount = (try? await data.fetchSavedJobs(candidateId: profile.id).count) ?? 0
        for application in applications.prefix(10) where jobTitles[application.jobId] == nil {
            jobTitles[application.jobId] = try? await data.fetchJob(id: application.jobId)
        }
    }
}
