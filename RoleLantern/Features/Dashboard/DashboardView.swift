import SwiftUI

enum DashRoute: Hashable { case invites, applications, privacy }

struct DashboardView: View {
    @EnvironmentObject var auth: AuthViewModel
    @EnvironmentObject var router: AppRouter
    @StateObject private var invitesVM = InvitesViewModel()
    @State private var path: [DashRoute] = []
    @State private var applications: [ApplicationRecord] = []
    @State private var jobTitles: [UUID: BoardJob] = [:]
    @State private var savedCount = 0
    @State private var availability = "active"
    @State private var isLoading = true
    @State private var saveError: String?

    private let data = DataService()

    private let availabilityOptions: [(String, String)] = [
        ("active", "Actively looking"),
        ("passive", "Open to offers"),
        ("not_looking", "Not looking"),
    ]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    welcome
                    quickLinks
                    availabilityCard
                    CVCard()
                    applicationsCard
                }
                .padding(20)
            }
            .navigationTitle("Dashboard")
            .navigationDestination(for: DashRoute.self) { route in
                switch route {
                case .invites: InvitesView(vm: invitesVM)
                case .applications: ApplicationsView()
                case .privacy: PrivacyCenterView()
                }
            }
            .onChange(of: router.pending) { _ in consumePending() }
            .onAppear { consumePending() }
            .refreshable {
                await auth.loadOrCreateProfile()
                await load()
                await invitesVM.refresh()
            }
            .alert("Something went wrong", isPresented: .init(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
            .task {
                if auth.profile == nil { await auth.loadOrCreateProfile() }
                await load()
                await invitesVM.refresh()
            }
        }
    }

    private func consumePending() {
        switch router.pending {
        case .invites: path = [.invites]; router.pending = nil
        case .applications: path = [.applications]; router.pending = nil
        default: break
        }
    }

    private var quickLinks: some View {
        VStack(spacing: 0) {
            quickLink(.invites, icon: "envelope.open", title: "Invites to apply",
                      detail: invitesVM.openCount > 0 ? "\(invitesVM.openCount) waiting" : "None waiting",
                      highlight: invitesVM.openCount > 0)
            Divider().padding(.leading, 48)
            quickLink(.applications, icon: "checklist", title: "Application tracker",
                      detail: applications.isEmpty ? "No applications yet" : "\(applications.count) total",
                      highlight: false)
            Divider().padding(.leading, 48)
            quickLink(.privacy, icon: "hand.raised", title: "Privacy Center",
                      detail: "Visibility, firewall, consent", highlight: false)
        }
        .background(Brand.surface.opacity(0.6))
        .cornerRadius(14)
    }

    private func quickLink(_ route: DashRoute, icon: String, title: String, detail: String, highlight: Bool) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(Brand.teal)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Brand.navy)
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(highlight ? Brand.gold : Brand.slate)
                }
                Spacer()
                if highlight {
                    Circle().fill(Brand.gold).frame(width: 8, height: 8)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Brand.slate)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    guard let profile = auth.profile else {
                        saveError = "Your profile hasn't loaded — pull to refresh, then try again."
                        return
                    }
                    do {
                        try await data.updateActiveStatus(profileId: profile.id, status: newValue)
                        await auth.loadOrCreateProfile()
                    } catch {
                        saveError = "Availability didn't save: \(error.localizedDescription)"
                        availability = auth.profile?.activeStatus ?? "active"
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
